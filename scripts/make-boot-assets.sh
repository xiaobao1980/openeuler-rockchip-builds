#!/usr/bin/env bash
# ============================================================================
# 打包「已验证可启动的 boot 资产」
#
# 为什么单独打包：openEuler 只换用户态，bootloader / Image / dtb / modules
# 必须用 Armbian 板上已经跑通的那一份。整包 2.6 GB 的 Armbian 镜像搬进 CI
# 太慢，抽出来只有 ~130 MB（zst 后 ~50 MB），作为 Release 资产一次发布、
# 后续每次构建复用。
#
# 用法（在 Linux / aarch64 板子上跑，macOS 无 loop 设备不可用）：
#   sudo ./make-boot-assets.sh --from-dev /dev/mmcblk0   # 从正在跑这张卡抓
#   sudo ./make-boot-assets.sh --from-image Armbian-*.img.xz
#
# 产物：out/boot-<board>-<kver>.tar.zst + .sha256
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# BOARD=<id> 指定板卡；配置由 board-resolve.sh 统一解析（手写 conf 优先，其次 TSV 推导）
BOARD="${BOARD:-h96-m9}"
if [ -n "${BOARD_CONF:-}" ]; then
  # shellcheck disable=SC1090
  . "$BOARD_CONF"
else
  # 不用进程替换：部分环境 /dev/fd 不可用，落临时文件更稳
  _CF=$(mktemp)
  bash "$HERE/board-resolve.sh" "$BOARD" > "$_CF"
  # shellcheck disable=SC1090
  . "$_CF"
  rm -f "$_CF"
fi

OUT_DIR="${OUT_DIR:-$HERE/../out}"
MNT=$(mktemp -d)
LOOP=""

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
cleanup() {
  set +e
  umount "$MNT/boot" 2>/dev/null
  umount "$MNT/lib" 2>/dev/null
  umount "$MNT/ro" 2>/dev/null
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
  rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT

MODE=""; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from-dev)   MODE=dev;   SRC="$2"; shift 2 ;;
    --from-image) MODE=image; SRC="$2"; shift 2 ;;
    *) die "未知参数 $1" ;;
  esac
done
[ -n "$MODE" ] || die "必须给 --from-dev <块设备> 或 --from-image <.img|.img.xz>"

mkdir -p "$OUT_DIR/stage"

# --- 1. 取出前 16 MiB（MBR + GPT + idbloader + u-boot.itb）------------------
log "抽取 bootloader 区（前 ${BOOTLOADER_BYTES} 字节）"
if [ "$MODE" = dev ]; then
  [ -b "$SRC" ] || die "$SRC 不是块设备"
  dd if="$SRC" of="$OUT_DIR/stage/bootloader-16M.bin" bs=512 count=$((BOOTLOADER_BYTES / 512)) status=none
  ROOTDEV="$(lsblk -lnpo NAME,FSTYPE "$SRC" | awk '$2=="ext4"{print $1; exit}')"
  [ -n "$ROOTDEV" ] || die "在 $SRC 上找不到 ext4 分区"
  SYSROOT=""
  mount -o ro "$ROOTDEV" "$MNT/ro" || die "挂载 $ROOTDEV 失败"
  SYSROOT="$MNT/ro"
else
  IMG="$SRC"
  case "$IMG" in
    *.xz) log "解压 $IMG（约 2.6 GB，需数分钟）"; xz -dc "$IMG" > "$OUT_DIR/stage/armbian.img" ;;
    *)    cp --reflink=auto "$IMG" "$OUT_DIR/stage/armbian.img" ;;
  esac
  IMG="$OUT_DIR/stage/armbian.img"
  dd if="$IMG" of="$OUT_DIR/stage/bootloader-16M.bin" bs=512 count=$((BOOTLOADER_BYTES / 512)) status=none
  LOOP=$(losetup --find --show --partscan "$IMG")
  ROOTDEV="$(lsblk -lnpo NAME,FSTYPE "$LOOP" | awk '$2=="ext4"{print $1; exit}')"
  [ -n "$ROOTDEV" ] || die "镜像里找不到 ext4 分区"
  mount -o ro "$ROOTDEV" "$MNT/ro" || die "挂载 $ROOTDEV 失败"
  SYSROOT="$MNT/ro"
fi

# --- 2. 抄出 Image / dtb / modules / extlinux.conf -------------------------
log "抄出内核与模块（$KERNEL_VER）"
[ -f "$SYSROOT/boot/Image" ] || die "$SYSROOT/boot/Image 不存在 — 不是 Armbian 镜像？"
[ -d "$SYSROOT/lib/modules/$KERNEL_VER" ] || die "$SYSROOT/lib/modules/$KERNEL_VER 不存在 — 板上实际内核版本是：$(ls "$SYSROOT/lib/modules")"

B="$OUT_DIR/stage/boot"
rm -rf "$B"; mkdir -p "$B/boot/dtb/rockchip" "$B/boot/extlinux" "$B/lib/modules"
cp -a "$SYSROOT/boot/Image" "$B/boot/"
# dtb 可能在 /boot/dtb/rockchip/ 也可能在 /boot/dtb/ 根
for d in "$SYSROOT/boot/dtb/rockchip/$DTB" "$SYSROOT/boot/dtb/$DTB" "$SYSROOT/boot/$DTB"; do
  [ -f "$d" ] && { cp -a "$d" "$B/boot/dtb/rockchip/"; break; }
done
[ -f "$B/boot/dtb/rockchip/$DTB" ] || die "找不到 $DTB"
cp -a "$SYSROOT/lib/modules/$KERNEL_VER" "$B/lib/modules/"
[ -f "$SYSROOT/boot/extlinux/extlinux.conf" ] && cp -a "$SYSROOT/boot/extlinux/extlinux.conf" "$B/boot/extlinux/"
# 顺手把原 cmdline 存一份，构建时按它改写（不自己凭空捏 root=/console=）
[ -f "$SYSROOT/boot/armbianEnv.txt" ] && cp -a "$SYSROOT/boot/armbianEnv.txt" "$B/boot/" || true

umount "$MNT/ro"; SYSROOT=""
[ "$MODE" = image ] && rm -f "$OUT_DIR/stage/armbian.img"

# --- 3. 记录清单，便于回溯 ------------------------------------------------
log "生成清单"
{
  echo "board=$BOARD_ID"
  echo "model=$MODEL"
  echo "kernel=$KERNEL_VER"
  echo "dtb=$DTB"
  echo "built_at=$(date -u +%FT%TZ)"
  echo "source=$MODE:$SRC"
  echo "--- bootloader sha256 ---"
  sha256sum "$OUT_DIR/stage/bootloader-16M.bin" | awk '{print $1}'
  echo "--- files ---"
  ( cd "$B" && find . -type f -printf '%s\t%p\n' | sort -k2 )
} > "$B/MANIFEST.txt"
cat "$B/MANIFEST.txt" | head -12

# --- 4. 打包 --------------------------------------------------------------
TAR="$OUT_DIR/boot-${BOARD_ID}-${KERNEL_VER%%-*}.tar.zst"
log "打包 $TAR"
tar --numeric-owner -I 'zstd -19 -T0 --long=27' -cf "$TAR" \
    -C "$OUT_DIR/stage" bootloader-16M.bin boot
sha256sum "$TAR" | sed 's| .*/| |' > "$TAR.sha256"
ls -lh "$TAR" "$TAR.sha256"

log "完成。发布到 Release 后 CI 即可消费："
echo "  gh release create ${BOOT_ASSETS_TAG} \"$TAR\" \"$TAR.sha256\" \\"
echo "    --repo <owner>/openeuler-rockchip-builds --title \"boot assets ${BOARD_ID} ${KERNEL_VER}\""
