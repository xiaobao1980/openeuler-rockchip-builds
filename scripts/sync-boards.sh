#!/usr/bin/env bash
# ============================================================================
# 从上游 armbian/build 同步 RK35xx 全系板卡清单 → boards/boards.tsv
#
# 上游是唯一定义源：https://github.com/armbian/build/tree/main/config/boards
#   BOARDFAMILY="rk35xx"          → rk3528 / rk3566 / rk3568 / rk3576
#   BOARDFAMILY="rockchip-rk3588" → rk3588
#
# 设计取舍：不生成「一板一个 conf 目录」，只生成一张 TSV。
#   109 块板 × 一个 conf 目录 = 109 份几乎相同的文件，改一个默认值要改 109 处。
#   改为：TSV 存「真的跟板子走」的 4 个值（id / model / soc / dtb），
#   其余参数由 boards/_template/board.conf 按规则推导（见 board-resolve.sh）。
#   需要给某块板特调（CMA、UUID、串口）时，手写 boards/<id>/board.conf 覆盖即可，
#   同步脚本永不覆盖手写配置。
#
# 用法：
#   ./sync-boards.sh                     # 拉上游 main
#   ./sync-boards.sh --local /tmp/ab-up  # 复用已有 clone
#   ./sync-boards.sh --families rk35xx   # 只要 3528/3566/3568/3576
# ============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

SRC_URL="https://github.com/armbian/build"
SRC_REF="main"
FAMILIES="rk35xx,rockchip-rk3588"
LOCAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source)   SRC_URL="$2"; shift 2 ;;
    --ref)      SRC_REF="$2"; shift 2 ;;
    --families) FAMILIES="$2"; shift 2 ;;
    --local)    LOCAL="$2"; shift 2 ;;
    *) echo "未知参数 $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

TMP=""
trap '[ -n "$TMP" ] && rm -rf "$TMP" || true' EXIT

if [ -n "$LOCAL" ]; then
  BOARDS_SRC="$LOCAL/config/boards"
  [ -d "$BOARDS_SRC" ] || die "$LOCAL 里没有 config/boards"
  SRC_COMMIT="local"
  log "使用本地源：$LOCAL"
else
  command -v git >/dev/null || die "需要 git"
  TMP=$(mktemp -d)
  log "稀疏克隆 $SRC_URL@$SRC_REF（只取 config/boards）"
  git clone --depth 1 --branch "$SRC_REF" --filter=blob:none --sparse \
      "$SRC_URL" "$TMP/ab" >/dev/null 2>&1 || die "clone 失败"
  git -C "$TMP/ab" sparse-checkout set config/boards >/dev/null 2>&1
  BOARDS_SRC="$TMP/ab/config/boards"
  SRC_COMMIT=$(git -C "$TMP/ab" rev-parse --short HEAD)
  log "上游 commit: $SRC_COMMIT"
fi
[ -d "$BOARDS_SRC" ] || die "找不到 $BOARDS_SRC"

# --- 单次 awk 解析全部板卡文件（不逐文件 spawn，避免上百次进程开销）-------
# 注意：不用 gawk 的 ENDFILE（BSD awk / mawk 都不支持），改用 FNR==1 时冲刷上一个文件
TSV="$ROOT/boards/boards.tsv"
mkdir -p "$ROOT/boards"

awk -F'"' -v fams="$FAMILIES" '
  function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
  function flush(   id,dtb,soc,n,i,ok){
    if (family=="") return
    n=split(fams, want, ",")
    ok=0; for(i=1;i<=n;i++) if (want[i]==family) ok=1
    if(!ok) return
    id=curfile; sub(/.*\//,"",id); sub(/\.(conf|csc|tvb|wip)$/,"",id)
    if(id=="_template") return
    dtb=fdt; sub(/^rockchip\//,"",dtb)
    soc=""; if (match(dtb,/^rk3[0-9][0-9][0-9]s?/)) soc=substr(dtb,1,RLENGTH)
    status = (dtb=="" ? "NO_DTB" : (soc=="" ? "SOC_UNKNOWN" : "OK"))
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, (bname==""?id:bname), (soc==""?"?":soc), dtb, family, status
  }
  FNR==1 { if (NR>1) flush(); family=""; bname=""; fdt=""; curfile=FILENAME }
  /^BOARDFAMILY=/   { family=trim($2) }
  /^BOARD_NAME=/    { bname=trim($2) }
  /^BOOT_FDT_FILE=/ { fdt=trim($2) }
  END { flush() }
' "$BOARDS_SRC"/*.conf "$BOARDS_SRC"/*.csc "$BOARDS_SRC"/*.tvb "$BOARDS_SRC"/*.wip 2>/dev/null \
  | awk -F'\t' '!seen[$1]++' \
  | sort -t$'\t' -k3,3 -k1,1 > "$TSV.tmp"

{
  printf '# 由 scripts/sync-boards.sh 从 %s 生成，勿手改\n' "$SRC_URL/config/boards@$SRC_REF"
  printf '# 上游 commit: %s   生成时间: %s\n' "${SRC_COMMIT:-?}" "$(date -u +%FT%TZ)"
  printf '#\n# 字段: board_id \\t model \\t soc \\t dtb \\t family \\t status\n'
  printf '# status=OK 可直接构建；NO_DTB 上游用 fdtdir 自动匹配，需手工确认 DTB 名；\n'
  printf '# SOC_UNKNOWN 的 dtb 命名不符合 rk3xxx-*.dtb 规则，需手工确认\n'
  printf 'board\tmodel\tsoc\tdtb\tfamily\tstatus\n'
  cat "$TSV.tmp"
} > "$TSV"
rm -f "$TSV.tmp"

TOTAL=$(awk -F'\t' '$1!="board" && $1!~/^#/' "$TSV" | wc -l | tr -d ' ')
OK=$(awk -F'\t' '$6=="OK"' "$TSV" | wc -l | tr -d ' ')
BAD=$((TOTAL - OK))
log "同步完成：${TOTAL} 块板（可构建 ${OK}，需确认 ${BAD}）"
awk -F'\t' 'NR>1 && $6=="OK"{c[$3]++} END{for(s in c) printf "  %-8s %d 块\n", s, c[s]}' "$TSV" | sort
log "清单：boards/boards.tsv"
