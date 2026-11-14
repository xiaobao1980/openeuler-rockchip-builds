#!/usr/bin/env bash
# ============================================================================
# 集成安装：把 X11(UKUI) + Wayland(labwc) 双桌面 + rkmpp 媒体栈烘焙进「离线 rootfs」
#
# 与 integrate-iot.sh 同接口：
#   sudo bash integrate-desktop.sh <rootfs目录> [--flavor=both|x11|wayland] [--mpv-x11=1] [--admin-user=iot] [--kiosk=0|1] [--kiosk-video=<文件>]
#
# 设计要点：
#   ① 由 build-image.sh 在 chroot 已挂载的前提下调用；本脚本再做幂等挂载 + resolv 修复
#   ② git clone 在宿主机跑（runner 网络更稳），编译（meson/ninja/cmake）在 chroot 内跑
#   ③ mpv 补丁在宿主机对 $R/opt/rk-src/mpv 打（chroot 内看不到仓库 scripts/ 路径）
#   ④ wayland-protocols 源码升级到 1.50 → mpv wayland 后端自动开启；mpv 已 -Dx11=enabled
#      → 最终 mpv 三后端（drm + x11egl + wayland）全开，rkmpp 硬解零拷贝
#   ⑤ lightdm 统一显示管理器：autologin-user=<admin> 进选定会话（both 默认 labwc/Wayland）
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
for a in "$@"; do
  case "$a" in
    --flavor=*)       FLAVOR="${a#*=}" ;;
    --mpv-x11=*)      MPV_X11="${a#*=}" ;;
    --admin-user=*)   ADMIN_USER="${a#*=}" ;;
    --kiosk=*)        KIOSK="${a#*=}" ;;
    --kiosk-video=*)  KIOSK_VIDEO="${a#*=}" ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

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

# chroot 内执行编译/安装命令
cr() {
  chroot "$R" /usr/bin/env -i \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME=/root LANG=C.UTF-8 \
    bash -c "$*"
}

log "目标系统: $(grep -E '^(PRETTY_NAME)=' "$R/etc/os-release" | cut -d= -f2- | tr -d '\"')"
log "桌面组合: $FLAVOR（autologin 用户: $ADMIN_USER）"

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

# 开发库与运行时（缺失不致命，后续编译按需报错）。
# 注意：seatd / libseat-devel 在 openEuler 仓库不存在（本就要源码编译），务必剔除，否则 dnf 因 No match 整笔中止。
cr "$DNFC install \
  libdrm-devel expat-devel libffi-devel \
  libX11-devel libXext-devel libXrandr-devel libXv-devel libxcb-devel \
  xcb-util-wm-devel xcb-util-renderutil-devel xcb-util-keysyms-devel xcb-util-image-devel xcb-util-cursor-devel \
  wayland-devel wayland-protocols-devel libxkbcommon-devel libxkbcommon \
  libinput-devel pixman-devel libxml2-devel cairo-devel pango-devel glib2-devel \
  freetype-devel fontconfig-devel mesa-libGL-devel mesa-libEGL-devel mesa-libgbm-devel \
  libass-devel uchardet-devel lua-devel x264-devel x265-devel libdav1d-devel gnutls-devel \
  libudev-devel systemd-devel hwdata \
  xorg-x11-server-Xwayland xorg-x11-server-Xwayland-devel xterm" >/tmp/desktop-dnf.log 2>&1 \
  || { tail -30 /tmp/desktop-dnf.log >&2; warn "部分开发库安装失败，后续阶段按需报错"; }

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
latest_tag(){ git -C "$1" tag -l | sort -V | tail -1; }
tag_ge(){ git -C "$1" tag -l "$2" | sort -V | tail -1; }

# ---- Wayland 栈源码（both / wayland） ----
if want wayland || want both; then
  mkdir -p "$SRC/wayland-src"
  git_clone_retry ""         "$SRC/wayland-src/wayland-protocols" \
    https://gitlab.freedesktop.org/wayland/wayland-protocols.git https://github.com/wayland-project/wayland-protocols.git
  git_clone_retry ""         "$SRC/wayland-src/libxkbcommon" https://github.com/xkbcommon/libxkbcommon.git
  git_clone_retry ""         "$SRC/wayland-src/libdisplay-info" \
    https://gitlab.freedesktop.org/emersion/libdisplay-info.git https://github.com/emersion/libdisplay-info.git
  git_clone_retry ""         "$SRC/wayland-src/seatd" https://github.com/kennylevinsen/seatd.git
  git_clone_retry ""         "$SRC/wayland-src/wlroots" \
    https://gitlab.freedesktop.org/wlroots/wlroots.git https://github.com/swaywm/wlroots.git
  git_clone_retry ""         "$SRC/wayland-src/labwc" https://github.com/labwc/labwc.git
  # foot 终端（尽力而为）
  git_clone_retry ""         "$SRC/wayland-src/tllist" https://github.com/aitzkora/tllist.git https://codeberg.org/dnkl/tllist.git || true
  git_clone_retry ""         "$SRC/wayland-src/fcft" https://github.com/aitzkora/fcft.git https://codeberg.org/dnkl/fcft.git || true
  git_clone_retry ""         "$SRC/wayland-src/foot" https://codeberg.org/dnkl/foot.git https://github.com/dnkl/foot.git || true
fi

# ---- 媒体栈源码（始终，桌面硬解） ----
MPV_TAG=v0.41.0
git_clone_retry ""         "$SRC/libplacebo" https://github.com/haasn/libplacebo.git
git_clone_retry jellyfin-mpp "$SRC/mpp" https://github.com/nyanmisaka/mpp.git https://gitee.com/nyanmisaka/mpp.git
git_clone_retry jellyfin-rga "$SRC/rkrga" https://github.com/nyanmisaka/rk-mirrors.git https://gitee.com/nyanmisaka/rga.git
git_clone_retry ""         "$SRC/ffmpeg-rockchip" \
  https://github.com/nyanmisaka/ffmpeg-rockchip.git https://gitee.com/nyanmisaka/ffmpeg-rockchip.git
git_clone_retry "$MPV_TAG" "$SRC/mpv" https://github.com/mpv-player/mpv.git

# ---------------------------------------------------------------------------
# 2. 编译 Wayland 栈（chroot 内）
# ---------------------------------------------------------------------------
if want wayland || want both; then
  log "== 编译 Wayland 栈（wayland-protocols/libxkbcommon/libdisplay-info/seatd/wlroots/labwc）=="
  cr "$DNFC install libX11-devel libXext-devel libXrandr-devel libXv-devel libxcb-devel \
      wayland-devel wayland-protocols-devel libxkbcommon-devel libinput-devel libxkbcommon \
      mesa-libEGL-devel mesa-libGL-devel mesa-libgbm-devel libudev-devel systemd-devel" >/dev/null 2>&1 || true

  # 注册 /usr/local/lib64 到动态链接器（libwlroots-0.19.so 等装这里）
  if ! cr "grep -q '/usr/local/lib64' /etc/ld.so.conf.d/*.conf 2>/dev/null"; then
    cr "echo '/usr/local/lib64' > /etc/ld.so.conf.d/usrlocal-lib64.conf && ldconfig"
  fi

  # 2.1 wayland-protocols
  ( cd "$SRC/wayland-src/wayland-protocols" && git checkout "$(latest_tag "$SRC/wayland-src/wayland-protocols")" 2>/dev/null
    cr "cd /opt/rk-src/wayland-src/wayland-protocols && rm -rf build && meson setup build --prefix=/usr/local -Dtests=false --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "wayland-protocols 编译失败"
  info "wayland-protocols=$(cr 'pkg-config --modversion wayland-protocols')"

  # 2.2 libxkbcommon（X11 + Wayland 都开：/usr/local/lib 优先级高于 /usr/lib64，
  #     本地库会覆盖系统库，故须同时支持 X11（UKUI 走 X11 需要 libxkbcommon-x11）与 Wayland（labwc））
  ( cd "$SRC/wayland-src/libxkbcommon" && git checkout "$(latest_tag "$SRC/wayland-src/libxkbcommon")" 2>/dev/null
    cr "cd /opt/rk-src/wayland-src/libxkbcommon && rm -rf build && meson setup build --prefix=/usr/local -Denable-x11=true -Denable-wayland=true -Denable-docs=false --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "libxkbcommon 编译失败"
  info "libxkbcommon=$(cr 'pkg-config --modversion xkbcommon')"

  # 2.3 libdisplay-info
  ( cd "$SRC/wayland-src/libdisplay-info" && git checkout "$(latest_tag "$SRC/wayland-src/libdisplay-info")" 2>/dev/null
    cr "cd /opt/rk-src/wayland-src/libdisplay-info && rm -rf build && meson setup build --prefix=/usr/local --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "libdisplay-info 编译失败"

  # 2.4 seatd (libseat)
  ( cd "$SRC/wayland-src/seatd" && git checkout "$(latest_tag "$SRC/wayland-src/seatd")" 2>/dev/null
    cr "cd /opt/rk-src/wayland-src/seatd && rm -rf build && meson setup build --prefix=/usr/local -Dman-pages=disabled -Dexamples=disabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "seatd 编译失败"

  # 2.5 wlroots（wrap 拉子项目；新版 GCC 对 etnaviv 的 -Werror=strict-aliasing 过敏 → 关 werror）
  WLR_TAG="$(tag_ge "$SRC/wayland-src/wlroots" '0.19*')"
  [ -z "$WLR_TAG" ] && WLR_TAG="$(tag_ge "$SRC/wayland-src/wlroots" '0.18*')"
  [ -z "$WLR_TAG" ] && WLR_TAG="$(latest_tag "$SRC/wayland-src/wlroots")"
  ( cd "$SRC/wayland-src/wlroots" && git checkout "$WLR_TAG" 2>/dev/null
    cr "cd /opt/rk-src/wayland-src/wlroots && rm -rf build && meson setup build --prefix=/usr/local --wrap-mode=default -Dlibdrm:werror=false -Dlibliftoff:werror=false -Dexamples=false -Dxwayland=enabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "wlroots 编译失败($WLR_TAG)"
  info "wlroots=$(cr 'pkg-config --modversion wlroots')"

  # 2.6 labwc（与 wlroots 大版本配对）
  case "$WLR_TAG" in
    0.19*) LAB_TAG="$(tag_ge "$SRC/wayland-src/labwc" '0.9*')" ;;
    0.18*) LAB_TAG="$(tag_ge "$SRC/wayland-src/labwc" '0.8*')" ;;
    *)     LAB_TAG="$(latest_tag "$SRC/wayland-src/labwc")" ;;
  esac
  [ -z "$LAB_TAG" ] && LAB_TAG="$(latest_tag "$SRC/wayland-src/labwc")"
  ( cd "$SRC/wayland-src/labwc" && git checkout "$LAB_TAG" 2>/dev/null
    cr "cd /opt/rk-src/wayland-src/labwc && rm -rf build && meson setup build --prefix=/usr/local --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) \
    || die "labwc 编译失败($LAB_TAG)"
  info "labwc=$(cr '/usr/local/bin/labwc --version 2>/dev/null | head -1')"

  # 2.7 foot 终端（尽力而为）
  if [ -d "$SRC/wayland-src/foot" ]; then
    ( cd "$SRC/wayland-src/tllist" && git checkout "$(latest_tag "$SRC/wayland-src/tllist")" 2>/dev/null
      cr "cd /opt/rk-src/wayland-src/tllist && rm -rf build && meson setup build --prefix=/usr/local --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) 2>/dev/null || warn "tllist 失败"
    ( cd "$SRC/wayland-src/fcft" && git checkout "$(latest_tag "$SRC/wayland-src/fcft")" 2>/dev/null
      cr "cd /opt/rk-src/wayland-src/fcft && rm -rf build && meson setup build --prefix=/usr/local -Ddocs=disabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) 2>/dev/null || warn "fcft 失败"
    ( cd "$SRC/wayland-src/foot" && git checkout "$(latest_tag "$SRC/wayland-src/foot")" 2>/dev/null
      cr "cd /opt/rk-src/wayland-src/foot && rm -rf build && meson setup build --prefix=/usr/local -Ddocs=disabled --buildtype=release -Doptimization=2 && ninja -C build install && ldconfig" ) 2>/dev/null && info "foot 已装" || warn "foot 未装成（非致命，xterm via Xwayland 兜底）"
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
log "== 编译 rkmpp 媒体栈（libplacebo/mpp/rga/ffmpeg-rockchip/mpv）=="
FFMPEG_LIBDIR=/usr/local/lib/ffmpeg-rkmpp

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

# 3.6 mpv 编译（x11 + drm + wayland 三后端全开；wayland 后端因 wayland-protocols>=1.34 自动开启）
WP_VER="$(cr 'pkg-config --modversion wayland-protocols 2>/dev/null')"
[ -z "$WP_VER" ] && WP_VER=0
WL_BUILD=enabled
if [ "$(printf '%s\n' 1.34 "$WP_VER" | sort -V | head -1)" != "1.34" ]; then
  WL_BUILD=disabled
  warn "wayland-protocols=$WP_VER < 1.34，mpv wayland 后端关闭（应已升级到 1.50，若到此告警请查编译）"
fi
_X11=""
[ "${MPV_X11:-1}" = "1" ] && _X11="-Dx11=enabled -Dgl-x11=enabled -Degl-x11=enabled"
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
# 5. 显示管理器：lightdm（统一，autologin 到 admin 用户）
# ---------------------------------------------------------------------------
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
# 7. mpv 运行时配置 + mpv-auto（修正版，三后端探测）
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
# 自动选择显示后端；传入的 mpv 参数原样透传，仍可手动 --gpu-context/--vo 覆盖
set -u
MPV="$(command -v mpv 2>/dev/null || echo /usr/local/bin/mpv)"
args=("$@")
for a in "${args[@]}"; do
  case "$a" in
    --vo=*|--gpu-context=*) exec "$MPV" "${args[@]}" ;;
  esac
done
# 1) Wayland 会话（套接字真实存在才认，防僵尸变量）
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    sock="${WAYLAND_DISPLAY#unix:}"
    [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$sock" ] || sock=""
    [ -n "$sock" ] && exec "$MPV" --gpu-context=wayland "${args[@]}"
fi
# 2) X11 会话且 EGL 可用（x11egl 走 GPU 渲染）—— 先探测再决定，避免误报错
if [ -n "${DISPLAY:-}" ] && ldconfig -p | grep -q 'libEGL\.so'; then
    if "$MPV" --gpu-context=help 2>/dev/null | grep -q x11egl; then
        exec "$MPV" --gpu-context=x11egl "${args[@]}"
    fi
fi
# 3) 无桌面/纯命令行/服务态：GPU 合成 + DRM 上下文（rkmpp 硬解直通，零拷贝）
exec "$MPV" --hwdec=rkmpp --vo=gpu --gpu-context=drm \
  --drm-connector=HDMI-A-1 --drm-mode=1 "${args[@]}"
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
# 8. 设为图形界面默认启动 + 启用 lightdm
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 9. 清理
# ---------------------------------------------------------------------------
log "清理 dnf 缓存"
cr "dnf clean all" >/dev/null 2>&1 || true
rm -rf "$R/var/cache/dnf"/* "$R/var/cache/yum"/* 2>/dev/null || true
rm -rf "$R/tmp"/* 2>/dev/null || true

info "桌面集成后 rootfs: $(du -sh "$R" | cut -f1)"
log "桌面集成安装完成"
_KIOSK_TAG=""
[ "$KIOSK" = "1" ] && _KIOSK_TAG=" / kiosk=开"
info "桌面组合: $FLAVOR / autologin: $ADMIN_USER / 会话: $DEF_SESSION$_KIOSK_TAG"
info "mpv 三后端: drm + x11egl + wayland（rkmpp 硬解）"
