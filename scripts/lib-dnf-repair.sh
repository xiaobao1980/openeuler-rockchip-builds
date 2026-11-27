#!/usr/bin/env bash
# ============================================================================
# 公共库：dnf 源修复（清缓存 + 固定单源），供 integrate-desktop.sh / integrate-mesa.sh
# 在首次 dnf install 之前 source。integrate-iot.sh 按用户要求不接入。
#
# 依赖调用方（source 前须已定义）：
#   R      —— rootfs 绝对路径
#   cr()   —— 在 chroot 内执行命令的封装
#   log/info/warn/die —— 日志函数
#
# 实现放在 scripts/dnf-repair-in-chroot.sh：由本库复制进 rootfs 后在 chroot 内跑，
# 避免多行脚本塞进 cr "bash -c ..." 引发引号问题。
# ============================================================================

_DNF_REPAIR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dnf_repair_sources() {
  local helper="$_DNF_REPAIR_DIR/dnf-repair-in-chroot.sh"
  [ -f "$helper" ] || { printf '[DNF-REPAIR] 缺少 %s\n' "$helper" >&2; return 1; }

  cp -f "$helper" "$R/tmp/dnf-repair-in-chroot.sh" || {
    printf '[DNF-REPAIR] 复制修复脚本进 rootfs 失败\n' >&2; return 1;
  }
  chmod 755 "$R/tmp/dnf-repair-in-chroot.sh"

  log "修复 dnf 源（清缓存 + 固定单源，根治 repomd checksum 不匹配）"
  if cr "bash /tmp/dnf-repair-in-chroot.sh"; then
    log "dnf 源修复完成"
    return 0
  fi
  warn "dnf 源修复失败（详见上方 [DNF-REPAIR-ERR]）"
  return 1
}
