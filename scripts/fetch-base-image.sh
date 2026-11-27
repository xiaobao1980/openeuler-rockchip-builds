#!/usr/bin/env bash
# 下载 openEuler aarch64 基础镜像，供 build-image.sh 取 rootfs。
#
# 来源优先级（方案 C）：
#   1) GitHub Release（本仓库 base-images tag）—— CI 内部传输，绕开 openEuler CDN，
#      740 MiB 只上传一次，matrix 并行构建时 N 块板共享同一份资产。
#   2) 官方镜像站按序回退（dl-cdn → repo → 华为云 → 清华 → 中科大）——
#      Release 不存在/校验失败时的兜底，也用于首次发布。
#
# 用法:
#   bash scripts/fetch-base-image.sh <OE_VER> [输出目录=in]
#   环境变量:
#     FORCE_OFFICIAL=1  跳过 Release 直走官方源（发布工作流用，避免自举循环）
#     BASE_IMAGE_TAG    覆盖 Release tag（默认 base-images）
#     BASE_IMAGE_REPO   覆盖仓库（默认 $GITHUB_REPOSITORY）
#
# 输出:
#   stdout 只打印镜像相对路径（如 in/openEuler-24.03-LTS-SP4-aarch64.qcow2.xz），
#   全部日志走 stderr，便于调用方直接 `OE_XZ=$(bash scripts/fetch-base-image.sh ...)`。
#
# 校验策略:
#   - 已知版本内置官方权威 SHA256（硬校验，防 Release 资产损坏/被替换）
#   - 同时校验随附 .sha256sum（若存在）
#   - 未知版本仅校验 .sha256sum；两者都没有则告警放行（兼容旧资产）
set -euo pipefail

OE_VER="${1:?用法: $0 <OE_VER> [输出目录]}"
OUT_DIR="${2:-in}"

F="openEuler-${OE_VER}-aarch64.qcow2.xz"
SUBDIR="openEuler-${OE_VER}/virtual_machine_img/aarch64"
BASE_TAG="${BASE_IMAGE_TAG:-base-images}"
REPO="${BASE_IMAGE_REPO:-${GITHUB_REPOSITORY:-xiaobao1980/openeuler-rockchip-builds}}"
OUT="$OUT_DIR/$F"

# 已验证版本的官方 SHA256（取自 virtual_machine_img 目录的 .sha256sum）
case "$OE_VER" in
  24.03-LTS-SP4) EXPECT_SHA="890857eb1472a5424022604607df459c4d3779ee17f2c4153800e8d2f035bb87" ;;
  *)             EXPECT_SHA="" ;;
esac

log() { printf '[base-image] %s\n' "$*" >&2; }
warn() { printf '::warning::[base-image] %s\n' "$*" >&2; }
err()  { printf '::error::[base-image] %s\n' "$*" >&2; }

mkdir -p "$OUT_DIR"

# verify <实际sha256>  —— 成功返回 0
verify() {
  local got="$1"
  if [ -n "$EXPECT_SHA" ] && [ "$got" != "$EXPECT_SHA" ]; then
    err "SHA256 不匹配：实际 ${got}，期望 ${EXPECT_SHA}"
    return 1
  fi
  if [ -s "$OUT.sha256sum" ]; then
    # 关键：sha256sum -c 的 "<file>: OK" 必须走 stderr。
    # 否则会被调用方的 IMAGE=$(bash fetch-base-image.sh ...) 一起捕获，
    # 使变量变成两行 → $GITHUB_OUTPUT 写多行 → "Invalid format"、
    # 后续 sha256sum "$IMAGE" 找不到文件。stdout 契约只允许最后一行路径。
    if ! ( cd "$OUT_DIR" && sha256sum -c "$F.sha256sum" >&2 ); then
      err "随附 .sha256sum 校验失败"
      return 1
    fi
  elif [ -z "$EXPECT_SHA" ]; then
    warn "无内置 SHA256、也无随附 .sha256sum，本次跳过校验"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 1) GitHub Release 优先
# ---------------------------------------------------------------------------
FROM_RELEASE=0
if [ "${FORCE_OFFICIAL:-0}" != "1" ] \
   && [ -n "${GH_TOKEN:-}" ] \
   && command -v gh >/dev/null 2>&1; then
  if gh release view "$BASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    rm -f "$OUT" "$OUT.sha256sum"
    if gh release download "$BASE_TAG" --repo "$REPO" \
         --pattern "$F*" --dir "$OUT_DIR" >/dev/null 2>&1 && [ -s "$OUT" ]; then
      GOT="$(sha256sum "$OUT" | awk '{print $1}')"
      if verify "$GOT"; then
        log "来源: GitHub Release ${BASE_TAG}（sha256=${GOT}）"
        FROM_RELEASE=1
      else
        warn "Release 资产校验失败，回退官方镜像源"
      fi
    else
      warn "Release ${BASE_TAG} 无可用资产 ${F}，回退官方镜像源"
    fi
  else
    log "Release $BASE_TAG 不存在，回退官方镜像源"
  fi
else
  log "按 FORCE_OFFICIAL=1 跳过 Release，直走官方镜像源"
fi

# ---------------------------------------------------------------------------
# 2) 官方镜像站按序回退
# ---------------------------------------------------------------------------
if [ "$FROM_RELEASE" != "1" ]; then
  OK_BASE=""
  for BASE in \
    "https://dl-cdn.openeuler.openatom.cn" \
    "https://repo.openeuler.openatom.cn" \
    "https://mirrors.huaweicloud.com/openeuler" \
    "https://mirrors.tuna.tsinghua.edu.cn/openeuler" \
    "https://mirrors.ustc.edu.cn/openeuler"; do
    URL="$BASE/$SUBDIR/$F"
    log "尝试下载: $URL"
    rm -f "$OUT"
    if curl -fL --retry 3 --retry-delay 5 -o "$OUT" "$URL"; then
      OK_BASE="$BASE"
      log "下载成功: $URL"
      break
    fi
    warn "镜像不可用: $BASE"
  done

  [ -s "$OUT" ] || { err "所有镜像均下载失败"; exit 1; }

  # 校验文件从成功的同一个源取（主源 403 时旧写法会静默跳过校验）
  rm -f "$OUT.sha256sum"
  curl -fsSL --retry 3 --retry-delay 5 -o "$OUT.sha256sum" "$OK_BASE/$SUBDIR/$F.sha256sum" || true
  GOT="$(sha256sum "$OUT" | awk '{print $1}')"
  verify "$GOT" || { err "校验失败，拒绝使用损坏镜像"; exit 1; }
  log "来源: ${OK_BASE}（sha256=${GOT}）"
fi

ls -lh "$OUT" >&2
printf '%s\n' "$OUT"
