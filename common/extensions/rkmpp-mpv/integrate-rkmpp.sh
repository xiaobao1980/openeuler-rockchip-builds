#!/usr/bin/env bash
# =============================================================================
# integrate-rkmpp.sh — 把 RKMPP+mpv 硬解栈烘焙进「离线的目标 rootfs」
# -----------------------------------------------------------------------------
# 与 scripts/integrate-iot.sh 同范式：操作离线的目标 rootfs（chroot），dnf/rpm 装包，
# 不依赖目标板已启动。供 build-image.sh / build-openeuler-iot.yml 在拼装镜像时调用。
#
# 两种模式：
#   1) 传 --rpm=<预编译的 rkmpp-stack-*.rpm>  → 直接装包（推荐，最快，免去板上编译）
#   2) 不传 --rpm                              → 在 rootfs 内联网编译+安装（慢，兜底）
#
# 用法：
#   sudo ./integrate-rkmpp.sh <rootfs目录> [--rpm=/path/rkmpp-stack.rpm] [--build]
#
# 注意：rootfs 必须已经是 openEuler aarch64（glibc/SONAME 匹配）。
# =============================================================================
set -euo pipefail

R="${1:?用法: $0 <rootfs目录> [--rpm=...] [--build]}"
shift || true
RPM=""
BUILD=no
while [ $# -gt 0 ]; do
  case "$1" in
    --rpm=*)  RPM="${1#*=}" ;;
    --build)  BUILD=yes ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

[ -d "$R" ] || { echo "rootfs 不存在: $R"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[integrate-rkmpp] $*"; }

# 必须离线 rootfs 里有 rpm 数据库（openEuler rootfs 自带 /var/lib/rpm）
[ -d "$R/var/lib/rpm" ] || { echo "$R 不是 openEuler rootfs（缺 /var/lib/rpm）"; exit 1; }

if [ -n "$RPM" ]; then
  [ -f "$RPM" ] || { echo "RPM 不存在: $RPM"; exit 1; }
  log "安装预编译 RPM: $RPM"
  cp "$RPM" "$R/tmp/$(basename "$RPM")"
  # 临时写 nameserver，装完还原（与 integrate-iot.sh 一致，避免 chroot 内解析失败）
  NS_BAK=""
  if [ -f "$R/etc/resolv.conf" ]; then NS_BAK="$(cat "$R/etc/resolv.conf")"; fi
  echo "nameserver 8.8.8.8" > "$R/etc/resolv.conf"
  chroot "$R" /bin/sh -c "rpm -ivh --nodeps /tmp/$(basename "$RPM"); ldconfig" 2>&1 | tail -20 || true
  # 兜底：若 rpm 在 chroot 内不可用，改宿主 rpm --root
  if [ ! -x "$R/usr/local/bin/mpv" ]; then
    rpm -ivh --root="$R" --nodeps "$RPM" 2>&1 | tail -20 || true
    chroot "$R" ldconfig 2>/dev/null || true
  fi
  [ -n "$NS_BAK" ] && echo "$NS_BAK" > "$R/etc/resolv.conf" || rm -f "$R/etc/resolv.conf"
  rm -f "$R/tmp/$(basename "$RPM")"
  log "RPM 安装完成：检查 $R/usr/local/bin/mpv"
else
  log "未传 --rpm，改为在 rootfs 内联网编译安装（BUILD=yes）"
  BUILD=yes
fi

if [ "$BUILD" = "yes" ]; then
  # 在 chroot 内跑 build-rkmpp-stack.sh（需要网络拉源码）
  cp "$HERE/build-rkmpp-stack.sh" "$R/tmp/" 2>/dev/null || true
  cp "$HERE/mpp.patch" "$HERE/vd_lavc-rkmpp-drm.patch" "$R/tmp/" 2>/dev/null || true
  chroot "$R" /bin/bash /tmp/build-rkmpp-stack.sh build 2>&1 | tail -30 || \
    { echo "chroot 内编译失败（多半是网络无法拉源码）；建议改用 --rpm 预编译包"; exit 1; }
  rm -f "$R/tmp/build-rkmpp-stack.sh" "$R/tmp/mpp.patch" "$R/tmp/vd_lavc-rkmpp-drm.patch"
fi

# 校验
if [ -x "$R/usr/local/bin/mpv" ]; then
  log "OK: $R/usr/local/bin/mpv 已就位"
else
  echo "警告: mpv 未出现在 rootfs 中，请检查上面的安装/编译日志"
  exit 1
fi
