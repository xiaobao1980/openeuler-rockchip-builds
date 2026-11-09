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
#   INTEGRATE=none|iot   烘焙 IoT 服务栈（Node-RED / Mosquitto / Zigbee2MQTT）
#   IOT_STACK / IOT_MQTT_USER / IOT_MQTT_PASS / IOT_COORD / IOT_ADAPTER 等
#               见 scripts/integrate-iot.sh 的选项说明
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

# --- CI 覆盖：workflow 的 inputs 落到 board.conf 推导出来的默认值上 -----------
# 不在这里合并的话，workflow 里选 selinux=permissive 会被 board.conf 的 disabled 静默吃掉
CMA="${CMA_OVERRIDE:-$CMA}"
SELINUX="${SELINUX_MODE:-$SELINUX}"
OE_VERSION="${OE_VER:-$OE_VERSION}"
INTEGRATE="${INTEGRATE:-none}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = aarch64 ] || die "必须 aarch64（depmod 要原生跑）。当前 $(uname -m)。"

# 无 initrd 的内核只认 root=PARTUUID= / PARTLABEL= / /dev/xxx，不认 root=UUID=
# （文件系统 UUID 是 initramfs 里 udev/blkid 解析的）。所以 GPT 分区 GUID 必须
# 显式固定，且不能与文件系统 UUID 混为一谈。缺了就立刻停，别做出起不来的镜像。
case "${ROOT_PARTUUID:-}" in
  ????????-????-????-????-????????????) ;;
  *) die "板级配置缺合法的 ROOT_PARTUUID（当前：${ROOT_PARTUUID:-<空>}）。见 boards/_template/board.conf 坑 #19" ;;
esac

mkdir -p "$WORK"
R="$WORK/rootfs"
MNT_OE="$WORK/mnt-oe"
LOOP_OE=""; LOOP_OUT=""
cleanup() {
  set +e
  umount "$R/dev/pts" 2>/dev/null; umount "$R/dev" 2>/dev/null
  umount "$R/proc" 2>/dev/null;    umount "$R/sys" 2>/dev/null
  umount "$MNT_OE" 2>/dev/null
  command -v vgchange >/dev/null 2>&1 && vgchange -an >/dev/null 2>&1
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

# --- 内核版本以 boot 资产为准 -----------------------------------------------
# board.conf 里的 KERNEL_VER 只是模板默认值（6.1.172），而板上/官方镜像里实际跑的
# 可能是 6.1.115、6.1.172 等不同小版本。资产里有且只有一个 lib/modules/<ver>，
# 那才是必须一字不差用在 depmod 和 /lib/modules 上的值。
if [ -d "$BA/lib/modules" ]; then
  _kv=$(find "$BA/lib/modules" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | awk 'NR==1')
  if [ -n "$_kv" ] && [ "$_kv" != "$KERNEL_VER" ]; then
    info "⚠ 内核版本以资产为准：$KERNEL_VER → $_kv"
    KERNEL_VER=$_kv
  fi
fi

# --- DTB 名也以资产为准 -----------------------------------------------------
# 上游 96 块板里，board.conf 推导出的 dtb 名来自 BOOT_FDT_FILE，个别板（走 fdtdir）
# 与镜像里实际文件名不一致。资产里只有一个 dtb 时直接采用，避免无谓失败。
if [ ! -f "$BA/boot/dtb/rockchip/$DTB" ] && [ -d "$BA/boot/dtb/rockchip" ]; then
  _n=$(find "$BA/boot/dtb/rockchip" -maxdepth 1 -name '*.dtb' | wc -l | tr -d ' ')
  if [ "$_n" = 1 ]; then
    _d=$(find "$BA/boot/dtb/rockchip" -maxdepth 1 -name '*.dtb' -exec basename {} \;)
    info "⚠ DTB 以资产为准：$DTB → $_d"
    DTB=$_d
  fi
fi

[ -f "$BA/bootloader-16M.bin" ] || die "boot 资产缺 bootloader-16M.bin"
[ -f "$BA/boot/Image" ]         || die "boot 资产缺 boot/Image"
[ -d "$BA/lib/modules/$KERNEL_VER" ] || die "boot 资产缺 lib/modules/$KERNEL_VER（资产里只有：$(ls "$BA/lib/modules" 2>/dev/null | tr '\n' ' ')）"
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
LOOP_OE=$(losetup --find --show --partscan "$OE_RAW") || die "losetup 失败"
partprobe "$LOOP_OE" 2>/dev/null || true
sleep 1

# openEuler 官方整机镜像默认走 LVM：p1=/boot(ext4)、p2=LVM PV → /dev/openeuler/root。
# 未激活时 lsblk 对 PV 的 FSTYPE 是空的，按 FSTYPE 挑分区必然挑不到，所以：
#   ① 先 vgchange -ay 激活；② 再按「试挂载 + 看 /etc/os-release」判定，不猜类型。
if command -v vgchange >/dev/null 2>&1; then
  vgchange -ay >/dev/null 2>&1 || true
fi

mkdir -p "$MNT_OE"
ROOTDEV=""
CANDS=$( { lsblk -lnpo NAME,FSTYPE "$LOOP_OE" | awk '$2!=""{print $1}'; ls /dev/mapper/* 2>/dev/null; } | awk '!seen[$0]++' )
for p in $CANDS; do
  mount -o ro "$p" "$MNT_OE" 2>/dev/null || continue
  if grep -qs '^ID="*openEuler' "$MNT_OE/etc/os-release"; then ROOTDEV="$p"; break; fi
  umount "$MNT_OE" 2>/dev/null
done
[ -n "$ROOTDEV" ] || die "qcow2 里没找到 openEuler 根分区。分区：$(lsblk -lnpo NAME,SIZE,FSTYPE "$LOOP_OE" | tr '\n' ' ')| mapper：$(ls /dev/mapper 2>/dev/null | tr '\n' ' ')"
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
# -L：万一资产里的 Image 仍是符号链接（旧资产），解引用成真实文件
cp -aL "$BA/boot/Image" "$R/boot/Image"
ISZ=$(stat -c %s "$R/boot/Image" 2>/dev/null || echo 0)
[ "$ISZ" -gt 5242880 ] || die "/boot/Image 只有 $ISZ 字节，不是内核（符号链接没解引用？）"
cp -a "$BA/boot/dtb/rockchip/$DTB" "$R/boot/dtb/rockchip/$DTB"
cp -a "$BA/lib/modules/$KERNEL_VER" "$R/lib/modules/"
info "已装 /boot/Image、/boot/dtb/rockchip/$DTB、/lib/modules/$KERNEL_VER"

# ---------------------------------------------------------------------------
# 4. extlinux.conf —— cmdline 优先继承板上原文件，路径一律按本镜像布局重写
# ---------------------------------------------------------------------------
# 真机教训 1（坑 #18，U-Boot 2017.09_armbian）：该 Armbian 镜像根本没有
# extlinux.conf，内置模板写的 `kernel /Image`、`fdt /dtb/rockchip/...` 是
# 「相对 /boot」口径；vendor U-Boot 的 sysboot 却按分区根解析 → /Image 找不到。
# 本仓库把内核与 dtb 固定装在 /boot/ 下，故 kernel/fdt 必须自己重写，只继承 append。
#
# 真机教训 2（坑 #19，第二轮上板）：append 里的 `root=UUID=<文件系统UUID>` 让
# 内核卡死在 `Waiting for root device UUID=...`。vendor 6.1 内核 init/do_mounts.c
# 的 name_to_dev_t() 只接受 PARTUUID= / PARTLABEL= / /dev/xxx / 设备号，没有
# UUID= 分支——文件系统 UUID 是 initramfs 里 udev/blkid 解析的，而我们按设计
# 不装 initrd。上游 Armbian 的 boot-rk35xx.cmd 也用 PARTUUID=${partuuid} 做
# rootdev，并明确警告硬编码 /dev/mmcblk0p1 会因 mmc 编号漂移指错设备。
# 因此：固定 GPT 分区项 1 的 GUID，cmdline 用 root=PARTUUID= 指向它。
log "生成 extlinux.conf"
SRC_CONF="$BA/boot/extlinux/extlinux.conf"
KL="  kernel /boot/Image"
FL="  fdt /boot/dtb/rockchip/$DTB"
if [ -f "$SRC_CONF" ]; then
  AP=$(grep -m1 -E '^[[:space:]]*append[[:space:]]' "$SRC_CONF" | sed -E 's/^[[:space:]]*append[[:space:]]+//' || true)
  [ -n "$AP" ] || AP="root=PARTUUID=$ROOT_PARTUUID rootwait rw rootfstype=ext4 console=$CONSOLE"
  info "继承板上原始 cmdline：$AP"
else
  AP="root=PARTUUID=$ROOT_PARTUUID rootwait rw rootfstype=ext4 console=$CONSOLE"
  info "板上无 extlinux.conf，使用内置 cmdline（kernel/fdt/root 全部按本镜像重写）"
fi
# root= 强制对齐到 GPT 分区 GUID；rootfstype 补上，省得内核逐个试文件系统
AP=$(printf '%s' "$AP" | sed -E "s#root=[^ ]+#root=PARTUUID=$ROOT_PARTUUID#")
case " $AP " in *" rootfstype="*) ;; *) AP="$AP rootfstype=ext4" ;; esac
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
# 兼容层：有些 vendor U-Boot 会把 conf 路径剥成 /Image、/dtb/... 去分区根找。
# 用硬链接把 /boot 下的实体文件再挂一份到根：同 inode、不额外占空间，也不是
# 符号链接（U-Boot 2017.09 的 ext4 驱动不跟随 symlink，软链必然读成一小段文本）。
# rsync -aHAX 的 -H 会把这层硬链接带进最终 ext4。
ln -f "$R/boot/Image" "$R/Image"
mkdir -p "$R/dtb/rockchip"
ln -f "$R/boot/dtb/rockchip/$DTB" "$R/dtb/rockchip/$DTB"
info "根兼容层：/Image、/dtb/rockchip/$DTB（硬链接，零额外占用）"
# 不要 initrd：MMC/SDHCI/EXT4 全 =y，rootfs 自带的内核 initramfs 与 6.1.172 无关
rm -f "$R/boot/initrd"* "$R/boot/uInitrd"* 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. fstab —— 官方 qcow2 的条目（/boot、/boot/efi、xfs 根）会直接进 emergency
# ---------------------------------------------------------------------------
log "重写 /etc/fstab"
# 注意：fstab 用文件系统 UUID（用户态 blkid/udev 解析，没问题），
# cmdline 用分区 GUID（内核自己解析，无 initrd 时唯一可行）。两者指向同一分区。
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
# 7. 集成安装（可选）：把 IoT 服务栈烘焙进 rootfs
#    必须在「定尺寸」之前 —— 装完会多出几百 MB，尺寸要按最终内容算
# ---------------------------------------------------------------------------
mount_chroot() {
  mountpoint -q "$R/dev"     || mount --bind /dev "$R/dev"
  mountpoint -q "$R/dev/pts" || mount --bind /dev/pts "$R/dev/pts" 2>/dev/null || true
  mountpoint -q "$R/proc"    || mount -t proc proc "$R/proc"
  mountpoint -q "$R/sys"     || mount -t sysfs sys "$R/sys"
}
umount_chroot() {
  umount "$R/dev/pts" 2>/dev/null; umount "$R/dev" 2>/dev/null
  umount "$R/proc" 2>/dev/null;    umount "$R/sys" 2>/dev/null
}

if [ "$INTEGRATE" != "none" ]; then
  log "集成安装：$INTEGRATE（$IOT_STACK）"
  [ -x "$HERE/integrate-iot.sh" ] || die "找不到 scripts/integrate-iot.sh"
  mount_chroot
  # integrate-iot.sh 自己也会检查挂载点，这里的挂载是幂等的
  bash "$HERE/integrate-iot.sh" "$R" \
    --stack="${IOT_STACK:-node-red,mosquitto}" \
    --mqtt-user="${IOT_MQTT_USER:-user-mqtt}" \
    --mqtt-pass="${IOT_MQTT_PASS:-Ab123456}" \
    --mqtt-port="${IOT_MQTT_PORT:-1883}" \
    --ws-port="${IOT_WS_PORT:-8083}" \
    --nodered-port="${IOT_NODERED_PORT:-1880}" \
    --z2m-port="${IOT_Z2M_PORT:-8080}" \
    --coord="${IOT_COORD:-}" \
    --adapter="${IOT_ADAPTER:-zstack}" \
    --node-version="${IOT_NODE_VERSION:-22}" \
    || die "集成安装失败"
  # 先卸载再统计：/proc 还挂着时 du 会走进进程目录，刷一屏 "cannot access .../fd"
  umount_chroot
  info "集成后 rootfs: $(du -sh "$R" | cut -f1)"
fi

# ---------------------------------------------------------------------------
# 8. depmod —— 必须用 rootfs 自带的 depmod，宿主的 kmod 版本不同会写出
#    不兼容的 modules.dep.bin（症状：能起、串口能登，但 lsmod 空、网卡/音频全哑）
# ---------------------------------------------------------------------------
if [ "${SKIP_DEPMOD:-0}" != 1 ]; then
  log "chroot 内执行 depmod（目标 rootfs 自带）"
  [ -x "$R/usr/sbin/depmod" ] || die "rootfs 里没有 /usr/sbin/depmod"
  mount_chroot
  chroot "$R" /usr/sbin/depmod -a "$KERNEL_VER"
  umount_chroot
  [ -s "$R/lib/modules/$KERNEL_VER/modules.dep" ] || die "modules.dep 生成失败"
  info "modules.dep: $(wc -l < "$R/lib/modules/$KERNEL_VER/modules.dep") 条依赖"
else
  info "SKIP_DEPMOD=1，跳过（首启后需手动 depmod -a && reboot）"
fi

# ---------------------------------------------------------------------------
# 9. 定尺寸：分区 = 内容 + slack，mkfs 按分区大小 → 首启无需 resize2fs
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
# 10. 拼装
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
# -n 会生成**随机**分区 GUID；必须显式覆盖成 ROOT_PARTUUID，否则 extlinux.conf
# 里写死的 root=PARTUUID= 找不到分区，内核又会在 `Waiting for root device` 死等。
# 放在 -e（重定位 backup GPT）之后再设，避免后续操作改写分区项。
sgdisk -u "1:${ROOT_PARTUUID}" "$OUT_IMG" >/dev/null
ACTUAL_PU=$(sgdisk -i 1 "$OUT_IMG" | sed -n 's/^Partition unique GUID: //p' | tr 'A-Z' 'a-z')
[ "$ACTUAL_PU" = "$ROOT_PARTUUID" ] || die "分区 GUID 写入失败：期望 $ROOT_PARTUUID，实为 ${ACTUAL_PU:-<空>}"
sgdisk -v "$OUT_IMG" | tail -3
info "分区 1 PARTUUID = $ROOT_PARTUUID（cmdline root=PARTUUID= 指向它）"
# 注意不能用 awk -F: '{print $2}' —— sgdisk 输出是 "First sector: 32768 (at 16.0 MiB)"，
# 去空格后会变成 "32768(at16.0MiB)"，拿去做算术直接报错
info "分区 1 起点 LBA $(sgdisk -i 1 "$OUT_IMG" | sed -n 's/^First sector: \([0-9][0-9]*\).*/\1/p')"

# ---------------------------------------------------------------------------
# 11. 校验
# ---------------------------------------------------------------------------
log "校验"
# 把本次真正生效的值固化成一份 conf 交给校验脚本。
# 不这么做的话 verify 会重新跑 board-resolve，把 PART_START_LBA 拿回配置里的兜底值、
# 把 CMA/SELINUX 拿回模板默认值 —— 上面做的实测与 CI 覆盖全都白做，校验误报失败。
RESOLVED="$WORK/board.resolved.conf"
{
  echo "BOARD_ID=$BOARD_ID"
  echo "MODEL=\"$MODEL\""
  echo "FAMILY=$FAMILY"
  echo "KERNEL_VER=$KERNEL_VER"
  echo "DTB=$DTB"
  echo "PART_START_LBA=$PART_START_LBA"
  echo "BOOTLOADER_BYTES=$BOOTLOADER_BYTES"
  echo "CONSOLE=$CONSOLE"
  echo "ROOT_UUID=$ROOT_UUID"
  echo "ROOT_PARTUUID=$ROOT_PARTUUID"
  echo "ROOT_LABEL=$ROOT_LABEL"
  echo "SLACK_PCT=$SLACK_PCT"
  echo "CMA=$CMA"
  echo "SELINUX=$SELINUX"
  echo "INTEGRATE=$INTEGRATE"
  echo "IOT_STACK=${IOT_STACK:-}"
  echo "IOT_MQTT_PORT=${IOT_MQTT_PORT:-1883}"
  echo "IOT_WS_PORT=${IOT_WS_PORT:-8083}"
  echo "IOT_NODERED_PORT=${IOT_NODERED_PORT:-1880}"
  echo "IOT_Z2M_PORT=${IOT_Z2M_PORT:-8080}"
} > "$RESOLVED"
BOARD_CONF="$RESOLVED" bash "$HERE/verify-image.sh" "$OUT_IMG"

# 被 sudo 调用时把产物交还给调用者。否则 out.img 属 root:root，后续非 root 的
# xz -6 会报 "Cannot set the file group: Operation not permitted" 直接失败。
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_UID:-}" ]; then
  chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT_IMG" 2>/dev/null || true
  chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$WORK" 2>/dev/null || true
  info "产物属主已交还 UID $SUDO_UID（xz/gh 需要非 root 才能改属组）"
fi

log "完成：$OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
