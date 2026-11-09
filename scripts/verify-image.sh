#!/usr/bin/env bash
# ============================================================================
# 镜像静态校验 —— 上板之前先把能查的都查完，避免把「能开机的废镜像」刷进卡
# 用法：sudo ./verify-image.sh <out.img>
# ============================================================================
set -uo pipefail

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

IMG="${1:?缺镜像路径}"

# 与 build-image.sh 保持一致的覆盖规则（独立运行时也不会误报）
CMA="${CMA_OVERRIDE:-$CMA}"
SELINUX="${SELINUX_MODE:-$SELINUX}"
MP=$(mktemp -d); LOOP=""
cleanup() { set +e; umount "$MP" 2>/dev/null; [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; rmdir "$MP" 2>/dev/null; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== 镜像: $IMG ($(du -h "$IMG" | cut -f1)) =="

# --- 分区表 ---------------------------------------------------------------
echo "-- 引导与分区"
chk "GPT 有效 (sgdisk -v)"            "sgdisk -v '$IMG' | grep -q 'No problems found'"
# sgdisk 输出 "First sector: 32768 (at 16.0 MiB)"，只取前一个数字
FIRST=$(sgdisk -i 1 "$IMG" 2>/dev/null | sed -n 's/^First sector: \([0-9][0-9]*\).*/\1/p')
chk "分区 1 起点 = LBA $PART_START_LBA (实为 ${FIRST:-?})" "[ '${FIRST:-0}' = '$PART_START_LBA' ]"
chk "idbloader 区非空 (LBA 64 起)"      "dd if='$IMG' bs=512 skip=64 count=8 status=none | tr -d '\0' | grep -q ."

# --- 文件系统 -------------------------------------------------------------
LOOP=$(losetup --find --show --partscan "$IMG") || { bad "loop 挂载失败"; exit 1; }
P1="${LOOP}p1"
chk "分区 1 文件系统 = ext4"           "[ \"\$(blkid -o value -s TYPE '$P1')\" = ext4 ]"
chk "文件系统 UUID = $ROOT_UUID"        "[ \"\$(blkid -o value -s UUID '$P1')\" = '$ROOT_UUID' ]"
mount -o ro "$P1" "$MP" || { bad "挂载 $P1 失败"; exit 1; }

echo "-- 系统身份"
chk "/etc/os-release 是 openEuler"     "grep -q '^ID=\"*openEuler' '$MP/etc/os-release'"
chk "/etc/passwd 有 root"              "grep -q '^root:' '$MP/etc/passwd'"
chk "/usr/sbin/depmod 存在"             "[ -x '$MP/usr/sbin/depmod' ]"
chk "/usr/sbin/sshd 存在"               "[ -x '$MP/usr/sbin/sshd' ]"

echo "-- 内核与模块"
chk "/boot/Image 存在且 >10MB"          "[ -f '$MP/boot/Image' ] && [ \$(stat -c %s '$MP/boot/Image') -gt 10485760 ]"
chk "/boot/dtb/rockchip/$DTB 存在"      "[ -f '$MP/boot/dtb/rockchip/$DTB' ]"
chk "/lib/modules 只有 $KERNEL_VER"     "[ \"\$(ls '$MP/lib/modules')\" = '$KERNEL_VER' ]"
chk "modules.dep 非空"                  "[ -s '$MP/lib/modules/$KERNEL_VER/modules.dep' ]"
chk "无 openEuler 自带 vmlinuz 残留"    "! ls '$MP'/boot/vmlinuz* >/dev/null 2>&1"

echo "-- 引导配置"
CONF="$MP/boot/extlinux/extlinux.conf"
chk "extlinux.conf 存在"                "[ -f '$CONF' ]"
chk "cmdline 含 root=UUID=$ROOT_UUID"    "grep -q 'root=UUID=$ROOT_UUID' '$CONF'"
chk "cmdline 含 cma=$CMA"               "grep -q 'cma=$CMA' '$CONF'"
chk "cmdline 含 selinux=$SELINUX"        "grep -q 'selinux=$SELINUX' '$CONF'"
chk "cmdline 未引用 initrd"             "! grep -qE '^[[:space:]]*(initrd|fdtdir)' '$CONF'"
chk "console=$CONSOLE"                  "grep -q 'console=$CONSOLE' '$CONF'"

# 真机教训：conf 里写了路径、镜像里却没有对应实体文件时，上面这些「字符串」校验
# 全过也照样起不来（U-Boot: ** File not found /Image **）。必须把路径解析出来落地查。
KPATH=$(sed -nE 's/^[[:space:]]*kernel[[:space:]]+//p' "$CONF" | awk 'NR==1')
FPATH=$(sed -nE 's/^[[:space:]]*fdt[[:space:]]+//p'    "$CONF" | awk 'NR==1')
chk "conf kernel 路径指向实体内核 (${KPATH:-无})" "[ -n '$KPATH' ] && [ -f '$MP/${KPATH#/}' ] && [ ! -L '$MP/${KPATH#/}' ] && [ \$(stat -c %s '$MP/${KPATH#/}') -gt 10485760 ]"
chk "conf fdt 路径指向实体 dtb (${FPATH:-无})"    "[ -n '$FPATH' ] && [ -f '$MP/${FPATH#/}' ] && [ ! -L '$MP/${FPATH#/}' ]"
chk "根兼容层 /Image 是实体文件"                  "[ -f '$MP/Image' ] && [ ! -L '$MP/Image' ]"
chk "根兼容层 /dtb/rockchip/$DTB"                 "[ -f '$MP/dtb/rockchip/$DTB' ] && [ ! -L '$MP/dtb/rockchip/$DTB' ]"

echo "-- 挂载表"
chk "fstab 根挂载用 UUID=$ROOT_UUID"     "grep -qE '^UUID=$ROOT_UUID[[:space:]]+/[[:space:]]' '$MP/etc/fstab'"
chk "fstab 无 /boot/efi 残留"           "! grep -q '/boot/efi' '$MP/etc/fstab'"

# --- IoT 服务栈（仅 INTEGRATE != none 时检查）-----------------------------
if [ "${INTEGRATE:-none}" != "none" ]; then
  echo "-- IoT 服务栈（$IOT_STACK）"
  case ",${IOT_STACK:-}," in
    *",mosquitto,"*)
      chk "mosquitto 可执行"                 "[ -x '$MP/usr/sbin/mosquitto' ] || [ -x '$MP/usr/bin/mosquitto' ]"
      chk "mosquitto 支持 WebSocket"          "grep -aq 'libwebsockets\.so' '$MP/usr/sbin/mosquitto'"
      chk "mosquitto 密码文件 600"            "[ \"\$(stat -c %a '$MP/etc/mosquitto/passwd')\" = 600 ]"
      chk "listener ${IOT_MQTT_PORT:-1883}"   "grep -q 'listener ${IOT_MQTT_PORT:-1883}' '$MP/etc/mosquitto/conf.d/zigbee2mqtt.conf'"
      chk "listener ${IOT_WS_PORT:-8083} ws"  "grep -q 'listener ${IOT_WS_PORT:-8083}' '$MP/etc/mosquitto/conf.d/zigbee2mqtt.conf'"
      chk "mosquitto 开机自启"                "[ -L '$MP/etc/systemd/system/multi-user.target.wants/mosquitto.service' ]"
      ;;
  esac
  case ",${IOT_STACK:-}," in
    *",node-red,"*)
      # 不能测 $MP/usr/local/bin/node 的 -x：它是指向 /usr/local/lib/nodejs/... 的
      # 绝对软链，挂载到 $MP 后解析到的是宿主机路径，必然不存在。要直接测真实文件。
      chk "node 实体存在"                    "ls '$MP'/usr/local/lib/nodejs/*/bin/node >/dev/null 2>&1"
      chk "node-red 实体存在"                "ls '$MP'/usr/local/lib/nodejs/*/bin/node-red >/dev/null 2>&1"
      chk "/usr/local/bin/node 软链"         "[ -L '$MP/usr/local/bin/node' ]"
      chk "/usr/local/bin/node-red 软链"     "[ -L '$MP/usr/local/bin/node-red' ]"
      chk "node-red.service 存在"            "[ -f '$MP/etc/systemd/system/node-red.service' ]"
      chk "node-red 开机自启"                "[ -L '$MP/etc/systemd/system/multi-user.target.wants/node-red.service' ]"
      chk "node-red 非 root 运行"            "grep -qE '^User=nodered' '$MP/etc/systemd/system/node-red.service'"
      ;;
  esac
  case ",${IOT_STACK:-}," in
    *",z2m,"*)
      # 入口是仓库根 index.js，它 require ./dist/controller —— dist/index.js 不存在
      chk "z2m dist/controller.js 已构建"      "[ -f '$MP/opt/zigbee2mqtt/dist/controller.js' ]"
      chk "z2m configuration.yaml"            "[ -f '$MP/opt/zigbee2mqtt/data/configuration.yaml' ]"
      chk "z2m 前端端口 ${IOT_Z2M_PORT:-8080}" "grep -q 'port: ${IOT_Z2M_PORT:-8080}' '$MP/opt/zigbee2mqtt/data/configuration.yaml'"
      chk "z2m 开机自启"                      "[ -L '$MP/etc/systemd/system/multi-user.target.wants/zigbee2mqtt.service' ]"
      ;;
  esac
  chk "/etc/iot-stack.env 已写入"           "[ -f '$MP/etc/iot-stack.env' ]"
  # dnf clean all 会重建目录骨架，判空目录会误报；只关心有没有真包留在里面
  chk "无 dnf 包缓存残留"                   "[ -z \"\$(find '$MP/var/cache/dnf' -name '*.rpm' -print -quit 2>/dev/null)\" ]"
fi

umount "$MP"
echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m全部通过：%d 项\033[0m\n' "$PASS"
else
  printf '\033[1;31m失败 %d 项 / 通过 %d 项\033[0m\n' "$FAIL" "$PASS"
  exit 1
fi
