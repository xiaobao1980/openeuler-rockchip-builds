#!/usr/bin/env bash
# ============================================================================
# 集成安装：把 Node-RED + Mosquitto + Zigbee2MQTT 装进「离线的目标 rootfs」
#
# 与 iot/install_nodered_z2m_ubuntu24_v3.5.sh 的关系：
#   那份脚本是给「已经跑起来的 Ubuntu/Debian」做在线安装的（apt + PM2 + $HOME 路径）。
#   本脚本是给它做「镜像烧录前烘焙」的等价物，三处必须不同：
#
#   ① 发行版：openEuler 用 dnf，且 mosquitto 在 EPOL 仓（OS 仓没有）。实测 openEuler
#      的 mosquitto-2.0.20 已静态链接 libwebsockets.so.19 —— 天生支持 8083 WebSocket，
#      原脚本里「apt 版没 WS，要不要源码编译」这个决策点在这里不存在。
#   ② 进程管理：原脚本用 PM2（用户级，首启要 pm2 startup 才开机自启）。烧进镜像的
#      系统没有「用户已登录」这回事，PM2 的 resurrect 依赖 /home 下的 dump 文件，
#      在 sealed 镜像里属于自找麻烦。这里全部用 systemd 原生 unit。
#   ③ 路径：不用 $HOME/.node-red、$HOME/.pm2，改 FHS 固定路径 /var/lib/{node-red,
#      zigbee2mqtt}，服务以独立系统用户运行，不跑 root。
#
# 用法：
#   sudo ./integrate-iot.sh <rootfs目录> [选项]
#
# 选项：
#   --stack=node-red,mosquitto,z2m   要装的组件（默认 node-red,mosquitto）
#   --mqtt-user= --mqtt-pass=         MQTT 账号（默认 user-mqtt / Ab123456）
#   --mqtt-port=1883  --ws-port=8083  --nodered-port=1880  --z2m-port=8080
#   --coord=tcp://IP:8888 或 /dev/ttyUSB0（默认空=只启用服务不配置协调器）
#   --adapter=zstack|ember|ezsp|deconz  默认 zstack
#   --node-version=22                  Node.js 主版本
#   --npm-registry=https://registry.npmmirror.com
#   --no-clean                        保留 dnf/npm 缓存（调试用，会多占 ~200MB）
#
# 环境变量同义：IOT_STACK / IOT_MQTT_USER / IOT_MQTT_PASS / IOT_COORD / IOT_ADAPTER
# ============================================================================
set -euo pipefail

R="${1:?用法: $0 <rootfs目录> [选项]}"
shift || true

STACK="${IOT_STACK:-node-red,mosquitto}"
MQTT_USER="${IOT_MQTT_USER:-user-mqtt}"
MQTT_PASS="${IOT_MQTT_PASS:-Ab123456}"
MQTT_PORT="${IOT_MQTT_PORT:-1883}"
WS_PORT="${IOT_WS_PORT:-8083}"
NR_PORT="${IOT_NODERED_PORT:-1880}"
Z2M_PORT="${IOT_Z2M_PORT:-8080}"
COORD="${IOT_COORD:-}"
ADAPTER="${IOT_ADAPTER:-zstack}"
NODE_MAJOR="${IOT_NODE_VERSION:-22}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
DO_CLEAN=1

for a in "$@"; do
  case "$a" in
    --stack=*)         STACK="${a#*=}" ;;
    --mqtt-user=*)     MQTT_USER="${a#*=}" ;;
    --mqtt-pass=*)     MQTT_PASS="${a#*=}" ;;
    --mqtt-port=*)     MQTT_PORT="${a#*=}" ;;
    --ws-port=*)       WS_PORT="${a#*=}" ;;
    --nodered-port=*)  NR_PORT="${a#*=}" ;;
    --z2m-port=*)      Z2M_PORT="${a#*=}" ;;
    --coord=*)         COORD="${a#*=}" ;;
    --adapter=*)       ADAPTER="${a#*=}" ;;
    --node-version=*)  NODE_MAJOR="${a#*=}" ;;
    --npm-registry=*)  NPM_REGISTRY="${a#*=}" ;;
    --no-clean)        DO_CLEAN=0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

log()  { printf '\n\033[1;36m[IOT] %s\033[0m\n' "$*"; }
info() { printf '      %s\n' "$*"; }
warn() { printf '\033[1;33m[IOT-WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[IOT-ERR] %s\033[0m\n' "$*" >&2; exit 1; }

want() { case ",$STACK," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

[ "$(id -u)" = 0 ] || die "需要 root（要 chroot + mount）"
[ -d "$R/etc" ] || die "$R 不像 rootfs"
[ "$(uname -m)" = aarch64 ] || die "必须 aarch64（dnf/chroot 原生执行），当前 $(uname -m)"
grep -qs '^ID="*openEuler' "$R/etc/os-release" || die "$R/etc/os-release 不是 openEuler"

# ---------------------------------------------------------------------------
# chroot 环境：dnf / git / npm 都需要 /proc、/dev 和可用的 resolv.conf
# ---------------------------------------------------------------------------
NEED_UMOUNT=0
mountpoint -q "$R/proc" || { mount -t proc proc "$R/proc"; NEED_UMOUNT=1; }
mountpoint -q "$R/sys"  || { mount -t sysfs sys "$R/sys";  NEED_UMOUNT=1; }
mkdir -p "$R/dev" "$R/dev/pts" "$R/run"
mountpoint -q "$R/dev"     || { mount --bind /dev "$R/dev"; NEED_UMOUNT=1; }
mountpoint -q "$R/dev/pts" || { mount --bind /dev/pts "$R/dev/pts"; NEED_UMOUNT=1; }

# resolv.conf：官方 qcow2 里可能是空的或指向 systemd-resolved，chroot 内 DNS 会全挂
SAVED_RESOLV=""
if [ -e "$R/etc/resolv.conf" ] && [ ! -L "$R/etc/resolv.conf" ]; then
  SAVED_RESOLV="$R/etc/resolv.conf.iotbak"
  cp -f "$R/etc/resolv.conf" "$SAVED_RESOLV"
fi
rm -f "$R/etc/resolv.conf"
{ echo "# temporary, restored after integrate"; grep -E '^(nameserver|options)' /etc/resolv.conf 2>/dev/null || echo "nameserver 223.5.5.5"; } \
  > "$R/etc/resolv.conf"

cleanup() {
  set +e
  if [ -n "$SAVED_RESOLV" ] && [ -f "$SAVED_RESOLV" ]; then
    mv -f "$SAVED_RESOLV" "$R/etc/resolv.conf"
  fi
  if [ "$NEED_UMOUNT" = 1 ]; then
    umount "$R/dev/pts" 2>/dev/null; umount "$R/dev" 2>/dev/null
    umount "$R/sys" 2>/dev/null;     umount "$R/proc" 2>/dev/null
  fi
}
trap cleanup EXIT

# 在目标 rootfs 里跑命令。PATH 里带上 node 安装目录，否则 systemd unit 与 npm 会找不到
cr() {
  chroot "$R" /usr/bin/env -i \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOME=/root LANG=C.UTF-8 \
    bash -c "$*"
}

log "目标系统"
info "$(grep -E '^(PRETTY_NAME)=' "$R/etc/os-release" | cut -d= -f2- | tr -d '\"')"
info "组件: $STACK"

# ---------------------------------------------------------------------------
# 1. 基础包
# ---------------------------------------------------------------------------
log "安装基础包（dnf）"
DNFC="dnf -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
      --setopt=timeout=20 --setopt=retries=1"
cr "$DNFC makecache" >/dev/null 2>&1 || warn "makecache 失败，继续"
# tar/xz 是解压 Node 用的；procps-ng 提供 pgrep 供后续排障；shadow 提供 useradd
BASE_PKGS="tar xz curl ca-certificates git procps-ng shadow util-linux hostname findutils"
if ! cr "$DNFC install $BASE_PKGS" >/tmp/iot-dnf-base.log 2>&1; then
  tail -25 /tmp/iot-dnf-base.log >&2
  warn "一次装不齐，逐个补装（openEuler 精简镜像的包名差异很常见）"
  for p in tar xz curl ca-certificates git procps-ng shadow util-linux; do
    cr "$DNFC install $p" >/dev/null 2>&1 || warn "  $p 装不上，跳过"
  done
fi
cr "command -v curl >/dev/null && command -v git >/dev/null" || die "curl/git 缺失，无法继续"

# openEuler 24.03 的 mosquitto 只在 EPOL 仓。若 OS 仓里找不到，按现有 repo 的
# 主机名与版本号动态拼一个 EPOL 源 —— 不硬编码版本，换 SP 也不会失效。
epol_fallback() {
  [ -f "$R/etc/yum.repos.d/epol-iot.repo" ] && return 0
  local ver arch cand chosen="" defhost
  ver=$(grep -hoE 'openEuler-[0-9.]+-LTS(-SP[0-9]+)?' "$R"/etc/yum.repos.d/*.repo 2>/dev/null | awk 'NR==1')
  [ -n "$ver" ] || { warn "无法从现有 repo 判定 openEuler 版本号"; return 1; }
  arch=$(cr 'uname -m')
  defhost=$(grep -hoE 'https?://[^/]+' "$R"/etc/yum.repos.d/*.repo 2>/dev/null | awk 'NR==1')

  # 关键：镜像自带的 repo 指向 license.coscl.org.cn —— 实测这台主机 30s 连不上，
  # 所以「从现有 repo 反推 EPOL 地址」会得到一个死地址。按候选顺序实测 repomd.xml
  # 可达性，取第一个能用的。
  for cand in \
      "https://dl-cdn.openeuler.openatom.cn/$ver/EPOL/main/$arch" \
      "https://repo.openeuler.openatom.cn/$ver/EPOL/main/$arch" \
      "${defhost:-none}/$ver/EPOL/main/$arch"; do
    case "$cand" in /*|none/*) continue ;; esac
    if curl -fsS -o /dev/null --max-time 15 "$cand/repodata/repomd.xml" 2>/dev/null; then
      chosen="$cand"; break
    fi
    info "  不可达: $cand"
  done
  [ -n "$chosen" ] || { warn "EPOL 候选源全部不可达（镜像自带 $defhost 也不通）"; return 1; }

  info "添加 EPOL 源: $chosen/"
  cat > "$R/etc/yum.repos.d/epol-iot.repo" <<EOF
[EPOL-iot]
name=openEuler EPOL (added by openeuler-rockchip-builds)
baseurl=$chosen/
enabled=1
gpgcheck=0
skip_if_unavailable=1
timeout=20
retries=1
EOF
  cr "dnf -y makecache" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 2. Mosquitto（TCP + WebSocket）
# ---------------------------------------------------------------------------
setup_mosquitto() {
  log "安装 Mosquitto"
  if ! cr "$DNFC install mosquitto" >/tmp/iot-dnf-mosq.log 2>&1; then
    warn "OS 仓没有 mosquitto，补 EPOL 源后重试"
    epol_fallback || die "无法添加 EPOL 源"
    if ! cr "$DNFC install mosquitto" >/tmp/iot-dnf-mosq.log 2>&1; then
      tail -25 /tmp/iot-dnf-mosq.log >&2
      die "mosquitto 安装失败（EPOL 也装不上）"
    fi
  fi
  cr "command -v mosquitto >/dev/null || test -x /usr/sbin/mosquitto" || die "mosquitto 安装后仍找不到可执行文件"

  # 关键事实：openEuler 的 mosquitto 已链接 libwebsockets，8083 直接可用。
  # 但仍显式检测一次 —— 万一某版本没编 WS，配置里写 listener 8083 protocol
  # websockets 会让整个服务起不来（Duplicate/Unknown protocol），那才是灾难。
  local has_ws=no
  # 用 grep -a 而不是 strings：目标 rootfs 里通常没有 binutils
  if grep -aq 'libwebsockets\.so' "$R/usr/sbin/mosquitto" 2>/dev/null; then
    has_ws=yes
  fi
  info "WebSocket 支持: $has_ws"

  mkdir -p "$R/etc/mosquitto/conf.d" "$R/var/lib/mosquitto" "$R/var/log/mosquitto"
  # 密码文件（-b 批量；-c 首次创建）
  if [ ! -f "$R/etc/mosquitto/passwd" ]; then
    # 用 600 创建：权限过宽时 mosquitto_passwd 会告警
    install -m 600 /dev/null "$R/etc/mosquitto/passwd"
  fi
  if ! grep -q "^${MQTT_USER}:" "$R/etc/mosquitto/passwd" 2>/dev/null; then
    cr "mosquitto_passwd -b /etc/mosquitto/passwd '$MQTT_USER' '$MQTT_PASS'" || die "写 mosquitto 密码文件失败"
  fi
  chmod 600 "$R/etc/mosquitto/passwd"
  # uid 不能猜（openEuler 的 mosquitto 用户不一定是 1883），从 passwd 里读
  local mu mg
  mu=$(awk -F: '$1=="mosquitto"{print $3}' "$R/etc/passwd" | head -1)
  mg=$(awk -F: '$1=="mosquitto"{print $4}' "$R/etc/passwd" | head -1)
  [ -n "$mu" ] && chown "$mu:$mg" "$R/etc/mosquitto/passwd"
  [ -n "$mu" ] && chown -R "$mu:$mg" "$R/var/lib/mosquitto" "$R/var/log/mosquitto" 2>/dev/null || true

  # 主配置只留 include_dir：openEuler 自带的 mosquitto.conf 里有 pid_file / log_dest
  # 等默认项，和 conf.d 里的 listener 混在一起容易出 Duplicate value
  cat > "$R/etc/mosquitto/mosquitto.conf" <<'EOF'
# 由 openeuler-rockchip-builds 生成
include_dir /etc/mosquitto/conf.d
EOF

  {
    echo "# 由 openeuler-rockchip-builds 生成"
    echo "allow_anonymous false"
    echo "password_file /etc/mosquitto/passwd"
    echo "persistence true"
    echo "persistence_location /var/lib/mosquitto/"
    echo "log_dest journal"
    echo ""
    echo "# TCP MQTT（设备 / 后端 / HA）"
    echo "listener $MQTT_PORT"
    echo "protocol mqtt"
    if [ "$has_ws" = yes ]; then
      echo ""
      echo "# WebSocket（浏览器 / IoTManager WebView / MQTT.js）"
      echo "listener $WS_PORT"
      echo "protocol websockets"
    fi
  } > "$R/etc/mosquitto/conf.d/zigbee2mqtt.conf"
  # 清理可能冲突的旧片段
  rm -f "$R/etc/mosquitto/conf.d/auth.conf" "$R/etc/mosquitto/conf.d/local.conf"

  # 服务已在 dnf 装好；确保 /run/mosquitto 由 systemd 自动创建（openEuler 的 unit 里
  # 通常已有 RuntimeDirectory，这里只在缺失时补 drop-in）
  if ! grep -qs 'RuntimeDirectory' "$R/usr/lib/systemd/system/mosquitto.service" 2>/dev/null; then
    mkdir -p "$R/etc/systemd/system/mosquitto.service.d"
    cat > "$R/etc/systemd/system/mosquitto.service.d/10-runtime-dir.conf" <<'EOF'
[Service]
RuntimeDirectory=mosquitto
RuntimeDirectoryMode=0755
EOF
  fi
  info "配置: TCP $MQTT_PORT / WS $WS_PORT / 用户 $MQTT_USER"
}

# ---------------------------------------------------------------------------
# 3. Node.js（官方二进制，与发行版无关，避免踩 openEuler 的 node 版本）
# ---------------------------------------------------------------------------
setup_nodejs() {
  log "安装 Node.js ${NODE_MAJOR}.x"
  if cr "command -v node >/dev/null && node -v | grep -q '^v${NODE_MAJOR}\.'"; then
    info "已存在 $(cr 'node -v')，跳过"
    return 0
  fi

  local arch=arm64 ver url
  # 不用 $(case ... ) —— 嵌套的命令替换里 case 模式的右括号会让解析器混淆
  case "$(cr 'uname -m')" in
    aarch64) arch=arm64 ;;
    x86_64)  arch=x64 ;;
    *) die "不支持的架构: $(cr 'uname -m')" ;;
  esac

  # 取最新的 v<NODE_MAJOR> 小版本；nodejs.org 不通就从 npmmirror 的同名目录取
  ver=""
  for idx in "https://nodejs.org/dist/index.json" \
             "https://npmmirror.com/mirrors/node/index.json"; do
    ver=$(curl -sS --max-time 20 "$idx" 2>/dev/null | tr ',' '\n' | grep -oE '"version":"v'"$NODE_MAJOR"'\.[0-9]+\.[0-9]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+') || true
    [ -n "$ver" ] && break
  done
  [ -n "$ver" ] || die "无法确定 Node ${NODE_MAJOR}.x 的最新版本号（nodejs.org 与 npmmirror 都不通）"
  info "版本: v$ver ($arch)"

  local f="node-v${ver}-linux-${arch}.tar.xz"
  local ok=0
  for base in "https://npmmirror.com/mirrors/node/v$ver" "https://nodejs.org/dist/v$ver"; do
    info "下载 $base/$f"
    if cr "cd /tmp && curl -fsSL --retry 3 --max-time 300 -o $f '$base/$f'"; then ok=1; break; fi
    warn "  失败，换下一个源"
  done
  [ "$ok" = 1 ] || die "Node.js 下载失败"

  cr "mkdir -p /usr/local/lib/nodejs && tar -xf /tmp/$f -C /usr/local/lib/nodejs && rm -f /tmp/$f"
  cr "ln -sf /usr/local/lib/nodejs/node-v${ver}-linux-${arch}/bin/node /usr/local/bin/node" || die "node 软链失败"
  cr "ln -sf /usr/local/lib/nodejs/node-v${ver}-linux-${arch}/bin/npm  /usr/local/bin/npm"
  cr "ln -sf /usr/local/lib/nodejs/node-v${ver}-linux-${arch}/bin/npx  /usr/local/bin/npx"
  cr "node -v && npm -v" || die "Node.js 装完不可用"
  if [ -n "$NPM_REGISTRY" ]; then
    cr "npm config set registry '$NPM_REGISTRY'" || warn "设置 npm 镜像失败"
  fi
  cr "npm config set fund false && npm config set audit false" || true
}


# npm -g 的产物落在 node 自己的 bin 目录（官方 tarball 的 prefix 是
# /usr/local/lib/nodejs/node-vX-linux-arm64），不在 PATH 上。node/npm/npx 我们建了
# 软链，其余全局包必须同样处理，否则 "装完了但 command -v 找不到"。
link_global_bin() {
  local n="$1" d
  # 不能用 dirname $(command -v node)：那是软链 /usr/local/bin/node，dirname 得到
  # /usr/local/bin，而 npm -g 的产物在 tarball 自己的 prefix 下。问 npm 要权威值。
  d=$(cr 'npm prefix -g')
  if cr "[ -x '$d/bin/$n' ]"; then
    cr "ln -sf '$d/bin/$n' /usr/local/bin/$n"
    info "$n → /usr/local/bin/$n（来自 $d/bin）"
  else
    warn "  $d/bin/$n 不存在"
  fi
}

# ---------------------------------------------------------------------------
# 4. Node-RED（systemd 直管，不用 PM2）
# ---------------------------------------------------------------------------
setup_nodered() {
  log "安装 Node-RED"
  cr "command -v node-red >/dev/null" || {
    info "npm 全局安装 node-red（约 2-4 分钟）"
    cr "npm install -g --unsafe-perm node-red" >/tmp/iot-npm-nr.log 2>&1 || {
      tail -25 /tmp/iot-npm-nr.log >&2
      die "node-red 安装失败"
    }
  }
  cr "command -v node-red >/dev/null" || link_global_bin node-red
  cr "command -v node-red >/dev/null" || die "node-red 装完找不到（npm -g 的 bin 目录未入 PATH）"
  info "路径: $(cr 'command -v node-red')"

  # 独立系统用户：Node-RED 官方明确不建议 root 运行
  cr "id -u nodered >/dev/null 2>&1 || useradd -r -m -d /var/lib/node-red -s /sbin/nologin nodered" || warn "创建 nodered 用户失败"
  mkdir -p "$R/var/lib/node-red"
  # 用 rootfs 里的真实 uid/gid，不要猜 1000
  local uid gid
  uid=$(awk -F: '$1=="nodered"{print $3}' "$R/etc/passwd" | head -1)
  gid=$(awk -F: '$1=="nodered"{print $4}' "$R/etc/passwd" | head -1)
  [ -n "$uid" ] && chown -R "$uid:$gid" "$R/var/lib/node-red"

  cat > "$R/etc/systemd/system/node-red.service" <<EOF
[Unit]
Description=Node-RED
After=network-online.target mosquitto.service
Wants=network-online.target
Documentation=https://nodered.org/docs/

[Service]
Type=simple
User=nodered
Group=nodered
WorkingDirectory=/var/lib/node-red
Environment="NODE_ENV=production"
Environment="PORT=$NR_PORT"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="NODE_OPTIONS=--max-old-space-size=256"
ExecStart=/usr/local/bin/node-red --userDir /var/lib/node-red
Restart=on-failure
RestartSec=5
# 首启会生成 settings.js，给足时间
TimeoutStartSec=120
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  info "端口 $NR_PORT，用户目录 /var/lib/node-red"
}

# ---------------------------------------------------------------------------
# 5. Zigbee2MQTT（源码 + 构建，无官方预编译包）
# ---------------------------------------------------------------------------
setup_z2m() {
  log "安装 Zigbee2MQTT"
  cr "id -u zigbee2mqtt >/dev/null 2>&1 || getent group dialout >/dev/null || groupadd -r dialout" >/dev/null 2>&1 || true
  cr "id -u zigbee2mqtt >/dev/null 2>&1 || useradd -r -m -d /var/lib/zigbee2mqtt -s /sbin/nologin -G dialout zigbee2mqtt" || warn "创建 zigbee2mqtt 用户失败"
  local uid gid
  uid=$(awk -F: '$1=="zigbee2mqtt"{print $3}' "$R/etc/passwd" | head -1)
  gid=$(awk -F: '$1=="zigbee2mqtt"{print $4}' "$R/etc/passwd" | head -1)

  if [ -d "$R/opt/zigbee2mqtt/.git" ]; then
    info "已存在，跳过克隆"
  else
    rm -rf "${R:?}/opt/zigbee2mqtt"
    cr "git clone --depth 1 https://github.com/Koenkk/zigbee2mqtt.git /opt/zigbee2mqtt" \
       > /tmp/iot-z2m-clone.log 2>&1 || {
      tail -15 /tmp/iot-z2m-clone.log >&2
      die "克隆 zigbee2mqtt 失败（GitHub 不通？）"
    }
  fi

  # pnpm：Z2M 2.x 是 pnpm workspace，用 npm 装会缺 workspace 依赖。
  # store-dir 放在项目内 → 硬链接，不额外占一份体积。
  local pm=""
  if cr "command -v pnpm >/dev/null"; then
    pm=pnpm
  else
    info "安装 pnpm"
    if cr "npm install -g pnpm@10" >/tmp/iot-pnpm.log 2>&1; then
      cr "command -v pnpm >/dev/null" || link_global_bin pnpm
      cr "command -v pnpm >/dev/null" && pm=pnpm
    fi
  fi
  info "包管理器: ${pm:-npm}"

  cr "cd /opt/zigbee2mqtt && export npm_config_registry='$NPM_REGISTRY' && \
      $(if [ "$pm" = pnpm ]; then echo "pnpm config set store-dir /opt/zigbee2mqtt/.pnpm-store --location project >/dev/null 2>&1 || true; pnpm install --frozen-lockfile || pnpm install"; else echo "npm ci || npm install"; fi)" \
      >/tmp/iot-z2m-deps.log 2>&1 || {
    tail -30 /tmp/iot-z2m-deps.log >&2
    die "Z2M 依赖安装失败"
  }
  info "构建（tsc + 前端）"
  cr "cd /opt/zigbee2mqtt && $(if [ "$pm" = pnpm ]; then echo "pnpm run build"; else echo "npm run build"; fi)" \
     > /tmp/iot-z2m-build.log 2>&1 || {
    tail -30 /tmp/iot-z2m-build.log >&2
    die "Z2M 构建失败"
  }
  # 注意：Z2M 的 lib/ 里没有 index.ts。仓库根的 index.js（package.json main/start）
  # 才是不带扩展名的入口，它 require("./dist/controller")。所以 tsc 的产物是
  # dist/controller.js —— 判 dist/index.js 会永远为假（踩过）。
  if [ ! -f "$R/opt/zigbee2mqtt/dist/controller.js" ]; then
    warn "dist 内容: $(ls "$R/opt/zigbee2mqtt/dist" 2>/dev/null | tr '\n' ' ')"
    die "构建后没有 dist/controller.js（tsc 没产出？见 /tmp/iot-z2m-build.log）"
  fi

  # 配置：协调器为空时写注释占位（首启手工填），不写死假地址
  mkdir -p "$R/opt/zigbee2mqtt/data" "$R/var/log/zigbee2mqtt"
  local serial
  if [ -z "$COORD" ]; then
    serial='  # 未配置协调器 —— 填好后 systemctl start zigbee2mqtt
  # port: /dev/ttyUSB0            # USB：Sonoff ZBDongle-P/E、ConBee
  # adapter: zstack
  # port: tcp://192.168.1.100:8888 # 以太网：ZB-GW03、SLZB-06、ZigStar
  # adapter: ezsp
  # baudrate: 115200'
  else
    serial="  port: $COORD
  adapter: $ADAPTER"
    case "$COORD" in tcp://*) serial="$serial
  baudrate: 115200
  rtscts: false" ;; esac
  fi

  cat > "$R/opt/zigbee2mqtt/data/configuration.yaml" <<EOF
# 由 openeuler-rockchip-builds 生成于 $(date -u +%FT%TZ)
version: 5

homeassistant:
  enabled: true
  legacy_entity_attributes: false
  legacy_triggers: false
  status_topic: homeassistant/status

mqtt:
  server: mqtt://127.0.0.1:$MQTT_PORT
  base_topic: zigbee2mqtt
  user: $MQTT_USER
  password: $MQTT_PASS
  client_id: zigbee2mqtt_gateway
  keepalive: 60
  qos: 1
  retain: true

serial:
$serial

frontend:
  enabled: true
  port: $Z2M_PORT
  host: 0.0.0.0

advanced:
  log_level: info
  log_directory: /var/log/zigbee2mqtt/%TIMESTAMP%
  log_file: log.txt
  channel: 25
  transmit_power: 10
  adapter_concurrent: 16
  last_seen: ISO_8601
  availability_timeout: 60
  backup_interval: 24
  pan_id_conflict_detection: true

map:
  enabled: true

device_options:
  retain: true
  qos: 1

devices: {}
groups: {}
EOF

  [ -n "$uid" ] && chown -R "$uid:$gid" "$R/opt/zigbee2mqtt" "$R/var/log/zigbee2mqtt"

  cat > "$R/etc/systemd/system/zigbee2mqtt.service" <<EOF
[Unit]
Description=Zigbee2MQTT
After=network-online.target mosquitto.service
Wants=network-online.target mosquitto.service

[Service]
Type=simple
User=zigbee2mqtt
Group=zigbee2mqtt
WorkingDirectory=/opt/zigbee2mqtt
Environment="NODE_ENV=production"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/local/bin/node index.js
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  info "配置: MQTT 127.0.0.1:$MQTT_PORT / 前端 $Z2M_PORT / 协调器 ${COORD:-未配置}"
}

# ---------------------------------------------------------------------------
# 6. 串口权限 + 防火墙
# ---------------------------------------------------------------------------
setup_misc() {
  log "串口权限与防火墙"

  # 开机自启：直接建 wants 软链 —— chroot 里 systemctl enable 依赖 systemd 内部状态，
  # 在 sealed 镜像里不可靠；软链是 systemd 唯一认可的事实来源，等价且确定。
  enable_unit() {
    local u="$1"
    mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
    if [ -f "$R/usr/lib/systemd/system/$u" ] || [ -f "$R/etc/systemd/system/$u" ]; then
      ln -sf "/usr/lib/systemd/system/$u" "$R/etc/systemd/system/multi-user.target.wants/$u" 2>/dev/null || true
      # 若 unit 在 /etc 下，软链要指向 /etc
      [ -f "$R/etc/systemd/system/$u" ] && ln -sf "/etc/systemd/system/$u" "$R/etc/systemd/system/multi-user.target.wants/$u"
      info "已启用 $u"
    else
      warn "找不到 $u，未启用"
    fi
  }
  want mosquitto && enable_unit mosquitto.service
  want node-red  && enable_unit node-red.service
  want z2m       && enable_unit zigbee2mqtt.service

  # firewalld 在 openEuler 默认开启，不放行就是「服务在跑、外面连不上」
  if [ -d "$R/etc/firewalld" ]; then
    if [ -x "$R/usr/bin/firewall-offline-cmd" ] || [ -x "$R/usr/sbin/firewall-offline-cmd" ]; then
      local fp=()
      want mosquitto && fp+=("--add-port=$MQTT_PORT/tcp" "--add-port=$WS_PORT/tcp")
      want node-red  && fp+=("--add-port=$NR_PORT/tcp")
      want z2m       && fp+=("--add-port=$Z2M_PORT/tcp")
      if [ ${#fp[@]} -gt 0 ]; then
        cr "firewall-offline-cmd ${fp[*]}" >/dev/null 2>&1 && info "firewalld 已放行 ${fp[*]}" || warn "firewall-offline-cmd 失败，端口可能被拦"
      fi
    else
      warn "无 firewall-offline-cmd，直接关闭 firewalld（appliance 镜像的合理选择）"
      ln -sf /dev/null "$R/etc/systemd/system/firewalld.service"
    fi
  fi

  # 记录给首启后的排障
  cat > "$R/etc/iot-stack.env" <<EOF
# 由 openeuler-rockchip-builds 生成
IOT_STACK=$STACK
IOT_MQTT_USER=$MQTT_USER
IOT_MQTT_PORT=$MQTT_PORT
IOT_WS_PORT=$WS_PORT
IOT_NODERED_PORT=$NR_PORT
IOT_Z2M_PORT=$Z2M_PORT
IOT_COORD=$COORD
IOT_ADAPTER=$ADAPTER
IOT_BUILT_AT=$(date -u +%FT%TZ)
EOF
  mkdir -p "$R/etc/motd.d"
  cat > "$R/etc/motd.d/50-iot.conf" <<EOF
IoT 服务栈：$STACK
  Node-RED     http://<IP>:$NR_PORT
  Zigbee2MQTT  http://<IP>:$Z2M_PORT
  MQTT         <IP>:$MQTT_PORT   WS <IP>:$WS_PORT   (用户 $MQTT_USER)
  状态         systemctl status mosquitto node-red zigbee2mqtt
EOF
}

# ---------------------------------------------------------------------------
# 7. 清缓存（镜像里留着就是纯浪费）
# ---------------------------------------------------------------------------
do_clean() {
  [ "$DO_CLEAN" = 1 ] || { warn "跳过清理（--no-clean）"; return 0; }
  log "清理缓存"
  cr "dnf clean all" >/dev/null 2>&1 || true
  rm -rf "$R/var/cache/dnf"/* "$R/var/cache/yum"/* 2>/dev/null || true
  rm -rf "$R/root/.npm/_cacache" "$R/usr/local/lib/nodejs"/*/lib/node_modules/.cache 2>/dev/null || true
  rm -rf "$R/tmp"/* 2>/dev/null || true
  info "剩余 rootfs 体积: $(du -sh "$R" | cut -f1)"
}

want mosquitto && setup_mosquitto
want node-red  && { setup_nodejs; setup_nodered; }
want z2m       && { want node-red || setup_nodejs; setup_z2m; }
setup_misc
do_clean

log "集成安装完成"
info "组件: $STACK"
info "端口: MQTT $MQTT_PORT / WS $WS_PORT / Node-RED $NR_PORT / Z2M $Z2M_PORT"
[ -n "$COORD" ] && info "协调器: $COORD ($ADAPTER)" || info "协调器: 未配置（首启编辑 /opt/zigbee2mqtt/data/configuration.yaml）"
