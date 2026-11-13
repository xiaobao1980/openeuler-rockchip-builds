#!/usr/bin/env bash
# =============================================================================
# build-rkmpp-stack.sh — 在 aarch64 openEuler 上编译 RK35xx RKMPP + mpv 硬解栈
# -----------------------------------------------------------------------------
# 目标：产出一套可复用的 RKMPP 硬解栈，供其它 RK35xx 板卡通过 RPM 直接安装，
#       免去每块板重复编译。与 armbian-custom-builds 的 rk35xx-rkmpp-mpv-build.sh
#       同源，但适配 openEuler（dnf / -devel 包名 / RPM 打包）。
#
# 路线（与板端已验证栈一致）：
#   mpp        (nyanmisaka/mpp, branch jellyfin-mpp)
#   rkrga      (nyanmisaka/rk-mirrors, branch jellyfin-rga)
#   ffmpeg-rockchip (nyanmisaka/ffmpeg-rockchip，隔离装到 /usr/local/lib/ffmpeg-rkmpp)
#   mpv        (官方 v0.41.0 + mpp.patch rkmpp 后端补丁 + vd_lavc-rkmpp-drm.patch)
#
# 后端：mpv 同时编 x11 / wayland / drm 三后端（-Ddrm/x11/wayland=enabled）。
#       vo=gpu 按会话自动选上下文：有 DISPLAY→X11，有 WAYLAND_DISPLAY→Wayland，
#       都没有→DRM/KMS（headless）。hwdec=rkmpp 与显示后端解耦，三后端均生效。
#
# 用法：
#   sudo bash build-rkmpp-stack.sh [build|uninstall]
#   MPV_TAG=v0.41.0 BUILD_RPM=yes bash build-rkmpp-stack.sh build
#
# 前置：必须在 aarch64 openEuler（24.03-LTS-SP4 验证）上运行；需要网络拉源码。
#       本脚本只编译，不替你打 RPM——设 BUILD_RPM=yes 会在末尾调用 mkrpm-rkmpp-stack.sh。
# =============================================================================
set -euo pipefail

BUILD_BASE="${BUILD_BASE:-/root/rkmpp-build}"
SRC_DIR="$BUILD_BASE/src"
MPV_TAG="${MPV_TAG:-v0.41.0}"
FFMPEG_LIBDIR=/usr/local/lib/ffmpeg-rkmpp
LOG="$BUILD_BASE/build.log"
JOBS="${JOBS:-$(nproc)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$BUILD_BASE" "$SRC_DIR"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "[build] 错误: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 发行版守卫：仅支持 openEuler aarch64（RPM 是发行版+架构绑定的）
# -----------------------------------------------------------------------------
guard_distro() {
  if [ "$(uname -m)" != "aarch64" ]; then
    die "仅支持 aarch64（当前 $(uname -m)）。RKMPP 栈需在 ARM64 上编译。"
  fi
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "openEuler" ]; then
      log "警告: 当前发行版为 ${PRETTY_NAME:-$ID}，未验证。RPM 含 openEuler 的 glibc/SONAME，" \
          "装在其它发行版可能缺库。建议仅在 openEuler 上构建与部署。"
    else
      log "检测到 openEuler ${VERSION_ID:-}（${PRETTY_NAME:-}）"
    fi
  fi
}

# -----------------------------------------------------------------------------
# git clone 多源兜底 + 重试（CI 弱网下 gitee 大仓库偶发 early EOF）
# -----------------------------------------------------------------------------
git_clone_retry() {
  local branch="${1:-}"; local dest="$2"; shift 2
  local bflag=""; [ -n "$branch" ] && bflag="-b $branch"
  for url in "$@"; do
    for attempt in 1 2 3 4 5; do
      log "[clone] 尝试 $attempt/5: $url"
      rm -rf "$dest"
      if git clone --depth=1 $bflag "$url" "$dest" >"/tmp/clone-$$.log" 2>&1 && [ -d "$dest" ]; then
        log "[clone] 成功: $url"; return 0
      fi
      log "[clone] 失败 ($(tail -n1 /tmp/clone-$$.log 2>/dev/null)); 清理重试"
      rm -rf "$dest"; sleep 8
    done
  done
  die "所有源/重试均失败: $*"
}

# -----------------------------------------------------------------------------
# 构建依赖（openEuler 包名；缺失的几个在此一并补齐）
# -----------------------------------------------------------------------------
install_deps() {
  log "== 安装构建依赖（dnf）=="
  dnf install -y --setopt=install_weak_deps=False \
    git cmake meson ninja-build pkg-config gcc gcc-c++ make nasm yasm \
    libdrm-devel libdisplayinfo-devel libplacebo-devel \
    libX11-devel libXext-devel libXrandr-devel libXv-devel libxcb-devel \
    libwayland-devel wayland-protocols-devel libxkbcommon-devel \
    mesa-libGL-devel mesa-libEGL-devel \
    libass-devel uchardet-devel lua-devel \
    x264-devel x265-devel libdav1d-devel gnutls-devel \
    rpm-build
  # libplacebo 版本体检（mpv 0.40+ 硬依赖 >= 6.338.2）
  if pkg-config --exists libplacebo; then
    local _plv; _plv="$(pkg-config --modversion libplacebo)"
    log "libplacebo: $_plv"
    local _maj _min
    _maj="$(echo "$_plv" | cut -d. -f1)"; _min="$(echo "$_plv" | cut -d. -f2)"
    if [ "${_maj:-0}" -lt 6 ] || { [ "${_maj:-0}" -eq 6 ] && [ "${_min:-0}" -lt 338 ]; }; then
      die "libplacebo $_plv < 6.338.2，mpv ${MPV_TAG#v} 硬依赖不满足；请升级 libplacebo-devel 后重试"
    fi
  else
    die "libplacebo-devel 安装后 pkg-config 仍不可见，中止"
  fi
  if [ "$(meson --version 2>/dev/null || echo 0)" \< "1.1" ]; then
    pip3 install -U meson ninja 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# 卸载旧栈（干净重建）
# -----------------------------------------------------------------------------
do_uninstall() {
  log "== 卸载旧 rkmpp + mpv 栈 =="
  rm -f /usr/local/bin/mpv /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffplay
  rm -f /usr/local/lib/libav*.so* /usr/local/lib/libpostproc*.so* /usr/local/lib/libsw*.so*
  rm -f /usr/local/lib/pkgconfig/libav*.pc /usr/local/lib/pkgconfig/libpostproc*.pc /usr/local/lib/pkgconfig/libsw*.pc
  rm -f /usr/local/lib/librockchip_mpp.so* /usr/local/lib/librga.so*
  rm -rf /usr/local/lib/ffmpeg-rkmpp
  rm -f /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
  rm -f /etc/udev/rules.d/99-mpp.rules
  rm -f /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf
  rm -f /usr/share/applications/mpv.desktop /usr/share/icons/hicolor/scalable/apps/rkmpp-mpv.svg /usr/local/bin/mpv-desktop
  rm -rf /usr/local/share/rkmpp-stack
  ldconfig
  log "== 卸载完成 =="
}

# -----------------------------------------------------------------------------
# mpp
# -----------------------------------------------------------------------------
build_mpp() {
  log "== 编译 mpp (jellyfin-mpp) =="
  cd "$SRC_DIR"
  git_clone_retry jellyfin-mpp mpp \
    https://github.com/nyanmisaka/mpp.git \
    https://gitee.com/nyanmisaka/mpp.git
  cd mpp && mkdir -p build && cd build
  cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF ..
  make -j"${JOBS}" && make install && ldconfig
  pkg-config --exists rockchip_mpp || die "MPP pkg-config 缺失"
  log "MPP OK: $(pkg-config --modversion rockchip_mpp)"
}

# -----------------------------------------------------------------------------
# rkrga
# -----------------------------------------------------------------------------
build_rga() {
  log "== 编译 rkrga (jellyfin-rga) =="
  cd "$SRC_DIR"
  git_clone_retry jellyfin-rga rkrga \
    https://github.com/nyanmisaka/rk-mirrors.git \
    https://gitee.com/nyanmisaka/rga.git
  cd rkrga
  meson setup build --prefix=/usr/local --buildtype=release \
    --default-library=shared -Dlibdrm=false -Dlibrga_demo=false
  ninja -C build && ninja -C build install && ldconfig
  pkg-config --exists librga || die "RGA pkg-config 缺失"
  log "RGA OK: $(pkg-config --modversion librga)"
}

# -----------------------------------------------------------------------------
# ffmpeg-rockchip（隔离安装，避免污染系统 ffmpeg）
# -----------------------------------------------------------------------------
build_ffmpeg() {
  log "== 编译 ffmpeg-rockchip（隔离到 $FFMPEG_LIBDIR）=="
  cd "$SRC_DIR"
  if [ -f ffmpeg-rockchip/libavcodec/rkmppdec.o ]; then
    log "ffmpeg-rockchip 已编译，跳过 clone/configure/make"
    cd ffmpeg-rockchip
  else
    git_clone_retry "" ffmpeg-rockchip \
      https://github.com/nyanmisaka/ffmpeg-rockchip.git \
      https://gitee.com/nyanmisaka/ffmpeg-rockchip.git
    cd ffmpeg-rockchip
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
    ./configure --prefix=/usr/local \
      --libdir="$FFMPEG_LIBDIR" \
      --enable-gpl --enable-version3 --enable-nonfree \
      --enable-shared --disable-static \
      --enable-libdrm --enable-rkmpp --enable-rkrga \
      --enable-libx264 --enable-libx265 --enable-libdav1d --enable-gnutls \
      --extra-cflags="-I/usr/local/include" \
      --extra-ldflags="-L/usr/local/lib -Wl,-rpath,$FFMPEG_LIBDIR" \
      --disable-doc --disable-debug --disable-ffplay || \
      ./configure --prefix=/usr/local \
      --libdir="$FFMPEG_LIBDIR" \
      --enable-gpl --enable-version3 --enable-nonfree \
      --enable-shared --disable-static \
      --enable-libdrm --enable-rkmpp --enable-rkrga \
      --extra-cflags="-I/usr/local/include" \
      --extra-ldflags="-L/usr/local/lib -Wl,-rpath,$FFMPEG_LIBDIR" \
      --disable-doc --disable-debug --disable-ffplay
    make -j"${JOBS}"
  fi
  make install
  echo "$FFMPEG_LIBDIR" > /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
  ldconfig
  export LD_LIBRARY_PATH="$FFMPEG_LIBDIR:${LD_LIBRARY_PATH:-}"
  /usr/local/bin/ffmpeg -hide_banner -decoders 2>/dev/null > /tmp/ffmpeg-decoders.txt || true
  grep -qE 'h264_rkmpp|hevc_rkmpp|vp9_rkmpp|av1_rkmpp' /tmp/ffmpeg-decoders.txt \
    || die "rkmpp 解码器缺失（--enable-rkmpp 未生效）"
  log "rkmpp 解码器校验通过: $(grep -cE '_rkmpp' /tmp/ffmpeg-decoders.txt) 个"
}

# -----------------------------------------------------------------------------
# mpv 源码 + 补丁
# -----------------------------------------------------------------------------
prepare_mpv() {
  log "== 准备 mpv 源码 ($MPV_TAG) + 应用 rkmpp 后端补丁 + vd_lavc 修复 =="
  cd "$SRC_DIR"
  if [ -d mpv/.git ]; then
    log "复用已存在的 mpv 源码"
  else
    git_clone_retry "$MPV_TAG" mpv https://github.com/mpv-player/mpv.git
  fi
  cd mpv
  git checkout "$MPV_TAG" 2>/dev/null || true
  # 1) rkmpp 后端补丁（官方主线不含该后端）
  if grep -q "ra_hwdec_drmprime_rkmpp" video/decode/hwdec/hwdec_drmprime.c 2>/dev/null; then
    log "rkmpp 后端补丁已存在，跳过"
  else
    log "应用 rkmpp 后端补丁: $HERE/mpp.patch"
    git apply "$HERE/mpp.patch" 2>/tmp/mpv-patch.err \
      || patch -p1 < "$HERE/mpp.patch" \
      || die "mpp.patch 应用失败: $(head -5 /tmp/mpv-patch.err)"
  fi
  # 2) 我们独有的 vd_lavc RKMPP/DRM 设备类型修复（零拷贝走 --gpu-context=drm 必需）
  if grep -q "av_hwdevice_ctx_create(&own, hwdec->lavc_device" video/decode/vd_lavc.c 2>/dev/null; then
    log "vd_lavc 修复已存在，跳过"
  else
    log "应用 vd_lavc-rkmpp-drm.patch: $HERE/vd_lavc-rkmpp-drm.patch"
    git apply "$HERE/vd_lavc-rkmpp-drm.patch" 2>/tmp/vd-patch.err \
      || patch -p1 < "$HERE/vd_lavc-rkmpp-drm.patch" \
      || die "vd_lavc-rkmpp-drm.patch 应用失败: $(head -5 /tmp/vd-patch.err)"
  fi
}

# -----------------------------------------------------------------------------
# mpv 编译（x11 + wayland + drm 三后端全开）
# -----------------------------------------------------------------------------
build_mpv() {
  log "== 编译 mpv ($MPV_TAG + rkmpp 补丁) =="
  cd "$SRC_DIR/mpv"
  export PKG_CONFIG_PATH=$FFMPEG_LIBDIR/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
  rm -rf build
  meson setup build --prefix=/usr/local --buildtype=release \
    -Dx11=enabled -Dgl-x11=enabled -Degl-x11=enabled \
    -Ddrm=enabled -Dwayland=enabled -Degl-wayland=enabled \
    -Dlibmpv=true -Dlua=disabled
  ninja -C build -j"${JOBS}"
  if ! grep -rqs "ra_hwdec_drmprime_rkmpp" build/ 2>/dev/null; then
    die "编译产物中未找到 rkmpp 驱动符号，补丁或 ffmpeg-rockchip 头文件可能未生效"
  fi
  ninja -C build install
  ldconfig
  mpv --hwdec=help 2>/dev/null > /tmp/mpv-hwdec.txt || true
  [ "$(grep -c rkmpp /tmp/mpv-hwdec.txt)" -ge 1 ] \
    || die "rkmpp hwdec 未出现（补丁未生效或 ffmpeg-rockchip 头文件未找到）"
  log "rkmpp hwdec 项数: $(grep -c rkmpp /tmp/mpv-hwdec.txt)"
}

# -----------------------------------------------------------------------------
# 运行时配置：mpv.conf / udev / 桌面入口
# -----------------------------------------------------------------------------
configure_runtime() {
  log "== 配置 mpv.conf / udev / 桌面入口 =="
  mkdir -p /etc/mpv /usr/local/etc/mpv /usr/share/applications \
           /usr/share/icons/hicolor/scalable/apps
  # mpv.conf：vo=gpu 不写死 gpu-context，按会话自动选 X11/Wayland/DRM。
  # 10-bit（NV15）内容必须 force_yuv=8bit 降位（否则 Mesa/上游不支持 nv15 纹理导入→黑屏）。
  cat > /etc/mpv/mpv.conf <<'EOF'
# RK35xx RKMPP 硬件加速配置（X11 / Wayland / DRM headless 通用）
# vo=gpu 自动选上下文：DISPLAY→X11，WAYLAND_DISPLAY→Wayland，都没有→DRM/KMS
hwdec=rkmpp
hwdec-codecs=all
vo=gpu
profile=fast
cache=yes
cache-secs=60
demuxer-max-bytes=50M
sub-font-size=35
# 10-bit(NV15) 内容必须降位为 NV12，否则黑屏；8-bit 内容此滤镜近乎零成本
vf=lavfi=[scale_rkrga=force_yuv=8bit]
EOF
  ln -sfn /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf
  cat > /etc/udev/rules.d/99-mpp.rules <<'EOF'
KERNEL=="mpp_service", MODE="0666"
KERNEL=="rga", MODE="0666"
EOF
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
  echo 1000 > /proc/mpp_service/load_interval 2>/dev/null || true
  # 桌面菜单入口（无参开 idle 窗口；带参正常播放）
  cat > /usr/local/bin/mpv-desktop <<'EOF'
#!/bin/sh
if [ "$#" -eq 0 ]; then
  exec /usr/local/bin/mpv --player-operation-mode=pseudo-gui --no-fullscreen --force-window=yes
fi
exec /usr/local/bin/mpv -- "$@"
EOF
  chmod 0755 /usr/local/bin/mpv-desktop
  cat > /usr/share/applications/mpv.desktop <<'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=mpv
Name[zh_CN]=mpv 播放器
GenericName=Media Player
Comment=RKMPP hardware-accelerated video player
Comment[zh_CN]=RKMPP 硬件加速视频播放器（RK35xx）
Exec=/usr/local/bin/mpv-desktop %U
TryExec=/usr/local/bin/mpv
Icon=rkmpp-mpv
Terminal=false
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/webm;video/quicktime;video/x-msvideo;video/mp2t;audio/mpeg;audio/flac;
EOF
  chmod 644 /usr/share/applications/mpv.desktop
  cat > /usr/share/icons/hicolor/scalable/apps/rkmpp-mpv.svg <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#9c27b0"/><stop offset="1" stop-color="#5e1273"/>
  </linearGradient></defs>
  <rect x="4" y="4" width="120" height="120" rx="26" fill="url(#g)"/>
  <path d="M52 38 L52 90 L94 64 Z" fill="#ffffff"/>
</svg>
EOF
  chmod 644 /usr/share/icons/hicolor/scalable/apps/rkmpp-mpv.svg
}

# -----------------------------------------------------------------------------
do_build() {
  log "######## RK35xx RKMPP+mpv 编译开始（openEuler aarch64）########"
  guard_distro
  do_uninstall
  install_deps
  build_mpp
  build_rga
  build_ffmpeg
  prepare_mpv
  build_mpv
  configure_runtime
  log "######## 编译完成。如需打包 RPM：BUILD_RPM=yes 重跑，或手动 bash $HERE/mkrpm-rkmpp-stack.sh ########"
  if [ "${BUILD_RPM:-no}" = "yes" ]; then
    bash "$HERE/mkrpm-rkmpp-stack.sh"
  fi
}

case "${1:-build}" in
  uninstall) do_uninstall ;;
  build|"") do_build ;;
  *) echo "用法: $0 [build|uninstall]"; exit 1 ;;
esac
