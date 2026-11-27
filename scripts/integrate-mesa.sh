#!/usr/bin/env bash
# ============================================================================
# 集成安装：Mesa(panfrost) 用户态 GPU 驱动 + GBM/EGL 后端烘焙进「离线 rootfs」
#
# 背景（2026-11-17 板端 .102 实测）：
#   - 内核层 OK：vendor 内核自带 panfrost.ko（CONFIG_DRM_PANFROST=m），已自动加载，
#     renderD130 即 Mali-G52 渲染节点 —— 问题从来不在内核。
#   - 用户态缺口：openEuler 24.03 SP4 仓库的 mesa 24.0.3-6 **编译时未启用 panfrost**，
#     mesa-dri-drivers 里只有 swrast/kms_swrast，全盘找不到 panfrost_dri.so
#     → mpv --vo=gpu 初始化 GPU 上下文失败，桌面 GL 只能软渲染。
#   - 正解（真机已验证：GL_RENDERER='Mali-G52 r1 (Panfrost)'，4K60 稳定）：
#     自编 Mesa 24.0.3（panfrost gallium，llvm=disabled），装 /usr/local，
#     靠 LIBGL_DRIVERS_PATH 让系统 libGL/libEGL/libgbm 加载 panfrost_dri.so。
#
# 与 integrate-iot.sh / integrate-desktop.sh 同接口：
#   sudo bash integrate-mesa.sh <rootfs目录>
#   由 build-image.sh 在 chroot 已挂载的前提下调用（INTEGRATE=mesa）；
#   本脚本自身再做幂等挂载 + resolv 修复，独立跑也行。
#
# 前置：openEuler aarch64 rootfs、arm runner（chroot 原生编译）、root、网络。
#
# 产物：
#   /usr/local/lib64/dri/panfrost_dri.so   GPU 硬件 GL（Mali-G52 MC3 / Bifrost）
#   /usr/local/lib64/dri/swrast_dri.so     软渲染兜底（softpipe，无 llvm 依赖）
#   /usr/local/lib64/libGL|libEGL|libgbm|libgallium ...
#   /etc/environment + /etc/profile.d/mesa-panfrost.sh   预置 LIBGL_DRIVERS_PATH
#   /etc/ld.so.conf.d/000-mesa-local.conf                /usr/local 运行库入链接搜索路径
# ============================================================================
set -euo pipefail

R="${1:?用法: $0 <rootfs目录>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESA_TAG="mesa-24.0.3"
SRC="$R/opt/rk-src"
mkdir -p "$SRC"

log()  { printf '\n\033[1;35m[MESA] %s\033[0m\n' "$*"; }
info() { printf '      %s\n' "$*"; }
warn() { printf '\033[1;33m[MESA-WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[MESA-ERR] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "需要 root（要 chroot + mount）"
[ -d "$R/etc" ] || die "$R 不像 rootfs"
[ "$(uname -m)" = aarch64 ] || die "必须 aarch64（chroot 原生编译），当前 $(uname -m)"
grep -qs '^ID="*openEuler' "$R/etc/os-release" || die "$R/etc/os-release 不是 openEuler"

# ---------------------------------------------------------------------------
# chroot 挂载 + resolv 修复（幂等，与 integrate-desktop.sh 同款）
# ---------------------------------------------------------------------------
mountpoint -q "$R/proc" || { mount -t proc proc "$R/proc"; }
mountpoint -q "$R/sys"  || { mount -t sysfs sys "$R/sys"; }
mkdir -p "$R/dev" "$R/dev/pts" "$R/run"
mountpoint -q "$R/dev"     || { mount --bind /dev "$R/dev"; }
mountpoint -q "$R/dev/pts" || { mount --bind /dev/pts "$R/dev/pts"; }

SAVED_RESOLV=""
if [ -e "$R/etc/resolv.conf" ] && [ ! -L "$R/etc/resolv.conf" ]; then
  SAVED_RESOLV="$R/etc/resolv.conf.mesabak"
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

# chroot 内执行命令（与 integrate-desktop.sh 同款：PKG_CONFIG_PATH 覆盖 /usr/local 三处）
cr() {
  chroot "$R" /usr/bin/env -i \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig" \
    HOME=/root LANG=C.UTF-8 \
    bash -c "$*"
}

# 逐个安装，容忍单包缺失（教训：个别坏包名会让整笔 dnf 事务全部回滚）
dnf_install_loose() {
  local p
  for p in "$@"; do
    if cr "dnf -y --setopt=install_weak_deps=False --setopt=timeout=30 --setopt=retries=2 install $p" \
        >"/tmp/dnf-mesa-$p.log" 2>&1; then
      log "dnf ok: $p"
    else
      warn "dnf 未安装(若非必需可忽略): $p"
    fi
  done
}

log "目标系统: $(grep -E '^(PRETTY_NAME)=' "$R/etc/os-release" | cut -d= -f2- | tr -d '"')"
log "Mesa 版本: $MESA_TAG（gallium=panfrost,swrast；llvm=disabled）"

# ---------------------------------------------------------------------------
# 0. dnf 源修复（必须先于任何 dnf install）
#    2026-11-27 CI 第三次网络故障：repomd checksum 不匹配，4 个 calculated
#    sha512 全相同（缓存中毒 + 多镜像校验）。--retry 无效，必须清缓存 + 固定单源。
# ---------------------------------------------------------------------------
# shellcheck source=lib-dnf-repair.sh
. "$HERE/lib-dnf-repair.sh"
dnf_repair_sources || die "dnf 源修复失败，构建依赖必然装不上，提前中止"

# ---------------------------------------------------------------------------
# 1. 构建依赖（工具链必须齐，缺一项直接死，别拖到 meson 才爆）
# ---------------------------------------------------------------------------
log "安装构建依赖（dnf）"
cr "dnf -y --setopt=install_weak_deps=False --setopt=timeout=30 --setopt=retries=2 install \
  meson ninja-build gcc gcc-c++ make bison flex pkgconf-pkg-config \
  python3 python3-mako" >/tmp/mesa-dnf-tools.log 2>&1 \
  || { tail -30 /tmp/mesa-dnf-tools.log >&2; die "Mesa 构建工具链安装失败（meson/ninja/python3-mako 缺失）"; }

# 开发库：逐个装、容忍缺失。llvm 故意不装（panfrost/swrast(softpipe) 都不需要）。
dnf_install_loose \
  expat-devel zlib-devel libdrm-devel \
  wayland-devel wayland-protocols-devel \
  libX11-devel libxcb-devel libXext-devel libXfixes-devel \
  libXrandr-devel libXxf86vm-devel libxshmfence-devel

_LDRM=$(cr 'pkg-config --modversion libdrm' 2>/dev/null | tail -1 || echo '?')
info "libdrm(系统): $_LDRM（Mesa 24.0.3 需 >=2.4.119；不足时 meson 会给出明确报错）"
# X11 头是 glx=dri + platforms=x11 的硬依赖，缺失时 meson 报得含糊，这里提前拦下
cr 'pkg-config --exists x11 && pkg-config --exists xcb && pkg-config --exists xcb-dri3 && pkg-config --exists xrandr' \
  || die "X11/XCB 开发头缺失（libX11-devel/libxcb-devel/libXrandr-devel 未装上），meson 无法配置 glx=dri"

# ---------------------------------------------------------------------------
# 2. 源码（宿主机 clone，网络稳；-b 直接落地钉死标签，杜绝误编 master）
# ---------------------------------------------------------------------------
git_clone_retry() {
  local branch="${1:-}"; local dest="$2"; shift 2
  local bflag=""; [ -n "$branch" ] && bflag="-b $branch"
  for url in "$@"; do
    for attempt in 1 2 3 4 5; do
      log "[clone] 尝试 $attempt/5: $url"
      rm -rf "$dest"
      if git clone --depth=1 $bflag "$url" "$dest" >"/tmp/clone-mesa-$$.log" 2>&1 && [ -d "$dest" ]; then
        log "[clone] 成功: $url"; return 0
      fi
      sleep 8
    done
  done
  die "所有源/重试均失败: $*"
}
assert_src_tag() {
  local d="$1" want="$2" got
  got="$(git -C "$d" describe --tags --exact-match 2>/dev/null || true)"
  [ "$got" = "$want" ] || die "源码版本校验失败：$d 期望 $want，实际 ${got:-无标签/HEAD}（浅克隆未落在标签会误编 master，铁律）"
}

git_clone_retry "$MESA_TAG" "$SRC/mesa-src" \
  https://gitlab.freedesktop.org/mesa/mesa.git \
  https://github.com/Mesa3D/mesa.git
assert_src_tag "$SRC/mesa-src" "$MESA_TAG"

# ---------------------------------------------------------------------------
# 3. 编译安装（chroot 内，prefix=/usr/local）
#    gallium 只选 panfrost + swrast（softpipe 兜底），llvm 关闭 —— 两者都不需要 llvm；
#    EGL/GBM 全开，glx=dri（UKUI/Xwayland 需要），平台 x11+wayland。
# ---------------------------------------------------------------------------
log "== 编译 Mesa（panfrost 用户态 + GBM/EGL 后端）=="
( cr "cd /opt/rk-src/mesa-src && rm -rf build && meson setup build --prefix=/usr/local \
    -Dgallium-drivers=panfrost,swrast \
    -Dvulkan-drivers= -Dllvm=disabled \
    -Dglx=dri -Dplatforms=x11,wayland \
    -Degl=enabled -Dgbm=enabled \
    -Dopengl=true -Dgles1=disabled -Dgles2=enabled \
    -Dglvnd=false \
    -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled \
    --buildtype=release -Doptimization=2 \
    && ninja -C build install && ldconfig" ) \
  || die "Mesa 编译失败（查上方 meson 输出：常见为 libdrm 版本不足或缺 X11 开发头）"

# ---------------------------------------------------------------------------
# 4. 产物断言（编译"成功"但驱动没出来 = 白干，当场拦下）
# ---------------------------------------------------------------------------
[ -f "$R/usr/local/lib64/dri/panfrost_dri.so" ] || die "panfrost_dri.so 未产出（meson 配置未生效？）"
[ -f "$R/usr/local/lib64/dri/swrast_dri.so" ]   || die "swrast_dri.so 未产出（软渲染兜底缺失）"
info "panfrost_dri.so: $(du -h "$R/usr/local/lib64/dri/panfrost_dri.so" | cut -f1)"
info "swrast_dri.so : $(du -h "$R/usr/local/lib64/dri/swrast_dri.so" | cut -f1)"

# ---------------------------------------------------------------------------
# 5. 运行环境预置
#    5a. /usr/local 运行库入 ld 搜索路径（000- 前缀确保排在发行版条目之前）
#    5b. LIBGL_DRIVERS_PATH 三处预置：
#        /etc/environment      —— PAM 登录会话（SSH / lightdm 均经 pam_env 读入）
#        /etc/profile.d/*.sh   —— 交互式登录 shell
#        有了这两处，mpv / labwc / UKUI / Xwayland 无需手工 export 即可加载 panfrost
# ---------------------------------------------------------------------------
mkdir -p "$R/etc/ld.so.conf.d"
cat > "$R/etc/ld.so.conf.d/000-mesa-local.conf" <<'EOF'
# 自编 Mesa(panfrost) 运行库（integrate-mesa.sh 烘焙）；DRI 驱动搜索走 LIBGL_DRIVERS_PATH
/usr/local/lib64
/usr/local/lib
EOF
chroot "$R" ldconfig
info "ld.so.conf.d/000-mesa-local.conf 已写入并 ldconfig"

grep -qs 'LIBGL_DRIVERS_PATH=' "$R/etc/environment" || \
  printf '\n# Mesa panfrost：让 libGL/libEGL/libgbm 找到 /usr/local/lib64/dri 下的 panfrost_dri.so\nLIBGL_DRIVERS_PATH=/usr/local/lib64/dri:/usr/lib64/dri\n' >> "$R/etc/environment"
[ -f "$R/etc/environment" ] && info "/etc/environment 已含 LIBGL_DRIVERS_PATH"

cat > "$R/etc/profile.d/mesa-panfrost.sh" <<'EOF'
# Mesa panfrost 用户态驱动搜索路径（构建期烘焙，见 scripts/integrate-mesa.sh）
export LIBGL_DRIVERS_PATH=/usr/local/lib64/dri:/usr/lib64/dri
EOF
chmod 644 "$R/etc/profile.d/mesa-panfrost.sh"
info "/etc/profile.d/mesa-panfrost.sh 已写入"

log "完成：Mesa $MESA_TAG（panfrost + GBM/EGL）已烘焙进 $R"
