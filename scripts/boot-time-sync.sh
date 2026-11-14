#!/usr/bin/env bash
# ============================================================================
# boot-time-sync —— 无 RTC 板每次开机校时（chronyd -> timesyncd -> HTTP Date）
#
# 背景：RK35xx 板普遍无 RTC 或 RTC 掉电，重启后系统钟归 1970-01-01。
# 钟错一年以上时，所有 HTTPS（dnf 下载、git clone、API 调用）都会报
# "certificate is not yet valid"，和当年 h96-m9 板端构建翻车是同一个坑。
#
# 由 boot-time-sync.service 在【每次开机】调用（非 firstboot 一次性）：
#   1. chronyd 存在     -> enable --now + waitsync + makestep（标准路径）
#   2. timesyncd 存在   -> restart 后轮询等待
#   3. HTTP Date 兜底   -> 多个国内源取 Date 头 date -s（纯 HTTP，无证书问题）
#
# 设计铁律（与 firstboot-growfs 一致）：
#  1. 绝不阻塞启动 —— 任何失败都记日志后恒 exit 0；
#  2. 每次开机都跑 —— 校时成功无副作用，重复执行幂等；
#  3. 纯用户态 —— 不依赖内核 RTC 驱动，不碰硬件。
#
# 手动调试：
#   /usr/sbin/boot-time-sync
# 查看结果：
#   journalctl -u boot-time-sync --no-pager; date
# 跳过本服务（特殊环境）：
#   touch /var/lib/boot-time-sync.skip
# ============================================================================
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

log(){ printf '[boot-time-sync] %s\n' "$*"; }

# 判定"时钟正常"：不猜具体日期，只要 >= 2025 就视为已校准（本镜像 2026 起构建）
sane(){ [ "$(date -u +%Y 2>/dev/null || echo 0)" -ge 2025 ]; }

year=$(date -u +%Y 2>/dev/null || echo 1970)
case "$year" in ''|*[!0-9]*) year=1970 ;; esac
if [ "$year" -lt 2025 ]; then
  log "时钟异常（${year} 年，疑似无 RTC 掉电归零），开始强制校时"
else
  log "时钟基本正常（${year} 年），按每次开机策略继续校时"
fi

# --- 1. chronyd：标准路径 ----------------------------------------------------
if command -v chronyc >/dev/null 2>&1; then
  systemctl enable --now chronyd >/dev/null 2>&1 || true
  if chronyc waitsync 15 0.1 >/dev/null 2>&1; then
    chronyc makestep >/dev/null 2>&1 || true
  fi
  if sane; then
    log "chronyd 校时完成：$(date '+%F %T' 2>/dev/null)"
    exit 0
  fi
  log "chronyd 未能校时（无 NTP 网络？），尝试兜底方案"
else
  log "无 chronyc，尝试兜底方案"
fi

# --- 2. systemd-timesyncd 兜底 ------------------------------------------------
if systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
  systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 2
    if sane; then log "timesyncd 校时完成：$(date '+%F %T')"; exit 0; fi
  done
  log "timesyncd 未能校时，尝试 HTTP 兜底"
fi

# --- 3. HTTP Date 兜底（1970 年也能用：HTTP 无 TLS 证书校验）-------------------
if ! sane; then
  for url in http://mirrors.aliyun.com/ http://www.baidu.com/ http://www.qq.com/; do
    D=$(curl -4 -s -I --max-time 6 "$url" 2>/dev/null | tr -d '\r' \
        | sed -n 's/^[Dd]ate:[[:space:]]*//p' | head -1)
    [ -n "$D" ] || continue
    # GNU date 能直接吃 RFC1123；个别精简环境不行，再用 python3 解析成 epoch
    if date -s "$D" >/dev/null 2>&1 && sane; then
      log "HTTP Date 兜底校时成功（$url）：$(date '+%F %T')"
      exit 0
    fi
    if command -v python3 >/dev/null 2>&1; then
      EPOCH=$(python3 -c 'import sys,email.utils; print(int(email.utils.parsedate_to_datetime(sys.argv[1]).timestamp()))' "$D" 2>/dev/null) || EPOCH=""
      case "$EPOCH" in ''|*[!0-9-]*) EPOCH="" ;; esac
      if [ -n "$EPOCH" ] && date -s "@$EPOCH" >/dev/null 2>&1 && sane; then
        log "HTTP Date 兜底校时成功（$url，经 python3）：$(date '+%F %T')"
        exit 0
      fi
    fi
  done
  log "所有校时手段失败（无网络或被限），保留当前时钟，下次开机自动重试"
else
  log "时钟已恢复：$(date '+%F %T')"
fi
exit 0
