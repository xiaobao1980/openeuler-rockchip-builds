#!/usr/bin/env bash
# ============================================================================
# 板级配置解析器 —— 把 board id 解析成一份完整可 source 的配置
#
# 优先级：
#   1. boards/<id>/board.conf      手写，永不覆盖（特调 CMA/UUID/串口 就放这里）
#   2. boards/boards.tsv + boards/_template/board.conf   上游同步而来的通用推导
#
# 用法：
#   bash board-resolve.sh h96-m9          # 打印到 stdout
#   . <(bash board-resolve.sh h96-m9)     # 在脚本里直接 source
#   ./board-resolve.sh --list             # 列出全部可构建板卡
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TSV="$ROOT/boards/boards.tsv"
TPL="$ROOT/boards/_template/board.conf"

die() { printf '\033[1;31mboard-resolve: %s\033[0m\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
  [ -f "$TSV" ] || die "缺 boards/boards.tsv，先跑 scripts/sync-boards.sh"
  echo "手写配置（boards/<id>/board.conf）："
  for d in "$ROOT"/boards/*/; do
    [ -f "$d/board.conf" ] && printf '  %-28s %s\n' "$(basename "$d")" "(hand-written)"
  done
  echo
  echo "同步清单（boards/boards.tsv，$(($(grep -vc '^#' "$TSV") - 1)) 块）："
  awk -F'\t' 'NR>1{printf "  %-28s %-10s %-6s %s\n", $1, $2, $3, $6}' "$TSV"
  exit 0
fi

BOARD="${1:-${BOARD:-h96-m9}}"

# --- 1. 手写优先 ----------------------------------------------------------
if [ -f "$ROOT/boards/$BOARD/board.conf" ]; then
  cat "$ROOT/boards/$BOARD/board.conf"
  exit 0
fi

# --- 2. 从同步清单推导 ----------------------------------------------------
[ -f "$TSV" ] || die "找不到 boards/$BOARD/board.conf，也没有 boards/boards.tsv（先跑 sync-boards.sh）"
ROW=$(awk -F'\t' -v b="$BOARD" '$1==b{print;exit}' "$TSV")
[ -n "$ROW" ] || die "未知板卡 '$BOARD'。用 $0 --list 查看可构建清单"

IFS=$'\t' read -r id model soc dtb family status <<< "$ROW"
case "$status" in
  OK) ;;
  NO_DTB)     die "$id 上游未定义 BOOT_FDT_FILE（靠 fdtdir 自动匹配）。请建 boards/$id/board.conf 手写 DTB=" ;;
  SOC_UNKNOWN) die "$id 的 dtb 名 '$dtb' 不符合 rk3xxx-* 规则，请建 boards/$id/board.conf 手写 FAMILY/DTB" ;;
  *) die "$id 状态异常：$status" ;;
esac

# rootfs UUID 由 board id 确定性推导：同一块板每次构建同一个 UUID，产物可复现
_sum() {
  if command -v md5sum >/dev/null 2>&1; then printf '%s' "$1" | md5sum | cut -c1-32
  else printf '%s' "$1" | md5 -q | cut -c1-32; fi
}
H=$(_sum "openeuler-rk35xx/$id")
ROOT_UUID="${H:0:8}-${H:8:4}-4${H:13:3}-a${H:17:3}-${H:20:12}"

# CMA 按 SoC 给经验值：小内存 SoC 给多了会挤压系统
case "$soc" in
  rk3528|rk3566|rk3568) CMA=128M ;;
  rk3576)               CMA=256M ;;
  rk3588)               CMA=512M ;;
  *)                    CMA=256M ;;
esac

sed -e "s|^BOARD_ID=.*|BOARD_ID=$id|" \
    -e "s|^MODEL=.*|MODEL=\"$model\"|" \
    -e "s|^FAMILY=[^ ]*|FAMILY=$soc|" \
    -e "s|^DTB=[^ ]*|DTB=$dtb|" \
    -e "s|^ROOT_UUID=[^ ]*|ROOT_UUID=$ROOT_UUID|" \
    -e "s|^CMA=[^ ]*|CMA=$CMA|" \
    -e "s|^# AUTO-GENERATED.*|# AUTO-GENERATED from boards/boards.tsv (soc=$soc, family=$family)|" \
    "$TPL"
