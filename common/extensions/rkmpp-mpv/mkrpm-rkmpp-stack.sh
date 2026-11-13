#!/usr/bin/env bash
# =============================================================================
# mkrpm-rkmpp-stack.sh — 把「已安装」的 RKMPP+mpv 栈打包成当前发行版/架构的 RPM
# -----------------------------------------------------------------------------
# 对应 armbian 侧的 mkdeb-rkmpp-stack.sh（dpkg）。这里用 rpmbuild 产 RPM。
#
# 重要：RPM 与 deb 一样是**发行版 + 架构绑定**的：
#   * 二进制由当前系统的 glibc 链接，SONAME 由当前 openEuler 版本决定；
#   * 所以换发行版（openEuler 24.03 → 其它）、换架构（aarch64 → 其它）必须重编重打。
#   本脚本替代一次性手工打包，纳入版本控制，可复现。
#
# 前提：栈已在本机装好（/usr/local/bin/mpv 能跑、/etc/mpv/mpv.conf 在）。
#       通常流程：build-rkmpp-stack.sh build（BUILD_RPM=yes）自动调用本脚本。
#
# 用法：
#   sudo bash mkrpm-rkmpp-stack.sh [--outdir DIR] [--version VER]
#   OUTDIR=/root/rkmpp-rpms bash mkrpm-rkmpp-stack.sh
#
# 产物：$OUTDIR/rkmpp-stack-<ver>-1.<arch>.rpm，内置 build-info 守卫文件。
# =============================================================================
set -euo pipefail

PREFIX=/usr/local
OUTDIR="${OUTDIR:-/root/rkmpp-rpms}"
PKG=rkmpp-stack
VERSION_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --outdir)   OUTDIR="$2"; shift 2 ;;
    --version)  VERSION_OVERRIDE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

log() { echo "[mkrpm $(date +%H:%M:%S)] $*"; }
die() { echo "[mkrpm] 错误: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root（要读 /etc 并用 rpmbuild 打包系统路径）"
command -v rpmbuild >/dev/null || dnf install -y rpm-build || die "缺少 rpmbuild（rpm-build 包）"

ARCH="$(uname -m)"
[ -r /etc/os-release ] && . /etc/os-release
DISTRO_ID="${ID:-unknown}"
DISTRO_VER="${VERSION_ID:-unknown}"
GLIBC="$(ldd --version 2>/dev/null | sed -n 1p | awk '{print $NF}')"

# ---- 0. 前置检查 ----
[ -x "$PREFIX/bin/mpv" ]      || die "$PREFIX/bin/mpv 不存在，请先 build"
[ -x "$PREFIX/bin/ffmpeg" ]   || die "$PREFIX/bin/ffmpeg 不存在，请先 build"
[ -d "$PREFIX/lib/ffmpeg-rkmpp" ] || die "$PREFIX/lib/ffmpeg-rkmpp 不存在，请先 build"
[ -f /etc/mpv/mpv.conf ]      || die "/etc/mpv/mpv.conf 不存在，请先 build"

MPV_RAW="$("$PREFIX/bin/mpv" --version 2>/dev/null | sed -n 1p | awk '{print $2}')"
MPV_BASE="${MPV_RAW%%-*}"; MPV_BASE="${MPV_BASE#v}"
VERSION="${VERSION_OVERRIDE:-${MPV_BASE:-0.41.0}-1}"

pc_ver() {
  local name="$1" f
  local v; v="$(pkg-config --modversion "$name" 2>/dev/null)" && [ -n "$v" ] && { echo "$v"; return; }
  for f in "$PREFIX/lib/pkgconfig/$name.pc" "$PREFIX/lib/$ARCH-linux-gnu/pkgconfig/$name.pc"; do
    [ -f "$f" ] || continue
    sed -n 's/^[Vv]ersion:[[:space:]]*//p' "$f" | sed -n 1p && return
  done
  echo unknown
}
MPP_VER="$(pc_ver rockchip_mpp)"
RGA_VER="$(pc_ver librga)"
FFMPEG_VER="$("$PREFIX/bin/ffmpeg" -hide_banner -version 2>/dev/null | sed -n 1p | awk '{print $3}')"
MULTIARCH="$ARCH-linux-gnu"

log "目标: $PKG $VERSION  arch=$ARCH  distro=$DISTRO_ID $DISTRO_VER  glibc=$GLIBC"

# ---- 1. 收集文件到 staging（与已验证 deb 同构，目录用 arch 自适应）----
WORK="$(mktemp -d /tmp/rkmpp-rpm.XXXXXX)"
STAGE="$WORK/stage"
BUILDROOT="$WORK/rpmbuild"
mkdir -p "$STAGE" "$OUTDIR" "$BUILDROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
trap 'rm -rf "$WORK"' EXIT

shopt -s nullglob
SRC=()
add() { local p; for p in "$@"; do [ -e "$p" ] && SRC+=("$p"); done; }
add "$PREFIX/bin/mpv" "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe"
add "$PREFIX"/lib/ffmpeg-rkmpp/*
add "$PREFIX"/lib/librockchip_mpp.so* "$PREFIX"/lib/librockchip_vpu.so*
add "$PREFIX"/lib/librga.so* "$PREFIX"/lib/pkgconfig/*.pc
add /etc/mpv/mpv.conf /etc/udev/rules.d/99-mpp.rules /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
add /usr/share/applications/mpv.desktop /usr/share/icons/hicolor/scalable/apps/rkmpp-mpv.svg
add "$PREFIX/bin/mpv-desktop"

[ "${#SRC[@]}" -gt 0 ] || die "未收集到任何文件"
log "收集 ${#SRC[@]} 个路径，复制到 staging…"
( cd / && cp -a --parents "${SRC[@]}" "$STAGE" )

# ---- 2. build-info 守卫（供扩展做发行版/架构判断）----
mkdir -p "$STAGE/usr/local/share/rkmpp-stack"
cat > "$STAGE/usr/local/share/rkmpp-stack/build-info" <<EOF
PKG=$PKG
VERSION=$VERSION
ARCH=$ARCH
MULTIARCH=$MULTIARCH
DISTRO_ID=$DISTRO_ID
DISTRO_VER=$DISTRO_VER
GLIBC=$GLIBC
MPV=$MPV_RAW
MPP=$MPP_VER
RGA=$RGA_VER
FFMPEG=$FFMPEG_VER
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILT_ON=$(hostname 2>/dev/null || echo unknown)
EOF

# ---- 3. 把 staging 搬进 rpmbuild 的 %{buildroot} ----
# 用 rsync/cp 把 / 根下的文件映射到 $RPM_BUILD_ROOT 对应路径
mkdir -p "$BUILDROOT/BUILDROOT"
( cd "$STAGE" && find . -type f -o -type l | while read -r f; do
    f="${f#./}"
    mkdir -p "$BUILDROOT/BUILDROOT/$(dirname "$f")"
    cp -a "$STAGE/$f" "$BUILDROOT/BUILDROOT/$f"
  done )

# ---- 4. 生成 %files 清单（从 buildroot 实际内容反推，杜绝 unpackaged 报错）----
FILES_LIST="$WORK/files.list"
( cd "$BUILDROOT/BUILDROOT" && find . -type f -o -type l | sed 's|^\./|/|' | sort -u > "$FILES_LIST" )
[ -s "$FILES_LIST" ] || die "buildroot 中未找到任何文件"
# 转成 %files 段落（目录用 %dir 省略，仅列文件；RPM 会自动建父目录）
FILES_SECTION="$(sed 's|^|%config(noreplace) |' "$FILES_LIST" | sed 's|%config(noreplace) /etc/mpv/mpv.conf|/etc/mpv/mpv.conf|')"

# ---- 5. 写 spec ----
SPEC="$BUILDROOT/SPECS/$PKG.spec"
cat > "$SPEC" <<EOF
Name:           $PKG
Version:        $VERSION
Release:        1
Summary:        RK35xx RKMPP hardware decoding stack (mpp + rkrga + ffmpeg-rockchip + mpv rkmpp)
License:        GPLv2+
URL:            https://github.com/xiaobao1980/openeuler-rockchip-builds
BuildArch:      $ARCH

%description
Prebuilt RKMPP hardware decoding stack for Rockchip RK3566/3568/3576/3588 on
openEuler $DISTRO_VER ($ARCH). mpp $MPP_VER, rkrga $RGA_VER, ffmpeg-rockchip
isolated in $PREFIX/lib/ffmpeg-rkmpp, mpv $MPV_RAW + rkmpp backend patch.
Ships /etc/mpv/mpv.conf (hwdec=rkmpp, vo=gpu auto-select X11/Wayland/DRM),
udev rule 99-mpp.rules (mpp_service/rga 0666) and ld.so.conf.d entry.
This RPM is bound to openEuler $DISTRO_VER / $ARCH (glibc $GLIBC); rebuild on other releases.

%prep
# 预编译好的栈，无需解压源码

%build
# 预编译好的栈，无编译步骤

%install
# 文件已在 %{buildroot} 预置（脚本在 build 阶段搬入），此处无需动作
true

%post
ldconfig
mkdir -p /usr/local/etc/mpv
[ -e /usr/local/etc/mpv/mpv.conf ] || ln -sf /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf
if [ -d /run/udev ] || [ -d /dev/.udev ]; then
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
fi
command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications 2>/dev/null || true

%files
$FILES_SECTION

%changelog
* $(date +'%a %b %d %Y') xiaobao <xiaobao@local> - $VERSION-1
- Prebuilt RKMPP stack for openEuler $DISTRO_VER/$ARCH.
EOF

# ---- 6. 打包 ----
export HOME="$WORK"
mkdir -p "$HOME"
cat > "$HOME/.rpmmacros" <<EOF
%_topdir $BUILDROOT
%_buildrootdir $BUILDROOT/BUILDROOT
EOF
log "rpmbuild -bb $SPEC"
rpmbuild -bb --buildroot "$BUILDROOT/BUILDROOT" "$SPEC" 2>&1 | tail -20
RPM="$(find "$BUILDROOT/RPMS" -name "${PKG}-${VERSION}-1.${ARCH}.rpm" | head -1)"
[ -n "$RPM" ] || die "RPM 未生成"
cp "$RPM" "$OUTDIR/"
log "产物: $OUTDIR/$(basename "$RPM")"
[ -x "$(command -v sha256sum)" ] && sha256sum "$OUTDIR/$(basename "$RPM")" | sed 's/^/    /'
log "部署（其它板卡）: dnf install -y $OUTDIR/$(basename "$RPM")   或   rpm -ivh $OUTDIR/$(basename "$RPM")"
