#!/usr/bin/env bash
# ============================================================================
# firstboot-growfs —— 首次启动把根分区 / 文件系统扩到整盘（Armbian 风格）
#
# 由 /etc/systemd/system/firstboot-growfs.service 在首启调用一次。
# build-image.sh 按「内容 + SLACK_PCT」定尺寸（约 3G），烧到 32G 卡 / 116G eMMC
# 后剩余空间默认全浪费；本服务用 sfdisk 在线扩 GPT 分区项，再 resize2fs 在线扩 fs。
#
# 设计铁律：
#  1. 绝不阻塞启动 —— 任何失败都记日志后恒 exit 0，板子必须照常进系统。
#  2. 幂等 —— 成功后写 /var/lib/firstboot-growfs.done，之后开机直接跳过；
#     「分区表已扩但 resize2fs 失败」不写 marker，下次启动自动重试。
#  3. 保守 —— 只在「GPT + 全盘仅 1 个分区 + 根在 p1」时才动分区表；
#     有多分区 / 非 GPT / 解析不出设备一律跳过，绝不覆盖用户数据。
#  4. PARTUUID 不变 —— cmdline 是 root=PARTUUID=，改了内核会死等 root device。
#
# h96-m9 真机实测（/dev/mmcblk2p1，3.1G → 116.5G）踩过的坑，已固化在下方：
#  - sfdisk -d 字段带对齐空格（start=       32768），正则必须吃空白；
#  - dump 头部 last-lba 是镜像里的旧盘边界，必须删掉让 sfdisk 按实际盘重算；
#  - 该版 sfdisk 不认 size=0，必须显式算扇区 = 总扇区 - 34(GPT 尾部) - start + 1；
#  - 写表用 --force --no-reread，之后 partx -u 通知内核，再 resize2fs 在线扩。
#  - 板上没有 growpart / parted，所以只能用 util-linux 自带的 sfdisk。
#
# 手动调试（不写盘、不扩 fs、不写 marker）：
#   FIRSTBOOT_GROWFS_DRYRUN=1 /usr/sbin/firstboot-growfs
# 查看首启结果：
#   journalctl -u firstboot-growfs --no-pager; cat /var/lib/firstboot-growfs.done
# ============================================================================
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 调试/回归钩子：正常首启由 systemd 调用，什么都不设。显式指定设备/marker 可在
# loop 设备上完整演练扩容链路而不碰真实根盘（见仓库 README「首启自动扩容」）。
MARK="${FIRSTBOOT_GROWFS_MARK:-/var/lib/firstboot-growfs.done}"
BAK="${FIRSTBOOT_GROWFS_BAK:-/var/lib/firstboot-growfs.partition-table.sfdisk}"
# 剩余空间不到 16 MiB 就不值得改分区表（但下面仍会尝试 resize2fs 自愈）
MIN_GAIN_SECTORS=$((16 * 1024 * 1024 / 512))
DRYRUN="${FIRSTBOOT_GROWFS_DRYRUN:-0}"

TMP_D=""; TMP_N=""
cleanup() { [ -n "$TMP_D" ] && rm -f "$TMP_D"; [ -n "$TMP_N" ] && rm -f "$TMP_N"; }
trap cleanup EXIT

log()  { printf '[firstboot-growfs] %s\n' "$*"; }
# 恒 0：这是整个设计里最重要的一条 —— 扩容失败绝不能拖垮 boot。
skip() { log "跳过：$*"; exit 0; }
done_ok() {
  if [ "$DRYRUN" != 1 ]; then
    printf 'date=%s disk=%s part=%s start=%s size=%s->%s\n' \
      "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" "${DISK:-?}" "${ROOT_PART:-?}" \
      "${START:-?}" "${CUR_SIZE:-?}" "${NEW_SIZE:-?}" > "$MARK" 2>/dev/null || true
  fi
  log "完成：$*"
  exit 0
}

command -v sfdisk    >/dev/null 2>&1 || skip "缺 sfdisk（util-linux）"
command -v resize2fs >/dev/null 2>&1 || skip "缺 resize2fs（e2fsprogs）"
if [ -f "$MARK" ] && [ "$DRYRUN" != 1 ]; then skip "已完成（$MARK 存在）"; fi

# --- 1. 定位根分区设备 ------------------------------------------------------
if [ -n "${FIRSTBOOT_GROWFS_DEVICE:-}" ]; then
  ROOT_SRC="$FIRSTBOOT_GROWFS_DEVICE"
  log "调试模式：指定设备 $ROOT_SRC"
else
  ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null | awk 'NR==1{print $1}')
  ROOT_SRC=$(printf '%s' "$ROOT_SRC" | sed 's/\[.*$//')   # 去掉 btrfs 子卷 [@/...]
fi
case "$ROOT_SRC" in
  /dev/*) ROOT_PART=$(readlink -f "$ROOT_SRC" 2>/dev/null || printf '%s' "$ROOT_SRC") ;;
  *)
    # findmnt 有时返回 /dev/root 或 PARTUUID=...，退回 cmdline 定位
    PU=$(sed -nE 's/.*root=PARTUUID=([^ ]+).*/\1/p' /proc/cmdline | awk 'NR==1')
    [ -n "${PU:-}" ] || skip "cmdline 里没有 root=PARTUUID="
    ROOT_PART=$(blkid -t "PARTUUID=$PU" -o device 2>/dev/null | awk 'NR==1{print $1}')
    ;;
esac
[ -n "${ROOT_PART:-}" ] && [ -b "$ROOT_PART" ] || skip "根设备不是块设备（${ROOT_PART:-无}）"

PART_NAME=${ROOT_PART#/dev/}
PKNAME=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null | awk 'NR==1{print $1}')
[ -n "${PKNAME:-}" ] || skip "解析不出父盘（$ROOT_PART）"
DISK="/dev/$PKNAME"
[ -b "$DISK" ] || skip "父盘不存在（$DISK）"
PARTNO=$(cat "/sys/class/block/$PART_NAME/partition" 2>/dev/null | awk 'NR==1')
[ -n "${PARTNO:-}" ] || PARTNO=$(lsblk -no PARTN "$ROOT_PART" 2>/dev/null | awk 'NR==1{print $1}')
[ -n "${PARTNO:-}" ] || skip "解析不出分区号"
[ "$PARTNO" = 1 ] || skip "根不在分区 1（p$PARTNO），保守跳过"

# --- 2. 读分区表 + 保守性检查 ------------------------------------------------
TMP_D=$(mktemp /dev/shm/fbg-dump.XXXXXX 2>/dev/null) || TMP_D=$(mktemp)
sfdisk -d "$DISK" > "$TMP_D" 2>/dev/null || skip "sfdisk -d 读取失败（$DISK）"
grep -q '^label: *gpt' "$TMP_D" || skip "不是 GPT 分区表，保守跳过"
NPART=$(grep -c '^/dev/' "$TMP_D")
[ "${NPART:-0}" -eq 1 ] || skip "盘上有 ${NPART:-?} 个分区（预期 1），保守跳过以免覆盖用户数据"
# 只有一行，直接取它 —— 避免 mmcblkNp1 / sdaN / nvme0n1pN 命名差异带来的拼串错误
LINE=$(grep '^/dev/' "$TMP_D" | head -1)
LINE_DEV=$(printf '%s' "$LINE" | sed -nE 's@^([^[:space:]]+)[[:space:]]*:.*@\1@p' | head -1)
[ -n "$LINE_DEV" ] || skip "分区表行解析失败"

f() { printf '%s' "$LINE" | sed -nE "s/.*[,[:space:]]$1=[[:space:]]*([^,[:space:]]+).*/\1/p" | head -1; }
START=$(f start)
CUR_SIZE=$(f size)
TYPE=$(f type)
UUID=$(f uuid)
NAME=$(printf '%s' "$LINE" | sed -nE 's/.*name="([^"]*)".*/\1/p' | head -1)
case "$START"    in ''|*[!0-9]*) skip "解析 start 失败" ;; esac
case "$CUR_SIZE" in ''|*[!0-9]*) skip "解析 size 失败" ;; esac
[ -n "$TYPE" ] || skip "解析 type 失败"
# uuid 就是分区 GUID（root=PARTUUID= 指向它），拿不到绝不能改表
[ -n "$UUID" ] || skip "解析 uuid 失败，不敢冒险改动 PARTUUID"

TOTAL=$(cat "/sys/class/block/$PKNAME/size" 2>/dev/null | awk 'NR==1')
case "$TOTAL" in ''|*[!0-9]*) skip "读不到磁盘总扇区" ;; esac
LAST_USABLE=$((TOTAL - 34))                       # GPT 尾部备份表占 34 扇区
NEW_SIZE=$((LAST_USABLE - START + 1))
[ "$NEW_SIZE" -gt 0 ] || skip "计算出的分区大小非法（$NEW_SIZE）"
GAIN=$((NEW_SIZE - CUR_SIZE))
log "设备 $ROOT_PART（父盘 $DISK）：分区 $CUR_SIZE 扇区 / 盘 $TOTAL 扇区，可扩 $GAIN 扇区"

# --- 3. 需要时改 GPT 分区项（PARTUUID / start 原样保留）----------------------
if [ "$GAIN" -ge "$MIN_GAIN_SECTORS" ]; then
  TMP_N=$(mktemp /dev/shm/fbg-new.XXXXXX 2>/dev/null) || TMP_N=$(mktemp)
  # 头部非分区行原样保留；last-lba 必须删 —— 它是镜像里的旧盘边界，
  # 留着 sfdisk 会按旧的 3.1G 盘重算，导致新 size 被截断。
  grep -v '^/dev/' "$TMP_D" | grep -v '^last-lba:' > "$TMP_N"
  if [ -n "$NAME" ]; then
    printf '%s : start=%s, size=%s, type=%s, uuid=%s, name="%s"\n' \
      "$LINE_DEV" "$START" "$NEW_SIZE" "$TYPE" "$UUID" "$NAME" >> "$TMP_N"
  else
    printf '%s : start=%s, size=%s, type=%s, uuid=%s\n' \
      "$LINE_DEV" "$START" "$NEW_SIZE" "$TYPE" "$UUID" >> "$TMP_N"
  fi
  log "扩分区项：$CUR_SIZE → $NEW_SIZE 扇区（start=$START、PARTUUID=$UUID 均不变）"
  if [ "$DRYRUN" = 1 ]; then
    log "DRYRUN 新分区表预览："
    sed 's/^/    /' "$TMP_N"
    log "DRYRUN：不写盘、不扩文件系统、不写 marker"
    exit 0
  fi
  cp "$TMP_D" "$BAK" 2>/dev/null || true        # 留一份原表，出事可人工回滚
  if ! sfdisk --force --no-reread "$DISK" < "$TMP_N" >/dev/null 2>&1; then
    log "写分区表失败（原表备份 ${BAK}），跳过"; exit 0
  fi
  partx -u "$DISK" >/dev/null 2>&1 || true
  partprobe "$DISK" >/dev/null 2>&1 || true
  KER_SIZE=$(cat "/sys/class/block/$PART_NAME/size" 2>/dev/null | awk 'NR==1')
  if [ "${KER_SIZE:-0}" -lt "$((NEW_SIZE - 2048))" ]; then
    log "内核仍看到旧分区大小（${KER_SIZE:-0}），再试一次 rescan"
    echo 1 > "/sys/class/block/$PKNAME/device/rescan" 2>/dev/null || true
    partx -u "$DISK" >/dev/null 2>&1 || true
  fi
else
  if [ "$GAIN" -gt 0 ]; then
    log "剩余 $GAIN 扇区 < 阈值 $MIN_GAIN_SECTORS，不改分区表"
  else
    log "分区已吃满整盘，无需改分区表"
  fi
  [ "$DRYRUN" = 1 ] && { log "DRYRUN：不做任何写操作"; exit 0; }
fi

# --- 4. 在线扩文件系统（总是跑，幂等且能自愈「表已扩 fs 未扩」）-------------
if resize2fs "$ROOT_PART" >/dev/null 2>&1; then
  done_ok "根文件系统已扩到 $(df -h / 2>/dev/null | awk 'NR==2{print $2}')"
else
  log "resize2fs 失败：分区表可能已扩，下次启动会自动重试（不写 marker）"
  exit 0
fi
