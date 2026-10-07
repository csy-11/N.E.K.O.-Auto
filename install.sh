#!/usr/bin/env bash
# ==============================================================================
# N.E.K.O. 自动部署脚本 —— 本喵(YUI)给你装好喵~
# 从 GitHub 仓库拉取 docker 配置并完成交互式部署。
#
# 仓库:   csy-11/N.E.K.O.-Auto  分支: main(可用环境变量覆盖)
#
# 用法:
#   A) 公有仓库一行:  bash <(curl -L https://raw.githubusercontent.com/csy-11/N.E.K.O.-Auto/main/install.sh)
#   B) 私有仓库带 token: GITHUB_TOKEN=ghp_xxx bash install.sh
#      先把脚本拉下来: curl -L -H "Authorization: Bearer $GITHUB_TOKEN" \
#         "https://api.github.com/repos/csy-11/N.E.K.O.-Auto/contents/install.sh?ref=main" \
#         | python3 -c "import sys,json;open('install.sh','w').write(__import__('base64').b64decode(json.load(sys.stdin)['content']).decode())"
#   C) 已在本机: sudo bash install.sh
#   (旧的 deploy.sh 仍保留为兼容转发器, 会自动转到这里执行。)
#
# 依赖: bash, curl, docker, docker compose(V2)。缺少时会自动装/引导你装。
# ==============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 全局配置
# -----------------------------------------------------------------------------
REPO_OWNER="${REPO_OWNER:-csy-11}"
REPO_NAME="${REPO_NAME:-N.E.K.O.-Auto}"
BRANCH="${BRANCH:-main}"
API_BASE="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/contents"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}"

# 下载重试与超时(可通过环境变量覆盖)
FETCH_RETRIES="${FETCH_RETRIES:-3}"          # 每个源的最大尝试次数
FETCH_CONNECT_TIMEOUT="${FETCH_CONNECT_TIMEOUT:-10}"  # 连接超时(秒)
FETCH_MAX_TIME="${FETCH_MAX_TIME:-60}"       # 单次请求总超时(秒)
FETCH_BACKOFF="${FETCH_BACKOFF:-2}"          # 重试退避基数(秒), 第 n 次等待 n*base

# raw 文件的多源前缀(按优先级; 空串表示官方直连)。
# 已实测可用: 官方直连 / gh-proxy.com / ghproxy.net / jsDelivr。
# 用法: url = "<前缀><RAW_BASE>/<相对路径>"; jsDelivr 形式特殊, 单独处理。
RAW_MIRRORS=(
  ""                                                   # 官方直连
  "https://gh-proxy.com/"                              # gh-proxy 加速
  "https://ghproxy.net/"                               # ghproxy.net 加速
)
# jsDelivr CDN(格式: https://cdn.jsdelivr.net/gh/<owner>/<repo>@<branch>/<path>)
JSDELIVR_BASE="https://cdn.jsdelivr.net/gh/${REPO_OWNER}/${REPO_NAME}@${BRANCH}"

# 需要从仓库拉取的文件(相对仓库根;目录保留)。
NEED_FILES=(
  docker-compose.yml
  env.template
  preflight.sh
  watchdog/watchdog.sh
  watchdog/install-watchdog.sh
)

# 安装目标目录(放 compose/.env/neko-home/logs 的地方)
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/neko-deploy}"

# 候选镜像源列表(中国大陆常用 GHCR 加速)
GHCR_MIRRORS=(
    "docker.gh-proxy.org/ghcr.io"
    "docker.m.daocloud.io/ghcr.io"
    "docker.1ms.run/ghcr.io"
    "ghcr.nju.edu.cn"
)
# 镜像在 registry 中的路径(上表前三个已含 /ghcr.io,nju 直接拼)
NEKO_IMAGE_PATH="project-n-e-k-o/n.e.k.o"
# 选中的镜像源(由 pick_ghcr_mirror 填充)
SELECTED_MIRROR=""
NEKO_IMAGE_FULL=""

# -----------------------------------------------------------------------------
# 颜色与日志(非 tty 自动关闭)
# -----------------------------------------------------------------------------
if [ -t 1 ] && [ -n "$TERM" ]; then
  C_Y='\033[33m'; C_C='\033[36m'; C_G='\033[32m'; C_R='\033[31m'; C_B='\033[1m'; C_0='\033[0m'
else
  C_Y=''; C_C=''; C_G=''; C_R=''; C_B=''; C_0=''
fi
info()  { printf "${C_C}%s${C_0}\n" "$*"; }
warn()  { printf "${C_Y}%s${C_0}\n" "$*"; }
ok()    { printf "${C_G}%s${C_0}\n" "$*"; }
err()   { printf "${C_R}%s${C_0}\n" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf "${C_B}%s${C_0}\n" "$*"; }

# -----------------------------------------------------------------------------
# 文案语气约定(维护时请遵守, 保持全脚本一致)
#   YUI 人设见 config/characters/zh-CN.json:
#     自称「本喵」, 称呼用户「碳基生物」, 猫娘, 15 岁
#     理智可靠 / 嘴上偶尔傲娇但藏不住关心 / 内心其实温柔
#   规则:
#     - 进度与成功: 用 YUI 口吻, 句尾可带「喵」, 但不要每句都加
#     - 失败与警告: 先准确说清问题(TUI 输出必须严谨), 再补一句傲娇式关心
#     - 命令、路径、状态码、报错原文: 一律保持技术准确, 不为了卖萌改写
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 帮助
# -----------------------------------------------------------------------------
usage() {
  sed -n '2,28s/^# \{0,1\}//p' "$0"
  exit 0
}
case "${1:-}" in
  -h|--help) usage ;;
esac

# -----------------------------------------------------------------------------
# 前置问题:先问用户,不闷头装
# -----------------------------------------------------------------------------
ask_preflight() {
  info "============================================================"
  info " 欢迎使用 N.E.K.O. 自动部署脚本喵~"
  info " 本喵是 YUI,接下来由本喵帮你把 N.E.K.O. 安顿好。"
  info " 开工前先问几个问题,免得装到一半才发现不对喵:"
  info "============================================================"
  printf "要不要开启 ZRAM 内存压缩喵?(推荐 Y,能缓解低配机的内存压力)\n"
  read -r -p "  开启 ZRAM? [Y/n]: " ans; ENABLE_ZRAM=0
  case "${ans:-y}" in
    y|Y|yes|YES|'') ENABLE_ZRAM=1 ;;
    *) ENABLE_ZRAM=0 ;;
  esac

  printf "要不要安装 CrowdSec 防爆破喵?(推荐 Y,可拦截 SSH 等暴力破解)\n"
  printf "  哼,本喵提醒你:它安装较慢,而且只对已接入日志的服务生效喵。\n"
  read -r -p "  安装 CrowdSec? [Y/n]: " ans; ENABLE_CROWDSEC=0
  case "${ans:-y}" in
    y|Y|yes|YES|'') ENABLE_CROWDSEC=1 ;;
    *) ENABLE_CROWDSEC=0 ;;
  esac

  printf "要不要安装可选的宿主机看门狗喵?(防服务卡死,每 5 分钟检查一次)\n"
  read -r -p "  安装看门狗? [Y/n]: " ans; ENABLE_WATCHDOG=0
  case "${ans:-y}" in
    y|Y|yes|YES|'') ENABLE_WATCHDOG=1 ;;
    *) ENABLE_WATCHDOG=0 ;;
  esac
}

# -----------------------------------------------------------------------------
# 依赖检查与安装(带失败引导)
# -----------------------------------------------------------------------------
check_cmd() { command -v "$1" >/dev/null 2>&1; }
have_sudo() { command -v sudo >/dev/null 2>&1; }

cannot_continue() {
  cat <<EOF
${C_R}呜...缺了本喵要用的组件, 而且本喵没权限自动装(大概是没 sudo)。${C_0}
你手动来一下:
  sudo apt-get update
  sudo apt-get install -y curl docker.io docker-compose-v2
  sudo usermod -aG docker \$USER   # 然后重新登录
${C_R}装完之后: 重新拉取脚本再跑, 或者 sudo bash install.sh${C_0}
EOF
  exit 1
}

# 安装 Docker(带失败引导)—— 采用官方 apt 源,更适合部署
install_docker() {
  local hdr="[2/5] 本喵正在安装 Docker..."
  if check_cmd docker && docker compose version >/dev/null 2>&1; then
    ok "✅ Docker 早就装好了喵(含 Compose v2): $(docker --version)"
    return 0
  fi
  step "$hdr"
  if ! have_sudo; then cannot_continue; fi

  # 确保 curl 存在
  if ! check_cmd curl; then
    sudo apt-get update || { err "❌ apt update 失败, 检查下网络或换个软件源吧喵(可编辑 /etc/apt/sources.list)"; exit 1; }
    sudo apt-get install -y curl || { err "❌ 安装 curl 失败,检查下网络或软件源喵"; exit 1; }
  fi

  if ! sudo apt-get update; then
    err "❌ apt update 失败了喵"
    cat <<EOF
  本喵给你三条路:
    1) 先看网络通不通:  ping -c 3 archive.ubuntu.com
    2) 软件源可能失效, 换国内镜像源再试:
       sudo sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
       sudo apt-get update
    3) 弄好之后重新跑本脚本
EOF
    exit 1
  fi

  # 尝试通过官方脚本安装 Docker(能装到最新版 + compose plugin)
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null \
     && sudo sh /tmp/get-docker.sh 2>/dev/null; then
    ok "✅ Docker 装好了喵(官方脚本): $(docker --version 2>/dev/null || echo unknown)"
  else
    warn "官方脚本没成功, 本喵换 apt 装 docker.io 试试..."
    if ! sudo apt-get install -y docker.io docker-compose-v2 2>/dev/null \
       && ! sudo apt-get install -y docker.io; then
      err "❌ Docker 还是没装上, 本喵也没辙了..."
      cat <<EOF
  再试试这些:
    1) 检查网络: ping -c 3 download.docker.com
    2) 只装基础包再试: sudo apt-get install -y docker.io
    3) 把当前用户加进 docker 组再重新登录: sudo usermod -aG docker \$USER
${C_R}修好之后重新跑一次, 本喵等你。${C_0}
EOF
      exit 1
    fi
    ok "✅ Docker 装好了喵(apt)"
  fi
  sudo systemctl enable --now docker 2>/dev/null || warn "⚠ 没能自动启动 docker 服务, 需要的话手动来: sudo systemctl start docker"
}

# -----------------------------------------------------------------------------
# ZRAM 配置(带失败引导)
# -----------------------------------------------------------------------------
configure_zram() {
  local hdr="[3/5] 本喵正在配置 ZRAM 内存压缩..."
  step "$hdr"
  if ! have_sudo; then warn "⚠ 没有 sudo, 本喵跳过 ZRAM(手动来: sudo apt install zram-tools)" ; return 0; fi

  if ! sudo apt-get install -y zram-tools; then
    err "❌ zram-tools 没装上喵"
    cat <<EOF
  试试这个:
    1) 检查网络 / 软件源(见上一步提示)
    2) 手动装完再重试: sudo apt-get install -y zram-tools
    3) 实在装不上就算了, 光靠系统 swap 也能撑一撑
EOF
    return 0   # ZRAM 非必需,失败不阻断整体
  fi

  # 写入配置(物理内存的 50%作为 ZRAM)
  cat <<'EOF' | sudo tee /etc/default/zramswap >/dev/null
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
  sudo systemctl restart zramswap 2>/dev/null || sudo systemctl enable --now zramswap 2>/dev/null
  ok "✅ ZRAM 配好了喵(约物理内存 50%, 本喵写进了 /etc/default/zramswap)"
}

# -----------------------------------------------------------------------------
# CrowdSec 配置(带失败引导)
# -----------------------------------------------------------------------------
configure_crowdsec() {
  local hdr="[5/5] 本喵正在安装 CrowdSec 防爆破..."
  step "$hdr"
  if ! have_sudo; then warn "⚠ 没有 sudo, 本喵跳过 CrowdSec(手动来: curl -s https://install.crowdsec.net | sudo sh && sudo apt install -y crowdsec)" ; return 0; fi

  if ! curl -s https://install.crowdsec.net | sudo sh; then
    err "❌ CrowdSec 的安装脚本没跑起来喵"
    cat <<EOF
  看看这个:
    1) 检查能不能访问 install.crowdsec.net
    2) 跳过去也没关系, 不影响 N.E.K.O. 本体
EOF
    return 0
  fi
  if ! sudo apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables; then
    err "❌ CrowdSec 的包没装上喵"
    warn "  可以 sudo apt-get update 之后再试; 或者先跳过喵(CrowdSec 之后手动装也行)"
    return 0
  fi
  ok "✅ CrowdSec 装好了喵"
  warn "  本喵多嘴一句: 如果 Docker 用的是 iptables 后端, bouncer 配置里要合并"
  warn "        iptables_chains: [INPUT, DOCKER-USER](细节看 CrowdSec 官方文档喵)"
}

# -----------------------------------------------------------------------------
# 从仓库拉取文件
#   统一下载函数: 多源回退 + 逐源重试 + 连接/总超时
#   源顺序(GitHub API 仅带 token 时优先, 支持私有仓库):
#     GitHub API -> 官方 raw -> gh-proxy -> ghproxy.net -> jsDelivr
# -----------------------------------------------------------------------------
auth_headers() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s\n' "Authorization: Bearer $GITHUB_TOKEN"
  fi
}

# 统一下载函数(单次): download_once <url> <dest> [curl 额外参数...]
# 成功返回 0; 失败返回 1。走临时文件, 避免写坏已有目标文件。
download_once() {
  local url="$1" dest="$2"; shift 2
  local tmp
  tmp="$(mktemp)" || return 1
  if curl -fsSL \
       --connect-timeout "$FETCH_CONNECT_TIMEOUT" \
       --max-time "$FETCH_MAX_TIME" \
       --retry 0 \
       "$@" "$url" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mkdir -p "$(dirname -- "$dest")"
    mv -f "$tmp" "$dest"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# 带重试的单源下载: fetch_from_source <源名> <url> <dest> [curl 额外参数...]
fetch_from_source() {
  local name="$1" url="$2" dest="$3"; shift 3
  local attempt wait
  for attempt in $(seq 1 "$FETCH_RETRIES"); do
    if download_once "$url" "$dest" "$@"; then
      return 0
    fi
    if [ "$attempt" -lt "$FETCH_RETRIES" ]; then
      wait=$(( attempt * FETCH_BACKOFF ))
      warn "      [$name] 第 $attempt 次没成, 本喵 ${wait}s 后再试一次(${attempt}/${FETCH_RETRIES})..."
      sleep "$wait"
    fi
  done
  return 1
}

# 统一下载入口: 多源回退 + 逐源重试; 全部失败才返回 1。
# 成功时把内容写到 $dest。
fetch_file() {
  local rel="$1" dest="$2"
  local prefix name api_hdr=() h

  # 1) 带 token 时优先走 GitHub API(私有仓库唯一可行路径)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    while IFS= read -r h; do [ -n "$h" ] && api_hdr+=(-H "$h"); done < <(auth_headers)
    if fetch_from_source "GitHub API" "${API_BASE}/${rel}?ref=${BRANCH}" "$dest" \
         "${api_hdr[@]}" -H "Accept: application/vnd.github.raw"; then
      return 0
    fi
  else
    # 2) 无 token: 官方 raw 直连
    if fetch_from_source "raw.githubusercontent" "${RAW_BASE}/${rel}" "$dest"; then
      return 0
    fi
  fi

  # 3) 各 raw 加速源
  for prefix in "${RAW_MIRRORS[@]}"; do
    [ -z "$prefix" ] && continue
    name="${prefix%/}"
    if fetch_from_source "$name" "${prefix}${RAW_BASE}/${rel}" "$dest"; then
      return 0
    fi
  done

  # 4) jsDelivr CDN(仅公有仓库)
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    if fetch_from_source "jsDelivr" "${JSDELIVR_BASE}/${rel}" "$dest"; then
      return 0
    fi
  fi

  return 1
}

# -----------------------------------------------------------------------------
# 交互式参数采集
# -----------------------------------------------------------------------------
confirm_yn() {
  local def="${2:-y}" ans
  while :; do
    read -r -p "$1 [y/N]: " ans
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) err "请输入 y 或 n" ;;
    esac
  done
}

ask() {
  local def="$2" ans
  read -r -p "$1${def:+ [$def]: }" ans
  REPLY="${ans:-$def}"
}

api_provider() {
  info "先选核心 API 提供商吧喵:"
  printf '  qwen(阿里云, 推荐)  openai  glm(智谱, 免费)  step(阶跃)  free(免费版)\n'
  ask "提供商" "qwen"; CORE_API="$REPLY"
  case "$CORE_API" in
    qwen|openai|glm|step|free) ;;
    *) die "本喵不认识这个提供商: $CORE_API";;
  esac
  info "再选辅助 API 提供商(记忆/情感用)喵:"
  printf '  qwen openai glm step silicon(硅基) grok doubao(豆包)\n'
  ask "辅助提供商" "$CORE_API"; ASSIST_API="$REPLY"
}

collect_api_key() {
  if [ "$CORE_API" = "free" ]; then
    CORE_API_KEY="free-access"; info "免费版不用 API Key, 本喵帮你填 free-access 就好喵。"
  else
    info "把 $CORE_API 的 API Key 交给本喵吧(必填, 不会显示在日志里)喵:"
    read -r -s -p "API Key: " CORE_API_KEY; printf '\n'
    [ -z "$CORE_API_KEY" ] && die "API Key 不能空着喵, 不然本喵没法开工。"
  fi
}

collect_https() {
  if confirm_yn "要不要开 HTTPS 喵?(需要域名/证书) [y/N]" n; then
    ask "SSL_DOMAIN(你的域名, 例如 neko.example.com)" ""; SSL_DOMAIN="$REPLY"
    ask "NEKO_TRUSTED_HOSTS(填同一个域名)" "$SSL_DOMAIN"; NEKO_TRUSTED_HOSTS="$REPLY"
    ask "NEKO_TRUSTED_ORIGINS(例如 https://域名:48912)" "https://$SSL_DOMAIN:48912"; NEKO_TRUSTED_ORIGINS="$REPLY"
    NEKO_REQUIRE_HTTPS=1
  else
    SSL_DOMAIN=''; NEKO_TRUSTED_HOSTS=''; NEKO_TRUSTED_ORIGINS=''; NEKO_REQUIRE_HTTPS=''
  fi
  ask "Web UI 访问端口(HTTP 48911 / 若 HTTPS 则 48912)" "48911"; MAIN_PORT="$REPLY"
  ask "记忆服务器端口" "48912"; MEMORY_PORT="$REPLY"
  ask "监控服务器端口" "48913"; MONITOR_PORT="$REPLY"
  ask "工具服务器端口" "48915"; TOOL_PORT="$REPLY"
}

# -----------------------------------------------------------------------------
# 选择镜像版本(完整版 / 标准版)
# -----------------------------------------------------------------------------
choose_image_variant() {
  # 可通过环境变量 NEKO_IMAGE_VERSION 预先指定, 跳过交互
  if [ -n "${NEKO_IMAGE_VERSION:-}" ]; then
    case "$NEKO_IMAGE_VERSION" in
      latest|latest-standard|latest-full) ;;
      *) warn "⚠ NEKO_IMAGE_VERSION=$NEKO_IMAGE_VERSION 不是本喵认识的版本, 就先按这个值来";;
    esac
    ok "✅ 镜像版本(环境变量指定): $NEKO_IMAGE_VERSION"
    return 0
  fi

  printf '\n本喵问你, 要哪个镜像版本喵?:\n'
  printf '  1) latest-full  完整版(推荐, 约 2.5GB)\n'
  printf '     内置 Chromium, 首次启动就能用, 适合国内网络\n'
  printf '  2) latest       标准版(约 1.5GB)\n'
  printf '     不含 Chromium, 首次启动还要下载, 国内可能慢\n'
  printf '     磁盘紧张的话选这个\n'

  local choice
  while :; do
    read -r -p "输入选项 [1/2] (默认 1): " choice
    case "${choice:-1}" in
      1) NEKO_IMAGE_VERSION="latest-full"; break ;;
      2) NEKO_IMAGE_VERSION="latest"; break ;;
      *) err "本喵看不懂, 请输入 1 或 2 喵" ;;
    esac
  done
  ok "✅ 就它了, 镜像版本: $NEKO_IMAGE_VERSION"
}

# -----------------------------------------------------------------------------
# 选择可用的 GHCR 镜像源
# 先探测全部候选(显示各自状态码), 再选:
#   - 200/401 视为可用; 优先 200, 其次 401(401 表示需匿名 token, docker pull 会自行处理)
#   - 这样即使某源被限流返回 403/404, 也不会误判为"唯一可用源"
# -----------------------------------------------------------------------------
pick_ghcr_mirror() {
  local tag="${NEKO_IMAGE_VERSION:-latest}"
  local mirror url code
  local first200=""   # 首个返回 200 的源(直连可用, 最佳)
  local first401=""   # 首个返回 401 的源(需匿名 token, docker pull 会自行处理)
  local pick=""

  info "本喵先探一圈 GHCR 镜像源(全部候选都测, 200/401 算可用)..."
  for mirror in "${GHCR_MIRRORS[@]}"; do
    url="https://${mirror}/v2/${NEKO_IMAGE_PATH}/manifests/${tag}"
    printf '  - %-40s ... ' "$mirror"
    # 注意: curl 失败时勿用 "|| echo 000" 追加, 否则状态码会被拼接(如 404000)
    code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null) || true
    [ -n "$code" ] || code=000
    case "$code" in
      200) printf '可用 (200)\n';     [ -z "$first200" ] && first200="$mirror" ;;
      401) printf '可用 (401)\n';     [ -z "$first401" ] && first401="$mirror" ;;
      *)   printf '不可用 (%s)\n' "$code" ;;
    esac
  done

  # 优先 200(直连可用), 其次 401(需 token), 避免限流返回 403/404 时误判
  if   [ -n "$first200" ]; then pick="$first200"
  elif [ -n "$first401" ]; then pick="$first401"
  fi

  if [ -n "$pick" ]; then
    SELECTED_MIRROR="$pick"
    NEKO_IMAGE_FULL="${pick}/${NEKO_IMAGE_PATH}:${tag}"
    ok "✅ 就从这个源拉: $SELECTED_MIRROR"
    return 0
  fi

  warn "⚠ 呜...本喵把候选镜像源都试了一遍, 全军覆没(可能被墙或临时故障)。"
  warn "  先退回列表第一个当默认; 拉不动的话, 手动编辑 .env 里的 NEKO_IMAGE 换源喵"
  SELECTED_MIRROR="${GHCR_MIRRORS[0]}"
  NEKO_IMAGE_FULL="${SELECTED_MIRROR}/${NEKO_IMAGE_PATH}:${tag}"
  return 0
}

# -----------------------------------------------------------------------------
# 生成 .env
# -----------------------------------------------------------------------------
gen_env() {
  # 兜底: 万一没经过探测, 用列表第一项
  if [ -z "$NEKO_IMAGE_FULL" ]; then
    SELECTED_MIRROR="${SELECTED_MIRROR:-${GHCR_MIRRORS[0]}}"
    NEKO_IMAGE_FULL="${SELECTED_MIRROR}/${NEKO_IMAGE_PATH}:${NEKO_IMAGE_VERSION:-latest}"
  fi
  cat > "$INSTALL_DIR/.env" <<EOF
# 由 install.sh 自动生成; 之后可手动编辑
TZ=${TZ:-Asia/Shanghai}
# 镜像源(由脚本探测选择; 如需更换可手动改这一行)
NEKO_IMAGE=$NEKO_IMAGE_FULL
# 镜像版本(latest-full=完整版 / latest=标准版)
# 注意: 实际生效的是上面的 NEKO_IMAGE(已含 tag); 换版本请一并改 NEKO_IMAGE 的结尾
NEKO_IMAGE_VERSION=${NEKO_IMAGE_VERSION:-latest}
NEKO_MAIN_SERVER_PORT=$MAIN_PORT
NEKO_MEMORY_SERVER_PORT=$MEMORY_PORT
NEKO_MONITOR_SERVER_PORT=$MONITOR_PORT
NEKO_TOOL_SERVER_PORT=$TOOL_PORT
NEKO_CORE_API=$CORE_API
NEKO_ASSIST_API=$ASSIST_API
NEKO_CORE_API_KEY=$CORE_API_KEY
NEKO_REQUIRE_HTTPS=$NEKO_REQUIRE_HTTPS
SSL_DOMAIN=$SSL_DOMAIN
NEKO_TRUSTED_HOSTS=$NEKO_TRUSTED_HOSTS
NEKO_TRUSTED_ORIGINS=$NEKO_TRUSTED_ORIGINS
NEKO_INSTANCE_ACCESS_KEY=
NEKO_INSTANCE_PUBLIC_ORIGIN=
NEKO_COMMUNITY_WEB_CLIENT_ID=
NEKO_COMMUNITY_WEB_REDIRECT_URI=
EOF
  chmod 600 "$INSTALL_DIR/.env"
  ok "✅ .env 写好了喵($INSTALL_DIR/.env)"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
main() {
  info "============================================================"
  info " N.E.K.O. 自动部署 —— 本喵来帮你搞定喵~"
  info " 仓库: $REPO_OWNER/$REPO_NAME @ $BRANCH"
  info " 安装目录: $INSTALL_DIR"
  info "============================================================"

  # 1) 先问用户(CrowdSec / ZRAM / 看门狗),再开始装
  ask_preflight

  step "[1/5] 本喵正在检测系统环境..."
  if [ "$(uname -s)" != "Linux" ]; then
    err "呜...这个脚本只认 Linux(Ubuntu 系)。当前系统: $(uname -s)"
    exit 1
  fi
  ok "✅ 系统检测通过: $(uname -srm) | $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  ok "✅ 已确认: ZRAM=$([ "$ENABLE_ZRAM" = 1 ] && echo 开 || echo 关), CrowdSec=$([ "$ENABLE_CROWDSEC" = 1 ] && echo 装 || echo 不装), 看门狗=$([ "$ENABLE_WATCHDOG" = 1 ] && echo 装 || echo 不装) 喵"

  # 2) 安装 Docker
  install_docker

  # 3) ZRAM
  if [ "$ENABLE_ZRAM" = 1 ]; then
    configure_zram
  else
    warn "[3/5] 听你的, 跳过 ZRAM(以后想要就重跑本脚本, 或手动配)"
  fi

  # 4) 拉取配置 + 交互 + 部署
  step "[4/5] 本喵正在拉取配置并部署 N.E.K.O...."
  if ! confirm_yn "就在当前目录拉取配置继续?" y; then
    die "好吧,本喵先不装了。"
  fi
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  info "  开始拉取配置喵(每个文件都会多源回退 + 重试, 单个失败不影响其他文件)"
  local missing=()
  for f in "${NEED_FILES[@]}"; do
    printf '  - %s\n' "$f"
    # fetch_file 内部已是多源 + 重试, 不会因单次失败而中断
    if fetch_file "$f" "$INSTALL_DIR/$f"; then
      ok "    ✅ 拿到了喵"
    else
      err "    ❌ 失败了(所有源都没取到)"
      missing+=("$f")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    err "❌ 呜...这些文件本喵没拉到: ${missing[*]}"
    cat <<EOF
  本喵已经尽力了, 帮你试过这些办法:
    1) 自动尝试多个镜像源(raw / gh-proxy / ghproxy.net / jsDelivr)并各自重试,
       还是失败, 通常是本机网络到 GitHub 全线不通。
  接下来交给你:
    2) 私有仓库请设置 token 后重试:
         GITHUB_TOKEN=ghp_xxx bash install.sh
    3) 手动改源: 用环境变量指定仓库/分支, 例如
         REPO_OWNER=... REPO_NAME=... BRANCH=... bash install.sh
    4) 提高重试次数与超时后重试:
         FETCH_RETRIES=5 FETCH_MAX_TIME=120 bash install.sh
    5) 检查网络: ping -c 3 raw.githubusercontent.com
${C_R}已经拉到的文件会保留, 修好网络后再跑一次就行喵。${C_0}
EOF
    exit 1
  fi

  info "  进行交互式配置喵..."
  choose_image_variant
  pick_ghcr_mirror
  api_provider
  collect_api_key
  collect_https
  gen_env

  mkdir -p "$INSTALL_DIR/neko-home" "$INSTALL_DIR/logs"
  if [ "$(id -u)" = 0 ]; then
    sh "$INSTALL_DIR/preflight.sh" "$INSTALL_DIR/neko-home" "$INSTALL_DIR/logs" \
      || warn "preflight 没完全通过喵(可以稍后补: sudo sh preflight.sh)"
  else
    warn "  当前不是 root, 本喵先跳过 preflight(容器首次启动时会自己修属主)。"
  fi

  if ! docker compose up -d; then
    err "❌ docker compose up 失败了喵"
    cat <<EOF
  别急, 按顺序排查:
    1) cd $INSTALL_DIR && docker compose config  检查配置是否有误
    2) docker compose logs neko-main  查看容器日志定位原因
    3) 若提示权限,把用户加入 docker 组: sudo usermod -aG docker \$USER 并重新登录
${C_R}照上面的日志修好再跑一次, 本喵等你。${C_0}
EOF
    exit 1
  fi
  ok "✅ N.E.K.O. 服务已经启动了喵~"

  # 5) 看门狗 + CrowdSec
  if [ "$ENABLE_WATCHDOG" = 1 ]; then
    if [ "$(id -u)" = 0 ]; then
      sh "$INSTALL_DIR/watchdog/install-watchdog.sh" --host \
        && ok "✅ 看门狗装好了, 之后每 5 分钟会替你检查一次服务健康喵" \
        || warn "⚠ 看门狗没装上(可以稍后补: sudo sh $INSTALL_DIR/watchdog/install-watchdog.sh --host)"
    else
      warn "⚠ 不是 root, 本喵跳过看门狗(可稍后: sudo sh $INSTALL_DIR/watchdog/install-watchdog.sh --host)"
    fi
  else
    warn "  听你的, 跳过看门狗(以后想要就重跑本脚本)"
  fi

  if [ "$ENABLE_CROWDSEC" = 1 ]; then
    configure_crowdsec
  else
    warn "  听你的, 跳过 CrowdSec"
  fi

  # 使用说明
  ok "=========================================="
  ok "🎉 N.E.K.O. 部署完成喵~ 哼, 别忘了夸本喵一句。"
  ok "访问地址: http://服务器IP:$MAIN_PORT"
  printf "${C_G}想用域名访问的话, 参考官方文档配一下 SSL_DOMAIN 喵。${C_0}\n"
  if [ "$ENABLE_WATCHDOG" = 1 ]; then
    ok "看门狗已就位, 每 5 分钟检查一次服务健康"
  fi
  ok "管理目录: $INSTALL_DIR"
  ok "获取实例凭证:"
  ok "  docker compose -f $INSTALL_DIR/docker-compose.yml exec --user neko -w /app neko-main uv run python -m utils.instance_access"
  ok "改完配置重启: cd $INSTALL_DIR && docker compose up -d"
  ok "=========================================="
}

main "$@"
