#!/usr/bin/env bash
# ============================================================================
# 组装镜像：openEuler 官方 qcow2 的 rootfs + Armbian 已验证的 bootloader/内核
#
# 全程只做文件操作，不编译任何东西。在 aarch64 Linux 上跑（depmod 必须原生）。
#
# 用法：
#   sudo ./build-image.sh <boot-assets.tar.zst> <oe.qcow2.xz> <out.img>
#
# 环境变量：
#   BOARD_CONF  板级配置（默认 boards/h96-m9/board.conf）
#   WORK        中间目录（默认 ./work，CI 里建议放 /mnt）
#   ROOT_PW     root 密码（默认 openeuler）
#   SKIP_DEPMOD=1  跳过 chroot depmod（调试用，产物大概率起不来）
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
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

BOOT_TAR="${1:?缺 boot assets tar}"
OE_XZ="${2:?缺 openEuler qcow2.xz}"
OUT_IMG="${3:?缺输出镜像路径}"
WORK="${WORK:-$HERE/../work}"
ROOT_PW="${ROOT_PW:-openeuler}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = aarch64 ] || die "必须 aarch64（depmod 要原生跑）。当前 $(uname -m)。"

mkdir -p "$WORK"
R="$WORK/rootfs"
MNT_OE="$WORK/mnt-oe"
LOOP_OE=""; LOOP_OUT=""
cleanup() {
  set +e
  umount "$R/dev/pts" 2>/dev/null; umount "$R/dev" 2>/dev/null
  umount "$R/proc" 2>/dev/null;    umount "$R/sys" 2>/dev/null
  umount "$MNT_OE" 2>/dev/null
  [ -n "$LOOP_OE"  ] && losetup -d "$LOOP_OE" 2>/dev/null
  [ -n "$LOOP_OUT" ] && losetup -d "$LOOP_OUT" 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. boot 资产
# ---------------------------------------------------------------------------
log "解包 boot 资产"
rm -rf "$WORK/ba"; mkdir -p "$WORK/ba"
tar -I zstd -xf "$BOOT_TAR" -C "$WORK/ba"
BA="$WORK/ba"
[ -f "$BA/bootloader-16M.bin" ] || die "boot 资产缺 bootloader-16M.bin"
[ -f "$BA/boot/Image" ]         || die "boot 资产缺 boot/Image"
[ -d "$BA/lib/modules/$KERNEL_VER" ] || die "boot 资产缺 lib/modules/$KERNEL_VER"
BSZ=$(stat -c %s "$BA/bootloader-16M.bin")
[ "$BSZ" -eq "$BOOTLOADER_BYTES" ] || die "bootloader 区大小 $BSZ != $BOOTLOADER_BYTES"
info "Image     : $(du -h "$BA/boot/Image" | cut -f1)"
info "modules   : $(du -sh "$BA/lib/modules/$KERNEL_VER" | cut -f1)"
info "bootloader: $(du -h "$BA/bootloader-16M.bin" | cut -f1)"

# bootloader 区自带 GPT，分区 1 的起始 LBA 就在里面（GPT 项偏移 1056 = LBA2*512 + 32）。
# 以实测为准：不同板厂给的镜像不保证都是 32768，配置里那个只是兜底。
DET_LBA=$(od -An -tu8 -j 1056 -N 8 "$BA/bootloader-16M.bin" | tr -d ' \n')
if [ -n "$DET_LBA" ] && [ "$DET_LBA" != "0" ]; then
  if [ "$DET_LBA" -ne "$PART_START_LBA" ]; then
    info "⚠ bootloader 内 GPT 的分区起点是 LBA $DET_LBA（配置写的是 $PART_START_LBA）→ 以实测为准"
    PART_START_LBA=$DET_LBA
  else
    info "分区起点校验通过：LBA $PART_START_LBA"
  fi
else
  info "⚠ bootloader 区内没读到有效 GPT 项，沿用配置值 LBA $PART_START_LBA"
fi

# ---------------------------------------------------------------------------
# 2. openEuler rootfs
# ---------------------------------------------------------------------------
log "解压 openEuler 整机镜像"
OE_RAW="$WORK/oe.raw"
if [ "${OE_XZ##*.}" = xz ]; then
  xz -dc "$OE_XZ" > "$OE_RAW.unc"   # 官方给的是 .qcow2.xz
  MV_SRC="$OE_RAW.unc"
else
  MV_SRC="$OE_XZ"
fi
if qemu-img info "$MV_SRC" 2>/dev/null | grep -qi 'file format: qcow2'; then
  info "qcow2 → raw 转换（稀疏，约 10 GiB 虚拟大小）"
  qemu-img convert -p -O raw "$MV_SRC" "$OE_RAW"
  rm -f "$MV_SRC"
else
  mv "$MV_SRC" "$OE_RAW"
fi

log "定位 openEuler 根分区"
LOOP_OE=$(losetup --find --show --partscan "$OE_RAW")
mkdir -p "$MNT_OE"
ROOTDEV=""
for p in $(lsblk -lnpo NAME,FSTYPE "$LOOP_OE" | awk '$2=="ext4"||$2=="xfs"{print $1}'); do
  mount -o ro "$p" "$MNT_OE" 2>/dev/null || continue
  if grep -qs '^ID="*openEuler' "$MNT_OE/etc/os-release"; then ROOTDEV="$p"; break; fi
  umount "$MNT_OE"
done
[ -n "$ROOTDEV" ] || die "qcow2 里没找到 openEuler 根分区。实际分区：$(lsblk -lnpo NAME,SIZE,FSTYPE "$LOOP_OE" | tr '\n' ' ')"
info "根分区: $ROOTDEV ($(findmnt -no SIZE --target "$MNT_OE" 2>/dev/null || echo '?'))"
info "$(grep -E '^(PRETTY_NAME|VERSION_ID)=' "$MNT_OE/etc/os-release" | tr '\n' ' ')"

log "抄出 rootfs（保留 xattr / ACL / SELinux 上下文）"
rm -rf "$R"; mkdir -p "$R"
rsync -aHAX --numeric-ids "$MNT_OE/" "$R/"
umount "$MNT_OE"
losetup -d "$LOOP_OE"; LOOP_OE=""
rm -f "$OE_RAW"
info "rootfs 内容: $(du -sh "$R" | cut -f1)"

# ---------------------------------------------------------------------------
# 3. 换内核：清掉 openEuler 自带的，装上 Armbian 的
# ---------------------------------------------------------------------------
log "替换内核与模块"
rm -rf "${R:?}/lib/modules/"*
rm -rf "${R:?}/boot/"*
mkdir -p "$R/boot/dtb/rockchip" "$R/boot/extlinux" "$R/lib/modules"
cp -a "$BA/boot/Image" "$R/boot/Image"
cp -a "$BA/boot/dtb/rockchip/$DTB" "$R/boot/dtb/rockchip/$DTB"
cp -a "$BA/lib/modules/$KERNEL_VER" "$R/lib/modules/"
info "已装 /boot/Image、/boot/dtb/rockchip/$DTB、/lib/modules/$KERNEL_VER"

# ---------------------------------------------------------------------------
# 4. extlinux.conf —— 优先改写板上原文件，不凭空造 cmdline
# ---------------------------------------------------------------------------
log "生成 extlinux.conf"
SRC_CONF="$BA/boot/extlinux/extlinux.conf"
if [ -f "$SRC_CONF" ]; then
  KL=$(grep -m1 -E '^[[:space:]]*kernel[[:space:]]' "$SRC_CONF" || true)
  FL=$(grep -m1 -E '^[[:space:]]*fdt[[:space:]]'    "$SRC_CONF" || true)
  AP=$(grep -m1 -E '^[[:space:]]*append[[:space:]]' "$SRC_CONF" | sed -E 's/^[[:space:]]*append[[:space:]]+//' || true)
  [ -n "$KL" ] || KL="  kernel /Image"
  [ -n "$FL" ] || FL="  fdt /dtb/rockchip/$DTB"
  [ -n "$AP" ] || AP="root=UUID=$ROOT_UUID rootwait rw console=$CONSOLE"
  info "继承板上原始 cmdline：$AP"
else
  KL="  kernel /Image"; FL="  fdt /dtb/rockchip/$DTB"
  AP="root=UUID=$ROOT_UUID rootwait rw console=$CONSOLE"
  info "板上无 extlinux.conf，使用内置模板"
fi
# UUID 强制对齐；CMA / SELinux 缺失则补
AP=$(printf '%s' "$AP" | sed -E "s#root=[^ ]+#root=UUID=$ROOT_UUID#")
case " $AP " in *" cma="*) AP=$(printf '%s' "$AP" | sed -E "s#cma=[^ ]+#cma=$CMA#") ;; *) AP="$AP cma=$CMA" ;; esac
case " $AP " in *" selinux="*) AP=$(printf '%s' "$AP" | sed -E "s#selinux=[^ ]+#selinux=$SELINUX#") ;; *) AP="$AP selinux=$SELINUX" ;; esac
case " $AP " in *cgroup_enable=*) ;; *) AP="$AP cgroup_enable=memory" ;; esac

cat > "$R/boot/extlinux/extlinux.conf" <<EOF
# 由 openeuler-rockchip-builds 生成 —— 手工修改会在下次构建被覆盖
label openEuler
$KL
$FL
  append $AP
EOF
cat "$R/boot/extlinux/extlinux.conf"
# 不要 initrd：MMC/SDHCI/EXT4 全 =y，rootfs 自带的内核 initramfs 与 6.1.172 无关
rm -f "$R/boot/initrd"* "$R/boot/uInitrd"* 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. fstab —— 官方 qcow2 的条目（/boot、/boot/efi、xfs 根）会直接进 emergency
# ---------------------------------------------------------------------------
log "重写 /etc/fstab"
cat > "$R/etc/fstab" <<EOF
UUID=$ROOT_UUID  /      ext4  defaults,noatime,errors=remount-ro  0 1
tmpfs            /tmp   tmpfs defaults,nosuid,nodev,size=2G       0 0
EOF
cat "$R/etc/fstab"

# ---------------------------------------------------------------------------
# 6. 用户态收尾：root 密码 / sshd / SELinux
# ---------------------------------------------------------------------------
log "用户态配置"
grep -q '^root:' "$R/etc/passwd" || die "/etc/passwd 无 root"
# 直接写 shadow 哈希，避免 chroot 里 passwd 依赖 PAM/SELinux 而失败
if command -v openssl >/dev/null; then
  HASH=$(openssl passwd -6 "$ROOT_PW")
  awk -F: -v h="$HASH" 'BEGIN{OFS=":"} $1=="root"{ $2=h } {print}' "$R/etc/shadow" > "$R/etc/shadow.new"
  mv "$R/etc/shadow.new" "$R/etc/shadow"; chmod 000 "$R/etc/shadow"
  info "root 密码已设为构建参数值"
else
  info "无 openssl，root 密码保持官方默认（首次登录需改）"
fi
# sshd：允许 root 密码登录（headless bring-up 期必需）
if [ -f "$R/etc/ssh/sshd_config" ]; then
  sed -i -E 's/^#?\s*PermitRootLogin\s+.*/PermitRootLogin yes/' "$R/etc/ssh/sshd_config"
  grep -qE '^PermitRootLogin\s+yes' "$R/etc/ssh/sshd_config" || echo 'PermitRootLogin yes' >> "$R/etc/ssh/sshd_config"
  sed -i -E 's/^#?\s*PasswordAuthentication\s+.*/PasswordAuthentication yes/' "$R/etc/ssh/sshd_config"
fi
# SELinux 配置文件与 cmdline 保持一致（cmdline 里的 selinux=0 优先级最高，这里是双保险）
if [ -d "$R/etc/selinux" ]; then
  echo "SELINUX=$SELINUX" > "$R/etc/selinux/config"
  echo "SELINUXTYPE=targeted" >> "$R/etc/selinux/config"
fi
# 拿掉 openEuler 对 qcow2 的 cloud-init 依赖（无 metadata 服务会拖慢首启）
for u in cloud-init cloud-init-local cloud-config cloud-final; do
  rm -f "$R/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 7. depmod —— 必须用 rootfs 自带的 depmod，宿主的 kmod 版本不同会写出
#    不兼容的 modules.dep.bin（症状：能起、串口能登，但 lsmod 空、网卡/音频全哑）
# ---------------------------------------------------------------------------
if [ "${SKIP_DEPMOD:-0}" != 1 ]; then
  log "chroot 内执行 depmod（目标 rootfs 自带）"
  [ -x "$R/usr/sbin/depmod" ] || die "rootfs 里没有 /usr/sbin/depmod"
  mount --bind /dev "$R/dev"; mount --bind /dev/pts "$R/dev/pts" 2>/dev/null || true
  mount -t proc proc "$R/proc"; mount -t sysfs sys "$R/sys"
  chroot "$R" /usr/sbin/depmod -a "$KERNEL_VER"
  umount "$R/dev/pts" 2>/dev/null; umount "$R/dev"; umount "$R/proc"; umount "$R/sys"
  [ -s "$R/lib/modules/$KERNEL_VER/modules.dep" ] || die "modules.dep 生成失败"
  info "modules.dep: $(wc -l < "$R/lib/modules/$KERNEL_VER/modules.dep") 条依赖"
else
  info "SKIP_DEPMOD=1，跳过（首启后需手动 depmod -a && reboot）"
fi

# ---------------------------------------------------------------------------
# 8. 定尺寸：分区 = 内容 + slack，mkfs 按分区大小 → 首启无需 resize2fs
# ---------------------------------------------------------------------------
log "计算分区大小"
USED_KB=$(du -s -B1K "$R" | cut -f1)
USED_BYTES=$((USED_KB * 1024))
PART_BYTES=$(( USED_BYTES * (100 + SLACK_PCT) / 100 ))
# 对齐到 1 MiB
PART_BYTES=$(( (PART_BYTES + 1048575) / 1048576 * 1048576 ))
PART_START_BYTES=$(( PART_START_LBA * 512 ))
IMG_BYTES=$(( PART_START_BYTES + PART_BYTES + 1048576 ))   # 尾部留 1 MiB 给 GPT backup
info "内容 $(numfmt --to=iec "$USED_BYTES") → 分区 $(numfmt --to=iec "$PART_BYTES")，整镜像 $(numfmt --to=iec "$IMG_BYTES")"

# ---------------------------------------------------------------------------
# 9. 拼装
# ---------------------------------------------------------------------------
log "拼装镜像"
rm -f "$OUT_IMG"
truncate -s "$IMG_BYTES" "$OUT_IMG"
# ① bootloader 区原样写入（含 GPT 主表与分区项）
dd if="$BA/bootloader-16M.bin" of="$OUT_IMG" bs=1M conv=notrunc status=none
# ② rootfs
FSIMG="$WORK/rootfs.ext4"
rm -f "$FSIMG"
truncate -s "$PART_BYTES" "$FSIMG"
mkfs.ext4 -q -F -L "$ROOT_LABEL" -U "$ROOT_UUID" -m 1 "$FSIMG"
LOOP_OUT=$(losetup --find --show "$FSIMG")
mkdir -p "$WORK/mnt-out"; mount "$LOOP_OUT" "$WORK/mnt-out"
rsync -aHAX --numeric-ids "$R/" "$WORK/mnt-out/"
sync
umount "$WORK/mnt-out"
losetup -d "$LOOP_OUT"; LOOP_OUT=""
dd if="$FSIMG" of="$OUT_IMG" bs=1M seek=$((PART_START_BYTES / 1048576)) conv=notrunc status=none
rm -f "$FSIMG"
# ③ GPT 分区项改成新尺寸（bootloader 里带的是旧的 2659 MiB）
log "修正 GPT 分区表"
sgdisk -d 1 "$OUT_IMG" >/dev/null
sgdisk -n "1:${PART_START_LBA}:0" -t 1:8300 -c "1:${ROOT_LABEL}" "$OUT_IMG" >/dev/null
sgdisk -e "$OUT_IMG" >/dev/null 2>&1 || true
sgdisk -v "$OUT_IMG" | tail -3
info "分区 1 起点 LBA $(sgdisk -i 1 "$OUT_IMG" | awk -F: '/First sector/{gsub(/ /,"",$2);print $2}')"

# ---------------------------------------------------------------------------
# 10. 校验
# ---------------------------------------------------------------------------
log "校验"
bash "$HERE/verify-image.sh" "$OUT_IMG"
log "完成：$OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
