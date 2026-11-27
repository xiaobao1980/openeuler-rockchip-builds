#!/usr/bin/env bash
# ============================================================================
# 在 chroot 内执行：根治 openEuler dnf 源元数据故障
#
# 背景（2026-11-27 CI 第三次网络故障）：
#   dnf 报 "checksum doesn't match"，4 个 calculated sha512 完全相同、expected
#   各不相同 —— 说明 dnf 缓存/中间代理把多个 repodata 文件返回成了同一份内容，
#   再叠加 baseurl 多镜像逐个校验必然全挂；而 curl 直连同一 URL 在同一时刻正常。
#   单纯 dnf --retry 无效（重试拿到的还是同一份中毒缓存）。
#
# 做法（幂等，可反复调用）：
#   1) 清 dnf 缓存 + 删下载缓存目录     —— 直接针对 calculated 全相同的中毒症状
#   2) 旧 repo 备份到 .orig-bak + 改后缀禁用（保留可人工恢复）
#   3) 写单一可信源的固定 baseurl       —— 消除多镜像 hash 不一致
#   4) dnf makecache 验证；主源失败自动切备源；两源都失败才退出 1
#
# 由 scripts/lib-dnf-repair.sh 复制进 rootfs 后在 chroot 内运行，勿在宿主机直接跑。
# 需要 root；不需要网络之外的任何外部文件。
# ============================================================================
set -uo pipefail

log()  { printf '\n\033[1;35m[DNF-REPAIR] %s\033[0m\n' "$*"; }
info() { printf '             %s\n' "$*"; }
warn() { printf '\033[1;33m[DNF-REPAIR-WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[DNF-REPAIR-ERR] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 目录定义（版本探测需要读原始 repo）----
REPO_DIR=/etc/yum.repos.d
BAK_DIR="$REPO_DIR/.orig-bak"
FIXED="$REPO_DIR/000-openeuler-fixed.repo"

# ---- 版本/架构：从 rootfs 自身读取，不靠调用方传参 ----
# 坑（2026-11-27 CI 实证）：openEuler 的 VERSION_ID 只有 "24.03"，而源站目录名是
# "openEuler-24.03-LTS-SP4" —— SP 后缀藏在同一行的 PRETTY_NAME 括号里：
#   VERSION_ID="24.03" PRETTY_NAME="openEuler 24.03 (LTS-SP4)"
# 直接用 VERSION_ID 会拼出 openEuler-24.03/... → 华为云/官方站双 404。
# 优先 VERSION_ID + 括号 SP 字段拼装；缺失括号时回退从原始 repo 的 baseurl 提取。
BASE_VER="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")"
SP="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION:-${PRETTY_NAME:-}}" | sed -n 's/.*(\([^)]*\)).*/\1/p')"
if [ -n "$BASE_VER" ] && [ -n "$SP" ]; then
  VER="$BASE_VER-$SP"
  VER_SRC="os-release(VERSION_ID + SP)"
else
  VER="$(grep -hoE 'openEuler-[0-9]+\.[0-9]+(-[A-Za-z0-9]+)*' "$REPO_DIR"/*.repo 2>/dev/null | sed 's/^openEuler-//' | sort -r | head -1)"
  VER_SRC="原始 repo baseurl"
fi
[ -n "$VER" ] || die "无法探测 openEuler 版本号（VERSION_ID=${BASE_VER:-空}，repo 也无版本串）"
ARCH="$(uname -m)"
[ "$ARCH" = aarch64 ] || die "非 aarch64 chroot（ARCH=${ARCH}），源路径按 aarch64 拼装"
log "目标系统: openEuler $VER / $ARCH"
info "版本来源: $VER_SRC"

# GPG key 存在就保持校验，缺失则降级为不校验（避免引入新的失败点）
GPG_KEY="$(ls /etc/pki/rpm-gpg/RPM-GPG-KEY-openEuler* 2>/dev/null | head -1 || true)"
if [ -n "$GPG_KEY" ]; then
  GPG_LINES="gpgcheck=1
gpgkey=file://$GPG_KEY"
  info "GPG 校验: 启用（${GPG_KEY}）"
else
  GPG_LINES="gpgcheck=0"
  warn "未找到 openEuler GPG key，本构建期源 gpgcheck=0"
fi

# ---- 1. 清缓存（关键步骤：针对 calculated hash 全相同的缓存中毒）----
log "清空 dnf 缓存"
dnf clean all >/dev/null 2>&1 || true
rm -rf /var/cache/dnf /var/cache/yum /var/tmp/dnf-* 2>/dev/null || true
info "缓存已清空"

# ---- 2. 备份并禁用旧 repo（只备份一次；.disabled 保留可人工恢复）----
mkdir -p "$BAK_DIR"
shopt -s nullglob
need_backup=0
for f in "$REPO_DIR"/*.repo; do
  [ "$(basename "$f")" = "$(basename "$FIXED")" ] && continue
  if [ ! -e "$BAK_DIR/$(basename "$f")" ]; then
    cp -a "$f" "$BAK_DIR/" && need_backup=1
  fi
done
for f in "$REPO_DIR"/*.repo; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "$(basename "$FIXED")" ] && continue
  mv -f "$f" "$f.disabled" 2>/dev/null || true
done
shopt -u nullglob
[ "$need_backup" = 1 ] && info "旧 repo 已备份到 ${BAK_DIR}（原文件名.disabled）"

# ---- 3. 写单源 repo（主源华为云；失败回退官方站，均为固定 baseurl、无 metalink）----
write_repo() {
  local root="$1"
  cat > "$FIXED" <<EOF
# 构建链自动生成（scripts/lib-dnf-repair.sh）：清缓存 + 固定单源，绕开
# metalink/多镜像 repomd.xml checksum 不匹配。原始 repo 备份在 .orig-bak/
[OE-OS]
name=openEuler $VER - OS
baseurl=$root/openEuler-$VER/OS/$ARCH/
enabled=1
$GPG_LINES

[OE-update]
name=openEuler $VER - Update
baseurl=$root/openEuler-$VER/update/$ARCH/
enabled=1
$GPG_LINES

[OE-everything]
name=openEuler $VER - Everything
baseurl=$root/openEuler-$VER/everything/$ARCH/
enabled=1
$GPG_LINES

[OE-EPOL]
name=openEuler $VER - EPOL
baseurl=$root/openEuler-$VER/EPOL/main/$ARCH/
enabled=1
$GPG_LINES

[OE-source]
name=openEuler $VER - Source
baseurl=$root/openEuler-$VER/source/
enabled=1
$GPG_LINES
EOF
}

verify_repo() {
  local tag="$1"
  dnf -y --setopt=timeout=30 --setopt=retries=1 makecache --refresh \
    >"/tmp/dnf-repair-makecache-$tag.log" 2>&1
}

log "配置主源: 华为云"
write_repo "https://mirrors.huaweicloud.com/openeuler"
if verify_repo huaweicloud; then
  info "主源 makecache 成功"
else
  warn "主源 makecache 失败，切换官方站单源"
  tail -12 /tmp/dnf-repair-makecache-huaweicloud.log >&2 || true
  write_repo "https://repo.openeuler.openatom.cn"
  if verify_repo official; then
    info "备源 makecache 成功"
  else
    tail -12 /tmp/dnf-repair-makecache-official.log >&2 || true
    die "华为云与官方单源均无法通过 makecache，dnf 元数据不可用（查 /tmp/dnf-repair-makecache-*.log）"
  fi
fi

dnf clean all >/dev/null 2>&1 || true
log "dnf 源修复完成：单源 + 缓存清空，可继续 dnf install"
