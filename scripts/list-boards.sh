#!/usr/bin/env bash
# ============================================================================
# 可构建板卡清单 —— boards/boards.tsv（上游同步）与 boards/<id>/board.conf（手写）
# 的合并视图，供 CI 生成构建矩阵。
#
# 为什么需要这一层：
#   boards.tsv 只包含 armbian/build 上游收录的板。自定义板（如 h96-m9）根本不在
#   上游，只存在于 boards/h96-m9/board.conf。若矩阵只读 TSV，选 h96-m9 会得到
#   0 块板然后直接失败。
#
# 输出（TSV，无表头）：board_id <TAB> model <TAB> soc <TAB> dtb <TAB> source
#   source = hand（boards/<id>/board.conf）| auto（boards.tsv 推导）
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TSV="$ROOT/boards/boards.tsv"

die() { printf '\033[1;31mlist-boards: %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$ROOT/boards" ] || die "找不到 $ROOT/boards"

# --- 1. 手写板卡优先 ------------------------------------------------------
# 不手工解析 board.conf：里面全是 shell 赋值 + 行尾注释，交给 board-resolve.sh
# 展开一次最准，也能拿到 # AUTO-GENERATED 之外的真实 DTB / FAMILY
HAND=""
for d in "$ROOT"/boards/*/; do
  [ -d "$d" ] || continue
  id=$(basename "$d")
  [ "$id" = "_template" ] && continue
  [ -f "$d/board.conf" ] || continue

  _cf=$(mktemp)
  if ! bash "$HERE/board-resolve.sh" "$id" > "$_cf" 2>/dev/null; then
    rm -f "$_cf"
    printf '\033[1;33mlist-boards: 跳过 %s（board.conf 解析失败）\033[0m\n' "$id" >&2
    continue
  fi
  # 子 shell 里 source：避免 BOARD_ID/DTB 之类的变量污染循环
  ( set +u; . "$_cf"
    printf '%s\t%s\t%s\t%s\thand\n' "$BOARD_ID" "$MODEL" "$FAMILY" "$DTB" )
  rm -f "$_cf"
  HAND="$HAND $id"
done

# --- 2. 上游同步清单，排除已被手写覆盖的 ----------------------------------
if [ -f "$TSV" ]; then
  awk -F'\t' -v hand="$HAND" '
    BEGIN { n = split(hand, h, " "); for (i = 1; i <= n; i++) if (h[i] != "") H[h[i]] = 1 }
    $1 == "board" || $1 ~ /^#/ { next }
    $6 != "OK"                 { next }
    ($1 in H)                  { next }
    { printf "%s\t%s\t%s\t%s\tauto\n", $1, $2, $3, $4 }
  ' "$TSV"
fi
