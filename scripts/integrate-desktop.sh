#!/usr/bin/env bash
# ============================================================================
# 集成安装：把 X11(UKUI) + Wayland(labwc) 双桌面 + rkmpp 媒体栈烘焙进「离线 rootfs」
#
# 与 integrate-iot.sh 同接口：
#   sudo bash integrate-desktop.sh <rootfs目录> [--flavor=both|x11|wayland] [--mpv-x11=1] [--admin-user=iot] [--kiosk=0|1] [--kiosk-video=<文件>]
#   sudo bash integrate-desktop.sh <rootfs目录> --media-only=1        # 无桌面：只烘焙 rkmpp 媒体栈 + mpv-auto(KMS 直控)
#
# 设计要点：
#   ① 由 build-image.sh 在 chroot 已挂载的前提下调用；本脚本再做幂等挂载 + resolv 修复
#   ② git clone 在宿主机跑（runner 网络更稳），编译（meson/ninja/cmake）在 chroot 内跑
#   ③ mpv 补丁在宿主机对 $R/opt/rk-src/mpv 打（chroot 内看不到仓库 scripts/ 路径）
#   ④ wayland-protocols 源码升级到 1.50 → mpv wayland 后端自动开启；mpv 已 -Dx11=enabled
#      → 最终 mpv 三后端（drm + x11egl + wayland）全开，rkmpp 硬解零拷贝
#   ⑤ lightdm 统一显示管理器：autologin-user=<admin> 进选定会话（both 默认 labwc/Wayland）
#   ⑥ --media-only=1（或 MEDIA_ONLY=1）：桌面/无桌面共用同一份媒体栈源码与补丁，
#      media-only 跳过 Wayland 栈/UKUI/lightdm/seatd/graphical.target/kiosk，
#      只留 libplacebo/mpp/rga/ffmpeg-rockchip(锁 9.1, pitch 补丁)/mpv + mpv-auto 的 KMS 后端链。
#      libdisplay-info 是 mpv drm VO 硬依赖，故从 wayland 条件块移出、两种模式都编译。
#
# 前置：openEuler aarch64 rootfs、arm runner（chroot 原生编译）、root、网络
# ============================================================================
set -euo pipefail

R="${1:?用法: $0 <rootfs目录> [选项]}"
shift || true

FLAVOR="${DESKTOP_FLAVOR:-both}"
MPV_X11="${MPV_X11:-1}"
ADMIN_USER="${ADMIN_USER:-iot}"
KIOSK="${KIOSK:-0}"
KIOSK_VIDEO="${KIOSK_VIDEO:-}"
MEDIA_ONLY="${MEDIA_ONLY:-0}"
for a in "$@"; do
  case "$a" in
    --flavor=*)       FLAVOR="${a#*=}" ;;
    --mpv-x11=*)      MPV_X11="${a#*=}" ;;
    --admin-user=*)   ADMIN_USER="${a#*=}" ;;
    --kiosk=*)        KIOSK="${a#*=}" ;;
    --kiosk-video=*)  KIOSK_VIDEO="${a#*=}" ;;
    --media-only=*)   MEDIA_ONLY="${a#*=}" ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

# media-only：无桌面(headless) 镜像只烘焙媒体栈 + mpv-auto(KMS 直控)，与桌面共用同一份源码和补丁。
# 强制关掉桌面相关开关（FLAVOR/X11/KIOSK），避免后续 want() 或 lightdm 段误启用桌面组件。
case "$MEDIA_ONLY" in 1|true|yes|on|TRUE) MEDIA_ONLY=1 ;; *) MEDIA_ONLY=0 ;; esac
if [ "$MEDIA_ONLY" = 1 ]; then
  FLAVOR=none
  MPV_X11=0
  KIOSK=0
  KIOSK_VIDEO=""
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$R/opt/rk-src"                      # 源码树落在 rootfs 内，chroot 编译即用
mkdir -p "$SRC"

log()  { printf '\n\033[1;35m[DESKTOP] %s\033[0m\n' "$*"; }
info() { printf '      %s\n' "$*"; }
warn() { printf '\033[1;33m[DESKTOP-WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[DESKTOP-ERR] %s\033[0m\n' "$*" >&2; exit 1; }
want() { case ",$FLAVOR," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# 规范化 KIOSK 为 1/0（兼容工作流传入的 true/false/yes/on）
case "$KIOSK" in 1|true|yes|on|TRUE) KIOSK=1 ;; *) KIOSK=0 ;; esac

# kiosk 展示模式隐含需要 wayland(labwc)：flavor 不含 wayland 时自动升为 both
if [ "$KIOSK" = "1" ] && ! want wayland && ! want both; then
  warn "kiosk 需要 wayland(labwc)，已将 flavor 由 $FLAVOR 自动升为 both"
  FLAVOR=both
fi

[ "$(id -u)" = 0 ] || die "需要 root（要 chroot + mount）"
[ -d "$R/etc" ] || die "$R 不像 rootfs"
[ "$(uname -m)" = aarch64 ] || die "必须 aarch64（chroot 原生编译），当前 $(uname -m)"
grep -qs '^ID="*openEuler' "$R/etc/os-release" || die "$R/etc/os-release 不是 openEuler"

# ---------------------------------------------------------------------------
# chroot 挂载 + resolv 修复（幂等）
# ---------------------------------------------------------------------------
mountpoint -q "$R/proc" || { mount -t proc proc "$R/proc"; }
mountpoint -q "$R/sys"  || { mount -t sysfs sys "$R/sys"; }
mkdir -p "$R/dev" "$R/dev/pts" "$R/run"
mountpoint -q "$R/dev"     || { mount --bind /dev "$R/dev"; }
mountpoint -q "$R/dev/pts" || { mount --bind /dev/pts "$R/dev/pts"; }

SAVED_RESOLV=""
if [ -e "$R/etc/resolv.conf" ] && [ ! -L "$R/etc/resolv.conf" ]; then
  SAVED_RESOLV="$R/etc/resolv.conf.desktopbak"
  cp -f "$R/etc/resolv.conf" "$SAVED_RESOLV"
fi
rm -f "$R/etc/resolv.conf"
{ echo "# temporary, restored after integrate"; grep -E '^(nameserver|options)' /etc/resolv.conf 2>/dev/null || echo "nameserver 223.5.5.5"; } \
  > "$R/etc/resolv.conf"

cleanup() {
  set +e
  [ -n "$SAVED_RESOLV" ] && [ -f "$SAVED_RESOLV" ] && mv -f "$SAVED_RESOLV" "$R/etc/resolv.conf"
  umount "$R/dev/pts" 2>/dev/null; umount "$R/dev" 2>/dev/null
  umount "$R/sys" 2>/dev/null;     umount "$R/proc" 2>/dev/null
}
trap cleanup EXIT

# chroot 内执行编译/安装命令。
# PKG_CONFIG_PATH 里 /usr/local/share/pkgconfig 必须有：wayland-protocols 的 .pc 装在这里
# （datadir/pkgconfig），漏掉会搜到系统自带的 1.33，而 labwc 0.9.0 要求 >=1.39 且无 wrap 兜底。
cr() {
  chroot "$R" /usr/bin/env -i \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig" \
    HOME=/root LANG=C.UTF-8 \
    bash -c "$*"
}

# 逐个安装开发库：容忍单个包在源里不存在，避免整笔 dnf 事务因个别坏包名全部中止
# （早期踩坑：libudev-devel/x264-devel 等不存在会让 libinput-devel 等必需包连带装不上）
dnf_install_loose() {
  local p
  for p in "$@"; do
    if cr "$DNFC install $p" >"/tmp/dnf-loose-$p.log" 2>&1; then
      log "dnf ok: $p"
    else
      warn "dnf 未安装(若非必需可忽略): $p"
    fi
  done
}

log "目标系统: $(grep -E '^(PRETTY_NAME)=' "$R/etc/os-release" | cut -d= -f2- | tr -d '\"')"
log "桌面组合: $FLAVOR（autologin 用户: $ADMIN_USER）"

# ---------------------------------------------------------------------------
# 前置：dnf 源修复（必须先于任何 dnf install，桌面与 --media-only 两条路径都走）
#   2026-11-27 CI 第三次网络故障：repomd checksum 不匹配，4 个 calculated
#   sha512 全相同（缓存中毒 + 多镜像校验）。清缓存 + 固定单源 + 主备源自动回退。
# ---------------------------------------------------------------------------
# shellcheck source=lib-dnf-repair.sh
. "$HERE/lib-dnf-repair.sh"
dnf_repair_sources || die "dnf 源修复失败，基础依赖必然装不上，提前中止"

# ---------------------------------------------------------------------------
# 0. 基础依赖（合并：UKUI/lightdm/mesa/X11/Wayland 编译链/媒体栈编译链）
# ---------------------------------------------------------------------------
log "安装基础依赖（dnf）"
DNFC="dnf -y --setopt=install_weak_deps=False --setopt=timeout=30 --setopt=retries=2"

# 关键构建工具链（必须成功，否则后续 meson/ninja/cmake 缺失无法编译；单独成笔避免被坏包名拖垮整笔事务）
cr "$DNFC install tar xz git curl ca-certificates shadow util-linux hostname findutils \
  meson ninja-build cmake gcc gcc-c++ make nasm yasm pkgconf-pkg-config \
  bison flex gperf" >/tmp/desktop-dnf-tools.log 2>&1 \
  || { tail -30 /tmp/desktop-dnf-tools.log >&2; die "基础构建工具链安装失败（meson/ninja/cmake/bison 缺失），桌面集成中止"; }

# 开发库与运行时：逐个安装、容忍缺失（避免整笔 dnf 因个别包名不存在而全部中止）。
# 注意：seatd/libseat-devel 在 openEuler 不存在（本就源码编译），libudev 头由 systemd-devel 提供，均不列入。
dnf_install_loose \
  libdrm-devel expat-devel libffi-devel \
  libX11-devel libXext-devel libXrandr-devel libXv-devel libxcb-devel \
  xcb-util-wm-devel xcb-util-renderutil-devel xcb-util-keysyms-devel xcb-util-image-devel xcb-util-cursor-devel \
  wayland-devel wayland-protocols-devel libxkbcommon-devel libxkbcommon \
  libinput-devel pixman-devel libxml2-devel cairo-devel pango-devel glib2-devel \
  freetype-devel fontconfig-devel mesa-libGL-devel mesa-libEGL-devel mesa-libgbm-devel \
  libass-devel uchardet-devel lua-devel x264-devel x265-devel libdav1d-devel gnutls-devel \
  alsa-lib-devel libXScrnSaver-devel libXpresent-devel libXfixes-devel \
  systemd-devel hwdata \
  xorg-x11-server-Xwayland xorg-x11-server-Xwayland-devel xterm

# 中文字体：最小 rootfs 无任何 :lang=zh 字体（实测 fc-list :lang=zh = 0），
# Kodi/mpv OSD、UKUI/labwc 桌面与文件名中文都会显示成方框。
# google-noto-cjk-fonts 覆盖简/繁/日/韩，为 openEuler OE-OS 源稳定包；
# cjkuni-ukai-fonts（楷体）作补充，两者均走 dnf_install_loose 容忍缺包。
log "安装中文字体"
dnf_install_loose google-noto-cjk-fonts cjkuni-ukai-fonts
if cr "fc-list :lang=zh 2>/dev/null | grep -q ."; then
  cr "fc-cache -f >/dev/null 2>&1" || warn "fc-cache 刷新失败（不影响字体文件本身）"
  info "中文字体已装: $(cr 'fc-list :lang=zh 2>/dev/null | wc -l') 款"
else
  warn "中文字体未装上：Kodi/mpv OSD 与桌面中文可能显示方框"
fi

# ---------------------------------------------------------------------------
# 1. git clone（宿主机执行，网络更稳）
# ---------------------------------------------------------------------------
git_clone_retry() {
  local branch="${1:-}"; local dest="$2"; shift 2
  local bflag=""; [ -n "$branch" ] && bflag="-b $branch"
  for url in "$@"; do
    for attempt in 1 2 3 4 5; do
      log "[clone] 尝试 $attempt/5: $url"
      rm -rf "$dest"
      if git clone --depth=1 --recurse-submodules $bflag "$url" "$dest" >"/tmp/clone-$$.log" 2>&1 && [ -d "$dest" ]; then
        log "[clone] 成功: $url"; return 0
      fi
      sleep 8
    done
  done
  die "所有源/重试均失败: $*"
}
# 钉死的 Wayland 栈版本：labwc 0.9.0 只要 libinput>=1.14（openEuler 24.03 自带 1.24.0），
# 且硬性依赖 wlroots-0.19；较新 labwc(>=0.9.8 / 0.20.x) 要 wlroots-0.20 + libinput>=1.26，
# 与本镜像源不兼容。版本号跳跃（0.9.x→0.20.x）+ 自动选 latest 会选错，故显式钉死。
WLR_TAG="0.19.0"
LAB_TAG="0.9.0"

# 校验源码确实落在指定标签，防止浅克隆未带标签时静默编译 master（曾连错 3 轮 CI 才定位）。
assert_src_tag() {
  local d="$1" want="$2" got
  got="$(git -C "$d" describe --tags --exact-match 2>/dev/null || true)"
  [ "$got" = "$want" ] || die "源码版本校验失败：$d 期望 $want，实际 ${got:-无标签/HEAD}（clone 未落在钉死标签，会误编 master）"
  log "源码版本校验 OK: $(basename "$d")=$got"
}

# ---- libdisplay-info 源码（始终：mpv 的 drm VO 硬依赖 EDID 解析，桌面/无桌面都要） ----
mkdir -p "$SRC/wayland-src"
git_clone_retry ""         "$SRC/libdisplay-info" \
  https://gitlab.freedesktop.org/emersion/libdisplay-info.git https://github.com/emersion/libdisplay-info.git

# ---- Wayland 栈源码（both / wayland） ----
if want wayland || want both; then
  git_clone_retry ""         "$SRC/wayland-src/wayland-protocols" \
    https://gitlab.freedesktop.org/wayland/wayland-protocols.git https://github.com/wayland-project/wayland-protocols.git
  git_clone_retry ""         "$SRC/wayland-src/libxkbcommon" https://github.com/xkbcommon/libxkbcommon.git
  git_clone_retry ""         "$SRC/wayland-src/seatd" https://github.com/kennylevinsen/seatd.git
  # 关键：--depth=1 浅克隆不带任何标签，事后 git checkout <tag> 必然失败且被静默吞掉，
  # 会一直编译仓库 master。必须用 -b <tag> 让 clone 直接落在钉死版本（第一个参数即 -b 值）。
  # 注意 github 镜像 swaywm/wlroots 标签只到 0.14.1，故 wlroots 首选 gitlab（有 0.19.0）。
  git_clone_retry "$WLR_TAG" "$SRC/wayland-src/wlroots" \
    https://gitlab.freedesktop.org/wlroots/wlroots.git https://github.com/swaywm/wlroots.git
  git_clone_retry "$LAB_TAG" "$SRC/wayland-src/labwc" https://github.com/labwc/labwc.git
  # foot 终端（尽力而为）
  git_clone_retry ""         "$SRC/wayland-src/tllist" https://github.com/aitzkora/tllist.git https://codeberg.org/dnkl/tllist.git || true
  git_clone_retry ""         "$SRC/wayland-src/fcft" https://github.com/aitzkora/fcft.git https://codeberg.org/dnkl/fcft.git || true
  git_clone_retry ""         "$SRC/wayland-src/foot" https://codeberg.org/dnkl/foot.git https://github.com/dnkl/foot.git || true
fi

# ---- 媒体栈源码（始终，桌面 + 无桌面共用） ----
MPV_TAG=v0.41.0
# ffmpeg-rockchip 必须锁 9.1（libavcodec 63）：pitch 补丁按此分支的 rkmppdec.c 对齐，
# 跟随默认分支 HEAD 一旦上游改版，补丁会 die 导致构建失败（宁可硬失败不可静默坏镜像）。
FFMPEG_TAG=9.1
git_clone_retry ""         "$SRC/libplacebo" https://github.com/haasn/libplacebo.git
git_clone_retry jellyfin-mpp "$SRC/mpp" https://github.com/nyanmisaka/mpp.git https://gitee.com/nyanmisaka/mpp.git
git_clone_retry jellyfin-rga "$SRC/rkrga" https://github.com/nyanmisaka/rk-mirrors.git https://gitee.com/nyanmisaka/rga.git
git_clone_retry "$FFMPEG_TAG" "$SRC/ffmpeg-rockchip" \
  https://github.com/nyanmisaka/ffmpeg-rockchip.git https://gitee.com/nyanmisaka/ffmpeg-rockchip.git
# 版本校验：-b 分支名不会带 tag，assert_src_tag 不适用；直接核对 libavcodec major=63。
FF_MAJ="$(sed -n 's/^#define[[:space:]]*LIBAVCODEC_VERSION_MAJOR[[:space:]]*//p' "$SRC/ffmpeg-rockchip/libavcodec/version_major.h" 2>/dev/null | head -1 | tr -d '[:space:]')"
[ "$FF_MAJ" = "63" ] || die "ffmpeg-rockchip 版本校验失败：期望 libavcodec 63（9.1），实际 ${FF_MAJ:-未找到}（clone 未落在 $FFMPEG_TAG？）"
log "ffmpeg-rockchip 版本校验 OK: tag=$FFMPEG_TAG / libavcodec=$FF_MAJ"
git_clone_retry "$MPV_TAG" "$SRC/mpv" https://github.com/mpv-player/mpv.git

# ---------------------------------------------------------------------------
# 2. 编译 Wayland 栈（chroot 内）
# ---------------------------------------------------------------------------
if want wayland || want both; then
  log "== 编译 Wayland 栈（wayland-protocols/libxkbcommon/seatd/wlroots/labwc）=="
  # 开发库已由上方 dnf_install_loose 逐个安装（含 libinput-devel 等必需项），此处不再重复 dnf
  # 编译前强制校验钉死版本：一旦 clone 落在错版本（浅克隆曾静默编 master）立即中止，
  # 不再让 meson 走 wrap 拉到不兼容的 wlroots/libinput 版本，浪费十几分钟才发现。
  assert_src_tag "$SRC/wayland-src/wlroots" "$WLR_TAG"
  assert_src_tag "$SRC/wayland-src/labwc"  "$LAB_TAG"

  # 注册 /usr/local/lib64 到动态链接器（libwlroots-0.19.so 等装这里）
  if ! cr "grep -q '/usr/local/lib64' /etc/ld.so.conf.d/*.conf 2>/dev/null"; then
    cr "echo '/usr/local/lib64' > /etc/ld.so.conf.d/usrlocal-lib64.conf && ldconfig"
  fi

  # 2.1~2.4 / 2.7 说明：这些库用 clone 下来的默认分支即可（无版本配对约束），
  # 不再写 git checkout "$(latest_tag ...)" —— --depth=1 浅克隆不带标签，那句必然
  # 失败且被 2>/dev/null 吞掉，是误导性的死代码。真正需要钉版本的 wlroots/labwc
  # 已由 clone 阶段 -b <tag> 落地并断言。
  # 2.1 wayland-protocols（1.50，装到 /usr/local/share/pkgconfig，labwc 0.9.0 要求 >=1.39）
  ( cr "cd /opt/rk-src/wayland-src/wayland-protocols && rm -rf build && meson setup build --prefix=/usr/local -Dtests=false --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "wayland-protocols 编译失败"
  WP_VER="$(cr 'pkg-config --modversion wayland-protocols' 2>/dev/null | tail -1)"
  info "wayland-protocols=$WP_VER"
  # labwc 0.9.0 要求 >=1.39，且 0.9.0 无 wayland-protocols.wrap 兜底。若这里仍是系统
  # 自带的 1.33，说明 /usr/local/share/pkgconfig 未生效，立即中止（别拖到 labwc 才报错）。
  case "$WP_VER" in
    1.[4-9][0-9]*|[2-9]*) : ;;                 # >=1.40 放行
    1.39*) : ;;                                # 1.39 恰好满足
    *) die "wayland-protocols 版本过低：$WP_VER（labwc 0.9.0 要求 >=1.39），检查 /usr/local/share/pkgconfig 是否生效" ;;
  esac

  # 2.2 libxkbcommon（X11 + Wayland 都开：/usr/local/lib 优先级高于 /usr/lib64，
  #     本地库会覆盖系统库，故须同时支持 X11（UKUI 走 X11 需要 libxkbcommon-x11）与 Wayland（labwc））
  ( cr "cd /opt/rk-src/wayland-src/libxkbcommon && rm -rf build && meson setup build --prefix=/usr/local -Denable-x11=true -Denable-wayland=true -Denable-docs=false --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "libxkbcommon 编译失败"
  info "libxkbcommon=$(cr 'pkg-config --modversion xkbcommon')"

  # 2.3 libdisplay-info 已移到媒体栈段（mpv drm VO 硬依赖，无桌面也要编）

  # 2.4 seatd (libseat)
  ( cr "cd /opt/rk-src/wayland-src/seatd && rm -rf build && meson setup build --prefix=/usr/local -Dman-pages=disabled -Dexamples=disabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "seatd 编译失败"

  # 2.5 wlroots（wrap 拉子项目；新版 GCC 对 etnaviv 的 -Werror=strict-aliasing 过敏 → 关 werror）
  # 版本由 clone 阶段 -b "$WLR_TAG" 落在 0.19.0，并已在编译段开头 assert_src_tag 校验。
  # .pc 名是 wlroots-0.19（versioned_name），不是 wlroots，故下面查询须带版本后缀。
  ( cr "cd /opt/rk-src/wayland-src/wlroots && rm -rf build && meson setup build --prefix=/usr/local --wrap-mode=default -Dlibdrm:werror=false -Dlibliftoff:werror=false -Dexamples=false -Dxwayland=enabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "wlroots 编译失败($WLR_TAG)"
  info "wlroots-0.19=$(cr 'pkg-config --modversion wlroots-0.19')"

  # 2.6 labwc —— 版本由 clone 阶段 -b "$LAB_TAG" 落在 0.9.0，开头已 assert_src_tag 校验。
  # -Dicon=disabled：0.9.0 的 icon 选项是 required，开启会经 libsfdo.wrap 去 clone 子项目；
  #   关掉后 libsfdo 依赖变可选，避免联网拉源码引入不确定性（极简合成器也不需要窗口图标）。
  # --wrap-mode=nofallback：wlroots 已装到 /usr/local，强制走系统依赖，杜绝再 clone
  #   wlroots.wrap 拉到 0.20 分支这类版本错配（曾导致 libinput>=1.26 报错）。
  ( cr "cd /opt/rk-src/wayland-src/labwc && rm -rf build && meson setup build --prefix=/usr/local --wrap-mode=nofallback -Dicon=disabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "labwc 编译失败($LAB_TAG)"
  info "labwc=$(cr '/usr/local/bin/labwc --version 2>/dev/null | head -1')"

  # 2.7 foot 终端（尽力而为）
  if [ -d "$SRC/wayland-src/foot" ]; then
    ( cr "cd /opt/rk-src/wayland-src/tllist && rm -rf build && meson setup build --prefix=/usr/local --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) 2>/dev/null || warn "tllist 失败"
    ( cr "cd /opt/rk-src/wayland-src/fcft && rm -rf build && meson setup build --prefix=/usr/local -Ddocs=disabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) 2>/dev/null || warn "fcft 失败"
    ( cr "cd /opt/rk-src/wayland-src/foot && rm -rf build && meson setup build --prefix=/usr/local -Ddocs=disabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) 2>/dev/null && info "foot 已装" || warn "foot 未装成（非致命，xterm via Xwayland 兜底）"
  fi

  # 2.8 XKB 软链修复（防 labwc 段错误 SIGSEGV/exit 139）：自编译 libxkbcommon 默认找
  #      /usr/local/share/X11/xkb（空目录），发行版数据在 /usr/share/X11/xkb
  if [ ! -e "$R/usr/local/share/X11/xkb/rules/evdev" ] && [ -e "$R/usr/share/X11/xkb/rules/evdev" ]; then
    rm -rf "$R/usr/local/share/X11/xkb"
    mkdir -p "$R/usr/local/share/X11"
    ln -sfn /usr/share/X11/xkb "$R/usr/local/share/X11/xkb"
    cr "ldconfig"
    info "XKB 软链已建（防 labwc 段错误）"
  fi

  # 2.9 写 labwc 的 Wayland 会话文件（让 lightdm 能列 Wayland 会话）
  mkdir -p "$R/usr/share/wayland-sessions"
  cat > "$R/usr/share/wayland-sessions/labwc.desktop" <<'EOF'
[Desktop Entry]
Name=labwc
Comment=labwc Wayland compositor (RK35xx, rkmpp)
Exec=labwc
Type=Application
EOF
  chmod 644 "$R/usr/share/wayland-sessions/labwc.desktop"
  info "已写 /usr/share/wayland-sessions/labwc.desktop"
fi

# ---------------------------------------------------------------------------
# 3. 编译 rkmpp 媒体栈（chroot 内；补丁在宿主对源码打）
# ---------------------------------------------------------------------------
log "== 编译 rkmpp 媒体栈（libdisplay-info/libplacebo/mpp/rga/ffmpeg-rockchip/mpv）=="
FFMPEG_LIBDIR=/usr/local/lib/ffmpeg-rkmpp

# 3.0 libdisplay-info（mpv drm VO 硬依赖：meson.build 解析 EDID；桌面/无桌面都编）
( cr "cd /opt/rk-src/libdisplay-info && rm -rf build && meson setup build --prefix=/usr/local --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
  || die "libdisplay-info 编译失败"
cr "pkg-config --exists libdisplay-info" || die "libdisplay-info 装完 pkg-config 找不到（mpv drm VO 会失败）"
info "libdisplay-info=$(cr 'pkg-config --modversion libdisplay-info')"

# 3.1 libplacebo（openEuler 无 -devel，源码编；mpv 0.40+ 硬依赖 >=6.338.2）
( cd "$SRC/libplacebo" && LPTAG="$(git tag -l 'v7.*' | sort -V | awk '$0 <= "v7.391.0"' | tail -1)"
  [ -z "$LPTAG" ] && LPTAG="$(git tag -l 'v6.338.2' | head -1)"
  git checkout "$LPTAG" 2>/dev/null; git submodule update --init --recursive 2>/dev/null || true
  cr "cd /opt/rk-src/libplacebo && rm -rf build && meson setup build --prefix=/usr/local --libdir=/usr/local/lib --buildtype=release -Dvulkan=disabled && ninja -C build install && ldconfig" ) \
  || die "libplacebo 编译失败"
cr "echo /usr/local/lib > /etc/ld.so.conf.d/00-rkmpp-stack.conf && ldconfig"
info "libplacebo=$(cr 'pkg-config --modversion libplacebo')"

# 3.2 mpp
( cd "$SRC/mpp" && mkdir -p build && cd build
  cr "cd /opt/rk-src/mpp/build && cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF .. && make -j$(nproc) && make install && ldconfig" ) \
  || die "mpp 编译失败"
info "MPP=$(cr 'pkg-config --modversion rockchip_mpp')"

# 3.3 rkrga
( cd "$SRC/rkrga"
  cr "cd /opt/rk-src/rkrga && rm -rf build && meson setup build --prefix=/usr/local --libdir=/usr/local/lib --buildtype=release --default-library=shared -Dlibdrm=false -Dlibrga_demo=false && ninja -C build install && ldconfig" ) \
  || die "rkrga 编译失败"
info "RGA=$(cr 'pkg-config --modversion librga')"

# 3.4 ffmpeg-rockchip（隔离到 FFMPEG_LIBDIR）
# 先打 10-bit pitch 修复：上游线性分支把 MPP 的「像素」单位 hor_stride 直接当 DRM「字节」
# pitch 用，NV15/NV20 的 planes[1].offset 与 linesize 全错位 —— 10-bit 零拷贝蓝屏、
# 拷回在 imgutils.c 断言失败都出自这一处（RK3576 板端已实证）。
log "应用 ffmpeg-rockchip 10-bit pitch 补丁"
( cd "$SRC/ffmpeg-rockchip"
  if grep -qs 'rk3576-10bit-pitch' libavcodec/rkmppdec.c; then
    info "pitch 补丁已在（重复执行或上游已含），跳过"
  elif git apply --check "$HERE/ffmpeg-rockchip-10bit-pitch.patch" 2>/dev/null; then
    git apply "$HERE/ffmpeg-rockchip-10bit-pitch.patch" && info "pitch 补丁已应用 (git apply)"
  elif patch -p1 -F 0 --dry-run --forward < "$HERE/ffmpeg-rockchip-10bit-pitch.patch" >/dev/null 2>&1; then
    patch -p1 -F 0 --forward < "$HERE/ffmpeg-rockchip-10bit-pitch.patch" >/dev/null && info "pitch 补丁已应用 (patch -p1)"
  fi
  grep -q 'rk3576-10bit-pitch' libavcodec/rkmppdec.c || {
    echo "pitch 补丁未生效：上游 rkmppdec.c 已改版，需重新对齐 scripts/ffmpeg-rockchip-10bit-pitch.patch"
    exit 1; } ) \
  || die "ffmpeg-rockchip 10-bit pitch 补丁未能生效"

( cd "$SRC/ffmpeg-rockchip"
  cr "export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:/usr/local/share/pkgconfig:\$PKG_CONFIG_PATH; \
      cd /opt/rk-src/ffmpeg-rockchip && ./configure --prefix=/usr/local --libdir=$FFMPEG_LIBDIR \
      --enable-gpl --enable-version3 --enable-nonfree --enable-shared --disable-static \
      --enable-libdrm --enable-rkmpp --enable-rkrga \
      --extra-cflags='-I/usr/local/include' \
      --extra-ldflags='-L/usr/local/lib -L/usr/local/lib64 -Wl,-rpath,$FFMPEG_LIBDIR' \
      --disable-doc --disable-debug --disable-ffplay && make -j\$(nproc) && make install" ) \
  || die "ffmpeg-rockchip 编译失败"
cr "echo $FFMPEG_LIBDIR > /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf && ldconfig"
info "ffmpeg=$(cr '/usr/local/bin/ffmpeg -hide_banner -version 2>/dev/null | head -1')"

# 3.5 mpv 补丁（宿主对 rootfs 内源码打，避免 chroot 看不到仓库补丁）
cd "$SRC/mpv" && git checkout "$MPV_TAG" 2>/dev/null
log "应用 rkmpp 后端补丁"
git apply "$HERE/mpp.patch" 2>/tmp/mpv-patch.err || patch -p1 --forward < "$HERE/mpp.patch" 2>>/tmp/mpv-patch.err \
  || die "mpp.patch 应用失败: $(head -5 /tmp/mpv-patch.err)"
log "应用 vd_lavc-rkmpp-drm 补丁"
git apply "$HERE/vd_lavc-rkmpp-drm.patch" 2>/tmp/vd-patch.err || patch -p1 --forward < "$HERE/vd_lavc-rkmpp-drm.patch" 2>>/tmp/vd-patch.err \
  || die "vd_lavc-rkmpp-drm.patch 应用失败: $(head -5 /tmp/vd-patch.err)"

# 3.6 mpv 编译（桌面：x11+drm+wayland 三后端；无桌面 media-only：仅 drm，避免链到未编译的桌面库）
WP_VER="$(cr 'pkg-config --modversion wayland-protocols 2>/dev/null')"
[ -z "$WP_VER" ] && WP_VER=0
WL_BUILD=enabled
if [ "$MEDIA_ONLY" = 1 ]; then
  WL_BUILD=disabled
elif [ "$(printf '%s\n' 1.34 "$WP_VER" | sort -V | head -1)" != "1.34" ]; then
  WL_BUILD=disabled
  warn "wayland-protocols=$WP_VER < 1.34，mpv wayland 后端关闭（应已升级到 1.50，若到此告警请查编译）"
fi
_X11=""
[ "${MPV_X11:-1}" = "1" ] && _X11="-Dx11=enabled -Dgl-x11=enabled -Degl-x11=enabled"
[ "$MEDIA_ONLY" = 1 ] && info "media-only：mpv 仅 drm 后端（x11/wayland 关闭），供 mpv-auto 的 KMS 链使用"
( cd "$SRC/mpv"
  cr "export PKG_CONFIG_PATH=$FFMPEG_LIBDIR/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/local/lib64/pkgconfig:\$PKG_CONFIG_PATH; \
      export LDFLAGS='-Wl,-rpath,/usr/local/lib -Wl,-rpath,/usr/local/lib64'; \
      cd /opt/rk-src/mpv && rm -rf build && meson setup build --prefix=/usr/local --buildtype=release \
      $_X11 -Ddrm=enabled -Dwayland=$WL_BUILD -Dalsa=enabled -Dgpl=true -Dlibmpv=true -Dlua=disabled \
      && ninja -C build install && ldconfig" ) \
  || die "mpv 编译失败"
cr "ldconfig"
info "mpv=$(cr '/usr/local/bin/mpv --version 2>/dev/null | head -1')"
if ! cr "/usr/local/bin/mpv --hwdec=help 2>/dev/null | grep -q rkmpp"; then
  die "rkmpp hwdec 未出现（补丁未生效或 ffmpeg-rockchip 头文件未找到）"
fi
info "rkmpp hwdec 校验通过"

# ---------------------------------------------------------------------------
# 4. 桌面环境：UKUI(X11)（both / x11）
# ---------------------------------------------------------------------------
if want x11 || want both; then
  log "安装 UKUI 桌面（X11）"
  cr "$DNFC install ukui" >/tmp/desktop-ukui.log 2>&1 \
    || { tail -20 /tmp/desktop-ukui.log >&2; die "UKUI 安装失败"; }
  info "UKUI 已装"
fi

# ---------------------------------------------------------------------------
# 5. 显示管理器：lightdm（统一，autologin 到 admin 用户）—— media-only 跳过
# ---------------------------------------------------------------------------
if [ "$MEDIA_ONLY" = 0 ]; then
log "安装并配置 lightdm（autologin -> $ADMIN_USER）"
cr "$DNFC install lightdm" >/tmp/desktop-lightdm.log 2>&1 \
  || { tail -20 /tmp/desktop-lightdm.log >&2; die "lightdm 安装失败"; }

# 默认会话：both/wayland -> labwc(Wayland)；x11 -> ukui(X11)
DEF_SESSION=labwc
want x11 && ! want both && DEF_SESSION=ukui
[ "$KIOSK" = "1" ] && DEF_SESSION=labwc

mkdir -p "$R/etc/lightdm/lightdm.conf.d"
cat > "$R/etc/lightdm/lightdm.conf.d/10-autologin.conf" <<EOF
[Seat:*]
autologin-user=$ADMIN_USER
autologin-user-timeout=0
autologin-session=$DEF_SESSION
user-session=$DEF_SESSION
EOF
info "lightdm autologin -> $ADMIN_USER / session=$DEF_SESSION"
fi

# X11（UKUI）显示配置：modesetting + glamor（走 panfrost GLES）
if want x11 || want both; then
  mkdir -p "$R/etc/X11/xorg.conf.d"
  cat > "$R/etc/X11/xorg.conf.d/99-rockchip.conf" <<'EOF'
Section "Device"
    Identifier "Rockchip DRM"
    Driver "modesetting"
    Option "AccelMethod" "glamor"
EndSection
EOF
  info "已写 X11 modesetting+glamor 配置"
fi

# ---------------------------------------------------------------------------
# 6. seatd（labwc/Wayland 需要）：装 + admin 入 seat 组 + 启用
# ---------------------------------------------------------------------------
if want wayland || want both; then
  log "配置 seatd"
  getent group seat >/dev/null 2>&1 || cr "groupadd -r seat"
  if id -u "$ADMIN_USER" >/dev/null 2>&1; then
    cr "usermod -aG seat $ADMIN_USER"
    info "$ADMIN_USER 已入 seat 组"
  else
    warn "用户 $ADMIN_USER 不存在（可能首启才建），跳过入组；请确认 ADMIN_USER 与 build-image.sh 一致"
  fi
  # 启用 seatd.service（建 wants 软链，chroot 内 systemctl enable 不可靠）
  mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
  if [ -f "$R/usr/lib/systemd/system/seatd.service" ]; then
    ln -sf /usr/lib/systemd/system/seatd.service "$R/etc/systemd/system/multi-user.target.wants/seatd.service"
    info "seatd.service 已启用"
  else
    warn "找不到 seatd.service，labwc 可能需 logind 后端（seatd 未启用）"
  fi
fi

# ---------------------------------------------------------------------------
# 7. mpv 运行时配置 + mpv-auto（后端链：真判活 + 失败逐级降级）
# ---------------------------------------------------------------------------
log "写 mpv.conf / udev / mpv-auto"
mkdir -p "$R/etc/mpv"
cat > "$R/etc/mpv/mpv.conf" <<'EOF'
# RK35xx RKMPP 硬件加速配置（X11 / Wayland / DRM headless 通用）
hwdec=rkmpp
hwdec-codecs=all
vo=gpu
profile=fast
cache=yes
cache-secs=60
demuxer-max-bytes=50M
sub-font-size=35
# 10-bit(NV15) 内容必须降位为 NV12，否则黑屏；8-bit 近乎零成本
vf=lavfi=[scale_rkrga=force_yuv=8bit]
EOF

cat > "$R/etc/udev/rules.d/99-mpp.rules" <<'EOF'
KERNEL=="mpp_service", MODE="0666"
KERNEL=="rga", MODE="0666"
EOF

cat > "$R/usr/local/bin/mpv-auto" <<'EOF'
#!/usr/bin/env bash
# 显示后端选择链：先按会话挑链，再逐级试；只有 mpv 没能建立显示才降级，出过画面就认定后端无罪。
#
# 覆盖入口：
#   MPV_AUTO_BACKEND=<名>  钉死单后端、不降级（板级对比实测用）
#   MPV_AUTO_CONNECTOR / MPV_AUTO_MODE  覆盖 KMS 输出（默认 HDMI-A-1 / mode 1）
#   MPV_AUTO_STATE=<路径>  记录最终后端，默认 /run/mpv-auto.backend
set -u
MPV="$(command -v mpv 2>/dev/null || echo /usr/local/bin/mpv)"
CONN="${MPV_AUTO_CONNECTOR:-HDMI-A-1}"
MODE="${MPV_AUTO_MODE:-1}"
STATE="${MPV_AUTO_STATE:-/run/mpv-auto.backend}"
LOG="$(mktemp "${TMPDIR:-/tmp}/mpv-auto.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
say() { printf 'mpv-auto: %s\n' "$*" >&2; }

BACKENDS="wl-copy wl-zero wl-soft x11-copy x11-zero x11-soft kms-zero kms-copy kms-rga soft-drm"
spec() {
  case "$1" in
    # 会话态：合成器已占 DRM master，只能在会话内选解码路径
    wl-copy)   echo "--gpu-context=wayland --hwdec=rkmpp-copy" ;;
    wl-zero)   echo "--gpu-context=wayland --hwdec=rkmpp" ;;
    wl-soft)   echo "--gpu-context=wayland --hwdec=no" ;;
    x11-copy)  echo "--gpu-context=x11egl --hwdec=rkmpp-copy" ;;
    x11-zero)  echo "--gpu-context=x11egl --hwdec=rkmpp" ;;
    x11-soft)  echo "--gpu-context=x11egl --hwdec=no" ;;
    # 无桌面/服务态：零拷贝 -> 拷回 -> RGA+KMS 直出 -> 软解
    kms-zero)  echo "--hwdec=rkmpp --vo=gpu --gpu-context=drm --drm-connector=$CONN --drm-mode=$MODE" ;;
    kms-copy)  echo "--hwdec=rkmpp-copy --vo=gpu --gpu-context=drm --drm-connector=$CONN --drm-mode=$MODE" ;;
    kms-rga)   echo "--hwdec=rkmpp-copy --vo=drm --drm-connector=$CONN --drm-mode=$MODE" ;;
    soft-drm)  echo "--hwdec=no --vo=drm --drm-connector=$CONN --drm-mode=$MODE" ;;
    *)         return 1 ;;
  esac
}

for a in "$@"; do
  case "$a" in
    --vo=*|--gpu-context=*) exec "$MPV" "$@" ;;
    --version|--help)       exec "$MPV" "$@" ;;
    --backends)             echo $BACKENDS; exit 0 ;;
  esac
done

chain=()
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  sock="${WAYLAND_DISPLAY#unix:}"
  # wl-copy 排在零拷贝前：mutter 与 rkvdec 的 dmabuf 互操作在 3576 实测持续播放必崩，
  # 崩在运行中而非启动时，链式降级兜不住，只能默认绕开。
  [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$sock" ] && chain=(wl-copy wl-zero wl-soft)
fi
if [ ${#chain[@]} -eq 0 ] && [ -n "${DISPLAY:-}" ] \
   && "$MPV" --gpu-context=help 2>/dev/null | grep -q x11egl; then
  chain=(x11-copy x11-zero x11-soft)
fi
if [ ${#chain[@]} -eq 0 ]; then
  if [ -d /dev/dri ]; then chain=(kms-zero kms-copy kms-rga soft-drm); else chain=(soft-drm); fi
fi
if [ -n "${MPV_AUTO_BACKEND:-}" ]; then
  spec "$MPV_AUTO_BACKEND" >/dev/null 2>&1 || { say "未知后端 '$MPV_AUTO_BACKEND'，可用：$BACKENDS"; exit 2; }
  chain=("$MPV_AUTO_BACKEND")
else
  # 上次成功的后端放链首：GPU 起不来的板子不必每次播放都白撞前几级。
  # 只认同一条链内的缓存——会话态与无桌面的后端互斥（合成器占 DRM master），跨链提权会白试。
  prev="$(cat "$STATE" 2>/dev/null || true)"
  in_chain=0
  for c in "${chain[@]}"; do [ "$c" = "$prev" ] && in_chain=1; done
  if [ "$in_chain" -eq 1 ] && [ "${chain[0]}" != "$prev" ]; then
    rest=()
    for c in "${chain[@]}"; do [ "$c" != "$prev" ] && rest+=("$c"); done
    chain=("$prev" "${rest[@]}")
  fi
fi

for b in "${chain[@]}"; do
  say "后端=$b"
  read -r -a opts <<<"$(spec "$b")"
  "$MPV" "${opts[@]}" "$@" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$b" > "$STATE" 2>/dev/null || :
    exit 0
  fi
  # mpv 打出 "VO: [xxx] WxH ..." 就说明显示后端真建起来了，失败在片源/其它环节
  if grep -qE '^VO: \[' "$LOG"; then
    say "后端 $b 已建立显示，退出码 $rc 与后端无关，不降级"
    exit "$rc"
  fi
  if grep -qiE 'Failed to open|No such file|unrecognized file format' "$LOG"; then
    say "片源打不开，与显示后端无关，不降级"
    exit "$rc"
  fi
  : > "$LOG"
  say "后端 $b 未能建立显示 -> 降级"
done
say "后端链全部失败"
exit 1
EOF
chmod +x "$R/usr/local/bin/mpv-auto"

# mpv 桌面入口
cat > "$R/usr/share/applications/mpv.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=mpv
Name[zh_CN]=mpv 播放器
GenericName=Media Player
Comment=RKMPP hardware-accelerated video player
Exec=/usr/local/bin/mpv --player-operation-mode=pseudo-gui --no-fullscreen --force-window=yes %U
TryExec=/usr/local/bin/mpv
Terminal=false
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/webm;video/quicktime;video/x-msvideo;video/mp2t;audio/mpeg;audio/flac;
EOF
chmod 644 "$R/usr/share/applications/mpv.desktop"
info "mpv-auto / mpv.conf / udev 已写"

# ---------------------------------------------------------------------------
# 7.6 USB 自动挂载 + audio-switch 音频出口切换（headless/桌面通用系统工具）
#   参考脚本：setup-usb-automount.sh（U 盘/移动硬盘即插即挂 + 开机补挂）、
#             audio-switch.sh（写 /etc/asound.conf 切换 3.5mm/HDMI/SPDIF）。
#   注意：chroot 内 systemctl enable / udevadm 不可靠，故按本仓库惯例直接写
#         udev 规则文件 + 建 multi-user.target.wants 软链，开机由 systemd/udev 自行加载。
#   media-only 与桌面都写：U 盘片源与音频出口在两种模式下都需要。
# ---------------------------------------------------------------------------
log "写 USB 自动挂载 + audio-switch"

# USB 文件系统驱动：exFAT/NTFS 是测试 U 盘常见格式，缺则挂载助手 SKIP
dnf_install_loose ntfs-3g exfatprogs usbutils

# 挂载助手：udev 回调(usb-automount %k) + 手动补挂(usb-automount sda1)，幂等
cat > "$R/usr/local/bin/usb-automount" <<'USBAUTOEOF'
#!/usr/bin/env bash
# udev 回调：usb-automount <kernel名>  挂载 | usb-automount --remove <kernel名>  卸载
# 手动补挂：usb-automount sda1（开机服务也是逐个分区调它）
set -u
LOG=/var/log/usb-automount.log
say(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
[ $# -ge 1 ] || exit 0

if [ "$1" = "--remove" ]; then
    dev="/dev/$2"
    mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null | head -1)
    [ -n "$mp" ] && umount -l "$dev" && rmdir "$mp" 2>/dev/null
    say "REMOVE $dev -> ${mp:-未挂载}"
    exit 0
fi

dev="/dev/$1"
# 已挂载则跳过（天然幂等：重复调用直接退出）
findmnt -n "$dev" >/dev/null 2>&1 && exit 0
# 分区就绪等待：慢盘/大移动硬盘识别慢，最长 10 秒（0.5s × 20）
WAIT=10
for i in $(seq 1 $((WAIT*2))); do
    fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
    [ -n "$fstype" ] && break
    sleep 0.5
done
[ -n "$fstype" ] || { say "TIMEOUT $dev 分区就绪超时"; exit 0; }
label=$(blkid -o value -s LABEL "$dev" 2>/dev/null | tr -cd '[:alnum:]_-')
mp="/mnt/usb${label:+-$label}"

mkdir -p "$mp"
case "$fstype" in
    ext4|ext3|ext2) mount "$dev" "$mp" ;;
    vfat|fat32)     mount -o iocharset=utf8,uid=1000,gid=1000,umask=022 "$dev" "$mp" ;;
    exfat)          mount -o uid=1000,gid=1000,umask=022 "$dev" "$mp" ;;
    ntfs)           mount -t ntfs-3g -o remove_hiberfile,big_writes,uid=1000,gid=1000,umask=022 "$dev" "$mp" ;;
    *)              say "SKIP $dev 未知文件系统 $fstype"; exit 0 ;;
esac
say "ADD $dev -> $mp ($fstype)"
USBAUTOEOF
chmod +x "$R/usr/local/bin/usb-automount"

cat > "$R/etc/udev/rules.d/99-usb-automount.rules" <<'USBRULEEOF'
# USB 存储自动挂载（integrate-desktop.sh 写入）
ACTION=="add",    SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_TYPE}!="", \
    RUN+="/usr/local/bin/usb-automount %k"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", \
    RUN+="/usr/local/bin/usb-automount --remove %k"
USBRULEEOF

# 开机补挂：udev add 只在"插入瞬间"触发，开机时已插的盘靠这个 oneshot 轮询补挂
cat > "$R/usr/local/bin/usb-automount-boot" <<'USBOOTEOF'
#!/usr/bin/env bash
# 开机轮询未挂载的 USB 分区(sd*)，挂完全部或超时 5 分钟即退出
for round in $(seq 1 60); do
    did_something=0
    for sys in /sys/class/block/sd*; do
        [ -e "$sys/partition" ] || continue          # 只要分区，不要整盘
        k=$(basename "$sys")
        findmnt -n "/dev/$k" >/dev/null 2>&1 && continue
        /usr/local/bin/usb-automount "$k" && did_something=1
    done
    [ "$did_something" = 0 ] && exit 0               # 一轮无待处理项 = 全挂完
    sleep 5
done
echo "$(date '+%F %T') BOOT-TIMEOUT 仍有未挂载 USB 分区" >> /var/log/usb-automount.log
USBOOTEOF
chmod +x "$R/usr/local/bin/usb-automount-boot"

cat > "$R/etc/systemd/system/usb-automount-boot.service" <<'USBSVCEOF'
[Unit]
Description=USB storage auto mount at boot
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/usb-automount-boot

[Install]
WantedBy=multi-user.target
USBSVCEOF
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/usb-automount-boot.service \
  "$R/etc/systemd/system/multi-user.target.wants/usb-automount-boot.service"

# audio-switch：命令式切换默认音频出口（写 /etc/asound.conf，全部应用跟随）
cat > "$R/usr/local/bin/audio-switch" <<'AUDIOSWEOF'
#!/usr/bin/env bash
# audio-switch —— RK3576/35xx 音频出口切换（3.5mm / HDMI / SPDIF）
# 原理：写 /etc/asound.conf 把 alsa "default" 指向目标卡，全部应用跟随；
#       卡名从 /proc/asound/cards 按卡号自动探测（换板无需改声卡名，探测失败回退内建名）；
#       3.5mm 若存在 HT5010 控件（numid=31/3）则自动补路由，其他 codec 自动跳过。
# 用法：
#   audio-switch 3.5|hdmi|spdif   切换（需 root）
#   audio-switch status           查看当前出口
#   audio-switch test             播 3 秒 1kHz 测试音（需 mpv 或 speaker-test）
set -u
CONF=/etc/asound.conf

get_cur() { [ -f "$CONF" ] && grep -o 'hw:[A-Za-z_0-9]*' "$CONF" | head -1 || echo "未配置"; }

# 从 /proc/asound/cards 按声卡「名字」定位卡号（不是写死 card0/1/2）。
# 实测 RK3588 板上 card0=rockchiphdmiin(HDMI 输入)、card1=realtekrt5616co(3.5mm)、card2=hdmi0，
# 若照搬固定卡号会把 3.5mm 误指向 HDMI-IN。按名字匹配 + 排除关键字，跨板通用。
# card_pick <包含正则> <排除正则> → 首个匹配的卡号
card_pick() {
    awk -v inc="$1" -v exc="${2:-}" '
        $1 ~ /^[0-9]+$/ {
            name=$2; gsub(/^\[|\]:?$/, "", name); low=tolower(name)
            if (low ~ inc && (exc == "" || low !~ exc)) { print $1; exit }
        }' /proc/asound/cards 2>/dev/null
}

# 从 /proc/asound/cards 按卡号取真实卡名（如 " 1 [realtekrt5616co]:" → realtekrt5616co）
card_name() {
    awk -v n="$1" '$1 == n { gsub(/^\[|\]:?$/, "", $2); print $2; exit }' /proc/asound/cards 2>/dev/null
}

# HT5010 专属路由：仅当声卡上存在 numid=31 控件才设置（其他 codec / 未装 amixer 自动跳过）
fix_ht5010_route() {
    command -v amixer >/dev/null 2>&1 || return 0
    local probe
    probe="$(amixer -c "$1" cget numid=31 2>&1)"
    echo "$probe" | grep -q 'numid=31' || return 0   # 没拿到真实控件 → 跳过
    amixer -c "$1" cset numid=31 0 >/dev/null 2>&1   # Transmit SDO2 Source = From PATH0
    amixer -c "$1" cset numid=3  0 >/dev/null 2>&1   # SDIx Select = Auto（非 Auto 会算出 bclk=0）
}

do_switch() {
    local name="$1" inc="$2" exc="$3"
    local num card
    num="$(card_pick "$inc" "$exc")"
    [ -n "$num" ] || { echo "未找到 $name 对应声卡（audio-switch list 查看）"; return 1; }
    card="$(card_name "$num")"
    cat > "$CONF.tmp" << EOF
# 由 audio-switch 生成（$(date '+%F %T')）：默认输出 → $name (card$num: $card)
pcm.!default {
    type plug
    slave.pcm "hw:$card"
}
ctl.!default {
    type hw
    card $card
}
EOF
    mv "$CONF.tmp" "$CONF" || { echo "写 $CONF 失败（需要 root）"; return 1; }
    case "$inc" in *rt5616*|*es8388*|*ht5010*) fix_ht5010_route "$num" ;; esac
    echo "已切换默认音频出口 → $name (hw:$card / card$num)"
    echo "   当前 $CONF: $(get_cur)"
    echo "   验证：audio-switch status；听音用 audio-switch test 或直接播片"
}

case "${1-}" in
    list|ls)
        echo "== 声卡清单（卡号 / 名字）=="; cat /proc/asound/cards ;;
    3.5|35|3.5mm)  do_switch "3.5mm(板载 codec)" 'rt5616|es8388|es8323|ht5010|wm8960|audio|codec' 'hdmi|dp|in|usb' ;;
    hdmi)          do_switch "HDMI"   'hdmi' 'in' ;;
    spdif|spdif-out) do_switch "SPDIF" 'spdif|iec958|digital' '' ;;
    status)
        echo "== 声卡清单 =="; cat /proc/asound/cards
        echo "== 当前默认 =="; get_cur
        if command -v amixer >/dev/null 2>&1; then
            probe="$(amixer -c 0 cget numid=31 2>&1)"
            if echo "$probe" | grep -q 'numid=31'; then
                for id in 31 3; do
                    v="$(amixer -c 0 cget numid=$id 2>/dev/null | grep -o 'values=[0-9]*' | head -1)"
                    echo "   HT5010 numid=$id: ${v:-?}（应为 values=0）"
                done
            else
                echo "   （未检测到 HT5010 控件 或 声卡不可访问：$(echo "$probe" | head -1)）"
            fi
        else
            echo "   （未装 alsa-utils，无法读 HT5010 路由）"
        fi ;;
    test)
        if command -v mpv >/dev/null 2>&1; then
            mpv --no-config --vo=null --ao=alsa --audio-device=alsa/default \
                --msg-level=ao=no 'av://lavfi:sine=frequency=1000:duration=3' 2>/dev/null \
                && echo "测试音已播 3 秒（1kHz）"
        elif command -v speaker-test >/dev/null 2>&1; then
            speaker-test -c2 -twav -l1 2>/dev/null | tail -1
        else
            echo "无 mpv / speaker-test，无法播测试音（dnf install alsa-utils 后再试）"
        fi ;;
    *)
        echo "用法:"
        echo "  audio-switch list   # 列出声卡（卡号/名字，选出口前先看）"
        echo "  audio-switch 3.5    # 切 3.5mm（按名字匹配板载 codec，自动补 HT5010 路由）"
        echo "  audio-switch hdmi   # 切 HDMI（排除 HDMI-IN，不会误切输入卡）"
        echo "  audio-switch spdif  # 切 SPDIF"
        echo "  audio-switch status # 查看当前出口与路由"
        echo "  audio-switch test   # 播 3 秒测试音验证"
        exit 1 ;;
esac
AUDIOSWEOF
chmod +x "$R/usr/local/bin/audio-switch"

info "USB 自动挂载(udev+开机 service)、audio-switch 已写入 /usr/local/bin"

# ---------------------------------------------------------------------------
# 7.5 kiosk 展示模式（可选）：labwc 会话 autostart 直接全屏播 mpv
# ---------------------------------------------------------------------------
if [ "$KIOSK" = "1" ]; then
  log "启用 kiosk 展示模式（开机自动全屏播 mpv）"
  DEF_SESSION=labwc

  # kiosk 播放脚本：自动探测视频目录（/home/*/Videos 或 /opt/kiosk），可用 KIOSK_VIDEO 直接指定单个文件
  cat > "$R/usr/local/bin/kiosk-play.sh" <<'KOEOF'
#!/bin/sh
# kiosk 展示：全屏循环播放视频（rk35xx rkmpp 硬解 + wayland 后端）
# 可用环境变量 KIOSK_VIDEO=<单个文件> 或 KIOSK_DIR=<目录> 覆盖默认探测
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
VIDEO="${KIOSK_VIDEO:-}"
DIR="${KIOSK_DIR:-}"
if [ -z "$DIR" ]; then
  for d in /home/*/Videos /opt/kiosk; do
    [ -d "$d" ] && DIR="$d" && break
  done
fi
if [ -z "$VIDEO" ] && [ -n "$DIR" ]; then
  VIDEO=$(find "$DIR" -maxdepth 2 -iname '*.mp4' 2>/dev/null | head -1)
fi
while true; do
  if [ -n "$VIDEO" ]; then
    mpv --no-terminal --fs --loop=inf --hwdec=rkmpp --vo=gpu --profile=fast \
      --no-border --cursor-autohide=always "$VIDEO"
  fi
  # 无视频时安静等待：每 5 秒重探测目录，直到出现 mp4 再播（不刷日志）
  if [ -z "$VIDEO" ]; then
    [ -z "$DIR" ] && for d in /home/*/Videos /opt/kiosk; do [ -d "$d" ] && DIR="$d" && break; done
    VIDEO=$( [ -n "$DIR" ] && find "$DIR" -maxdepth 2 -iname '*.mp4' 2>/dev/null | head -1 )
  fi
  sleep 5
done
KOEOF
  # 构建期固化指定视频：把 --kiosk-video 值注入脚本（运行时优先于目录探测）
  if [ -n "$KIOSK_VIDEO" ]; then
    sed -i "1a KIOSK_VIDEO='$KIOSK_VIDEO'" "$R/usr/local/bin/kiosk-play.sh"
    info "已固化 KIOSK_VIDEO=$KIOSK_VIDEO 进 kiosk-play.sh"
  fi
  chmod 755 "$R/usr/local/bin/kiosk-play.sh"
  info "kiosk-play.sh 已写（默认探测 /home/*/Videos 或 /opt/kiosk，可用 KIOSK_VIDEO 覆盖）"

  # labwc autostart：系统级兜底 + 用户级（lightdm autologin 到 $ADMIN_USER 时读此处）
  mkdir -p "$R/etc/xdg/labwc"
  cat > "$R/etc/xdg/labwc/autostart" <<'KOEOF'
#!/bin/sh
/usr/local/bin/kiosk-play.sh &
KOEOF
  chmod 755 "$R/etc/xdg/labwc/autostart"
  if id -u "$ADMIN_USER" >/dev/null 2>&1 && [ -d "$R/home/$ADMIN_USER" ]; then
    mkdir -p "$R/home/$ADMIN_USER/.config/labwc"
    cp "$R/etc/xdg/labwc/autostart" "$R/home/$ADMIN_USER/.config/labwc/autostart"
    chmod 755 "$R/home/$ADMIN_USER/.config/labwc/autostart"
    cr "chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER/.config" 2>/dev/null || true
    info "用户级 autostart 已写 /home/$ADMIN_USER/.config/labwc/autostart"
  fi
  info "kiosk：labwc 会话启动后直接全屏播放 mpv"
fi

# ---------------------------------------------------------------------------
# 8. 设为图形界面默认启动 + 启用 lightdm —— media-only 跳过（headless 保持 multi-user.target）
# ---------------------------------------------------------------------------
if [ "$MEDIA_ONLY" = 0 ]; then
log "设置 graphical.target 默认 + 启用 lightdm"
# default.target -> graphical.target（chroot 内 systemctl set-default 不可靠，直接建软链）
ln -sf /usr/lib/systemd/system/graphical.target "$R/etc/systemd/system/default.target" 2>/dev/null || true
mkdir -p "$R/etc/systemd/system/graphical.target.wants"
if [ -f "$R/usr/lib/systemd/system/lightdm.service" ]; then
  ln -sf /usr/lib/systemd/system/lightdm.service "$R/etc/systemd/system/graphical.target.wants/lightdm.service"
  info "lightdm.service 已启用（graphical.target）"
else
  warn "找不到 lightdm.service，未启用显示管理器"
fi
fi

# ---------------------------------------------------------------------------
# 9. 清理
# ---------------------------------------------------------------------------
log "清理 dnf 缓存"
cr "dnf clean all" >/dev/null 2>&1 || true
rm -rf "$R/var/cache/dnf"/* "$R/var/cache/yum"/* 2>/dev/null || true
rm -rf "$R/tmp"/* 2>/dev/null || true

info "集成后 rootfs: $(du -sh "$R" | cut -f1)"
if [ "$MEDIA_ONLY" = 1 ]; then
  log "无桌面媒体栈集成完成（media-only）"
  info "模式: headless / mpv 后端: drm / 播放器入口: /usr/local/bin/mpv-auto（KMS 直控 + rkmpp）"
  info "ffmpeg-rockchip: $FFMPEG_TAG (libavcodec $FF_MAJ) / mpv: $MPV_TAG / pitch 补丁已入链"
else
  log "桌面集成安装完成"
  _KIOSK_TAG=""
  [ "$KIOSK" = "1" ] && _KIOSK_TAG=" / kiosk=开"
  info "桌面组合: $FLAVOR / autologin: $ADMIN_USER / 会话: ${DEF_SESSION:-无}$_KIOSK_TAG"
  info "mpv 三后端: drm + x11egl + wayland（rkmpp 硬解）"
  info "ffmpeg-rockchip: $FFMPEG_TAG (libavcodec $FF_MAJ) / mpv: $MPV_TAG / pitch 补丁已入链"
fi
