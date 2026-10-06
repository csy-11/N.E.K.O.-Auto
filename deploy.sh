#!/usr/bin/env bash
# ==============================================================================
# N.E.K.O. Auto Deploy —— 小白友好全自动部署脚本
# 从 GitHub 仓库拉取 docker 配置并完成交互式部署。
#
# 仓库:   csy-11/N.E.K.O.-Auto  分支: main(可覆盖)
#
# 用法:
#   A) 公有仓库一行:  bash <(curl -L https://raw.githubusercontent.com/csy-11/N.E.K.O.-Auto/main/deploy.sh)
#   B) 私有仓库带 token: GITHUB_TOKEN=ghp_xxx bash deploy.sh
#      先把脚本拉下来: curl -L -H "Authorization: Bearer $GITHUB_TOKEN" \
#         "https://api.github.com/repos/csy-11/N.E.K.O.-Auto/contents/deploy.sh?ref=main" \
#         | python3 -c "import sys,json;open('deploy.sh','w').write(__import__('base64').b64decode(json.load(sys.stdin)['content']).decode())"
#   C) 已在本机: sudo bash deploy.sh
#
# 依赖: bash, curl, docker, docker compose(V2)。缺少时会自动/引导安装。
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
  info " 欢迎使用 N.E.K.O. 自动部署脚本"
  info " 在正式安装前,先问你几个问题:"
  info "============================================================"
  printf "是否需要开启 ZRAM 内存压缩?(推荐 Y,能缓解低配机的内存压力)\n"
  read -r -p "  开启 ZRAM? [Y/n]: " ans; ENABLE_ZRAM=0
  case "${ans:-y}" in
    y|Y|yes|YES|'') ENABLE_ZRAM=1 ;;
    *) ENABLE_ZRAM=0 ;;
  esac

  printf "是否需要安装 CrowdSec 防爆破?(推荐 Y,可拦截 SSH 等暴力破解)\n"
  printf "  注意:CrowdSec 安装较慢,且只对已接入日志的服务生效\n"
  read -r -p "  安装 CrowdSec? [Y/n]: " ans; ENABLE_CROWDSEC=0
  case "${ans:-y}" in
    y|Y|yes|YES|'') ENABLE_CROWDSEC=1 ;;
    *) ENABLE_CROWDSEC=0 ;;
  esac

  printf "需要安装可选宿主机看门狗吗?(防服务卡死,每 5 分钟检查一次)\n"
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
${C_R}缺少必要组件,且本脚本无法自动安装(可能没有 sudo 权限)。${C_0}
请手动安装后重新运行本脚本:
  sudo apt-get update
  sudo apt-get install -y curl docker.io docker-compose-v2
  sudo usermod -aG docker \$USER   # 然后重新登录
${C_R}安装完成后: bash <(重新拉取脚本) 或 sudo bash deploy.sh${C_0}
EOF
  exit 1
}

# 安装 Docker(带失败引导)—— 采用官方 apt 源,更适合部署
install_docker() {
  local hdr="[2/5] 正在安装 Docker..."
  if check_cmd docker && docker compose version >/dev/null 2>&1; then
    ok "✅ Docker 已安装(含 Compose v2): $(docker --version)"
    return 0
  fi
  step "$hdr"
  if ! have_sudo; then cannot_continue; fi

  # 确保 curl 存在
  if ! check_cmd curl; then
    sudo apt-get update || { err "❌ apt update 失败,请检查网络或更换软件源(可编辑 /etc/apt/sources.list)"; exit 1; }
    sudo apt-get install -y curl || { err "❌ 安装 curl 失败,请检查网络或软件源"; exit 1; }
  fi

  if ! sudo apt-get update; then
    err "❌ apt update 失败"
    cat <<EOF
  提示:
    1) 检查网络是否连通:  ping -c 3 archive.ubuntu.com
    2) 软件源可能失效,可更换国内镜像源后重试:
       sudo sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
       sudo apt-get update
    3) 修复后再重新运行本脚本
EOF
    exit 1
  fi

  # 尝试通过官方脚本安装 Docker(能装到最新版 + compose plugin)
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null \
     && sudo sh /tmp/get-docker.sh 2>/dev/null; then
    ok "✅ Docker 安装完成(官方脚本): $(docker --version 2>/dev/null || echo unknown)"
  else
    warn "官方脚本安装失败,改用 apt 安装 docker.io..."
    if ! sudo apt-get install -y docker.io docker-compose-v2 2>/dev/null \
       && ! sudo apt-get install -y docker.io; then
      err "❌ Docker 安装失败"
      cat <<EOF
  提示:
    1) 检查网络: ping -c 3 download.docker.com
    2) 或仅安装基础包后重试: sudo apt-get install -y docker.io
    3) 把当前用户加入 docker 组再重新登录: sudo usermod -aG docker \$USER
${C_R}请修复后重新运行本脚本。${C_0}
EOF
      exit 1
    fi
    ok "✅ Docker 安装完成(apt)"
  fi
  sudo systemctl enable --now docker 2>/dev/null || warn "⚠ 未能自动启动 docker 服务,如有需要请手动执行 sudo systemctl start docker"
}

# -----------------------------------------------------------------------------
# ZRAM 配置(带失败引导)
# -----------------------------------------------------------------------------
configure_zram() {
  local hdr="[3/5] 正在配置 ZRAM 内存压缩..."
  step "$hdr"
  if ! have_sudo; then warn "⚠ 无 sudo,跳过 ZRAM(手动配置: sudo apt install zram-tools)" ; return 0; fi

  if ! sudo apt-get install -y zram-tools; then
    err "❌ zram-tools 安装失败"
    cat <<EOF
  提示:
    1) 检查网络 / 软件源(见上一步提示)
    2) 可手动安装后重试: sudo apt-get install -y zram-tools
    3) 实在装不上可跳过 ZRAM,仅靠系统 swap 兜底
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
  ok "✅ ZRAM 已配置(约物理内存 50%, 由本脚本写入 /etc/default/zramswap)"
}

# -----------------------------------------------------------------------------
# CrowdSec 配置(带失败引导)
# -----------------------------------------------------------------------------
configure_crowdsec() {
  local hdr="[5/5] 正在安装 CrowdSec 防爆破..."
  step "$hdr"
  if ! have_sudo; then warn "⚠ 无 sudo,跳过 CrowdSec(手动安装: curl -s https://install.crowdsec.net | sudo sh && sudo apt install -y crowdsec)" ; return 0; fi

  if ! curl -s https://install.crowdsec.net | sudo sh; then
    err "❌ CrowdSec 安装脚本执行失败"
    cat <<EOF
  提示:
    1) 检查网络能否访问 install.crowdsec.net
    2) 可跳过,不影响 N.E.K.O. 本体运行
EOF
    return 0
  fi
  if ! sudo apt-get install -y crowdsec crowdsec-firewall-bouncer-iptables; then
    err "❌ CrowdSec 包安装失败"
    warn "提示: 可尝试 sudo apt-get update 后重试; 或跳过(CrowdSec 可后续手动装)"
    return 0
  fi
  ok "✅ CrowdSec 已安装"
  warn "  提示: 若 Docker 使用 iptables 后端,需在 bouncer 配置中合并"
  warn "        iptables_chains: [INPUT, DOCKER-USER](具体见 CrowdSec 官方文档)"
}

# -----------------------------------------------------------------------------
# 从仓库拉取文件(API 优先, 回退 raw; 支持私有仓库 token)
# -----------------------------------------------------------------------------
auth_headers() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s\n' "Authorization: Bearer $GITHUB_TOKEN"
  fi
}

fetch_file() {
  local rel="$1" dest="$2" tmp
  tmp="$(mktemp)"
  local api_hdr=() h
  while IFS= read -r h; do [ -n "$h" ] && api_hdr+=(-H "$h"); done < <(auth_headers)

  if curl -fsSL "${api_hdr[@]}" "${API_BASE}/${rel}?ref=${BRANCH}" -o "$tmp" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1 \
       && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
      local dl
      dl="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("download_url",""))' "$tmp")"
      if [ -n "$dl" ] && curl -fsSL "${api_hdr[@]}" "$dl" -o "$tmp" 2>/dev/null; then
        mkdir -p "$(dirname -- "$dest")"; cp "$tmp" "$dest"; rm -f "$tmp"; return 0
      fi
    else
      mkdir -p "$(dirname -- "$dest")"; cp "$tmp" "$dest"; rm -f "$tmp"; return 0
    fi
  fi
  # 回退: raw.githubusercontent(仅公有)
  if [ -z "${GITHUB_TOKEN:-}" ] && curl -fsSL "${RAW_BASE}/${rel}" -o "$tmp" 2>/dev/null; then
    mkdir -p "$(dirname -- "$dest")"; cp "$tmp" "$dest"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
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
  info "选择核心 API 提供商:"
  printf '  qwen(阿里云, 推荐)  openai  glm(智谱, 免费)  step(阶跃)  free(免费版)\n'
  ask "提供商" "qwen"; CORE_API="$REPLY"
  case "$CORE_API" in
    qwen|openai|glm|step|free) ;;
    *) die "未知提供商: $CORE_API";;
  esac
  info "选择辅助 API 提供商(记忆/情感):"
  printf '  qwen openai glm step silicon(硅基) grok doubao(豆包)\n'
  ask "辅助提供商" "$CORE_API"; ASSIST_API="$REPLY"
}

collect_api_key() {
  if [ "$CORE_API" = "free" ]; then
    CORE_API_KEY="free-access"; info "免费版无需 API Key, 已使用 free-access。"
  else
    info "请输入 $CORE_API 的 API Key(必填, 不会显示在日志)。"
    read -r -s -p "API Key: " CORE_API_KEY; printf '\n'
    [ -z "$CORE_API_KEY" ] && die "API Key 不能为空。"
  fi
}

collect_https() {
  if confirm_yn "是否想用 HTTPS(需域名/证书)? [y/N]" n; then
    ask "SSL_DOMAIN(你的域名, 如 neko.example.com)" ""; SSL_DOMAIN="$REPLY"
    ask "NEKO_TRUSTED_HOSTS(同域名)" "$SSL_DOMAIN"; NEKO_TRUSTED_HOSTS="$REPLY"
    ask "NEKO_TRUSTED_ORIGINS(如 https://域名:48912)" "https://$SSL_DOMAIN:48912"; NEKO_TRUSTED_ORIGINS="$REPLY"
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
# 生成 .env
# -----------------------------------------------------------------------------
gen_env() {
  cat > "$INSTALL_DIR/.env" <<EOF
# 由 deploy.sh 自动生成; 之后可手动编辑
TZ=${TZ:-Asia/Shanghai}
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
  ok "✅ 已生成 .env ($INSTALL_DIR/.env)"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
main() {
  info "============================================================"
  info " N.E.K.O. Auto Deploy"
  info " 仓库: $REPO_OWNER/$REPO_NAME @ $BRANCH"
  info " 安装目录: $INSTALL_DIR"
  info "============================================================"

  # 1) 先问用户(CrowdSec / ZRAM / 看门狗),再开始装
  ask_preflight

  step "[1/5] 正在检测系统环境..."
  if [ "$(uname -s)" != "Linux" ]; then
    err "本脚本面向 Linux(Ubuntu 系)。当前系统: $(uname -s)"
    exit 1
  fi
  ok "✅ 系统检测通过: $(uname -srm) | $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  ok "✅ 已确认: ZRAM=$([ "$ENABLE_ZRAM" = 1 ] && echo 开 || echo 关), CrowdSec=$([ "$ENABLE_CROWDSEC" = 1 ] && echo 装 || echo 不装), 看门狗=$([ "$ENABLE_WATCHDOG" = 1 ] && echo 装 || echo 不装)"

  # 2) 安装 Docker
  install_docker

  # 3) ZRAM
  if [ "$ENABLE_ZRAM" = 1 ]; then
    configure_zram
  else
    warn "[3/5] 跳过 ZRAM(你选择不开启; 需要时可重跑本脚本或手动配置)"
  fi

  # 4) 拉取配置 + 交互 + 部署
  step "[4/5] 正在拉取配置并部署 N.E.K.O...."
  if ! confirm_yn "是否在当前安装目录拉取配置并继续?" y; then
    die "已取消。"
  fi
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  local missing=()
  for f in "${NEED_FILES[@]}"; do
    printf '  - %s ... ' "$f"
    if fetch_file "$f" "$INSTALL_DIR/$f"; then ok "OK"; else printf 'FAILED\n'; missing+=("$f"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "以下文件拉取失败: ${missing[*]}。若为私有仓库请设置 GITHUB_TOKEN 后重试。"
  fi

  info "  进行交互式配置..."
  api_provider
  collect_api_key
  collect_https
  gen_env

  mkdir -p "$INSTALL_DIR/neko-home" "$INSTALL_DIR/logs"
  if [ "$(id -u)" = 0 ]; then
    sh "$INSTALL_DIR/preflight.sh" "$INSTALL_DIR/neko-home" "$INSTALL_DIR/logs" \
      || warn "preflight 未完全通过(可稍后: sudo sh preflight.sh)"
  else
    warn "  当前非 root, 跳过 preflight(容器 entrypoint 首次启动时会调整属主)。"
  fi

  if ! docker compose up -d; then
    err "❌ docker compose up 失败"
    cat <<EOF
  提示:
    1) cd $INSTALL_DIR && docker compose config  检查配置是否有误
    2) docker compose logs neko-main  查看容器日志定位原因
    3) 若提示权限,把用户加入 docker 组: sudo usermod -aG docker \$USER 并重新登录
${C_R}请根据上方日志修复后重试。${C_0}
EOF
    exit 1
  fi
  ok "✅ N.E.K.O. 服务已启动"

  # 5) 看门狗 + CrowdSec
  if [ "$ENABLE_WATCHDOG" = 1 ]; then
    if [ "$(id -u)" = 0 ]; then
      sh "$INSTALL_DIR/watchdog/install-watchdog.sh" --host \
        && ok "✅ 看门狗已安装(每 5 分钟检查一次服务健康)" \
        || warn "⚠ 看门狗安装失败(可稍后: sudo sh $INSTALL_DIR/watchdog/install-watchdog.sh --host)"
    else
      warn "⚠ 非 root,跳过看门狗(可稍后: sudo sh $INSTALL_DIR/watchdog/install-watchdog.sh --host)"
    fi
  else
    warn "  跳过看门狗(你选择不安装; 需要时重跑本脚本或手动安装)"
  fi

  if [ "$ENABLE_CROWDSEC" = 1 ]; then
    configure_crowdsec
  else
    warn "  跳过 CrowdSec(你选择不安装)"
  fi

  # 使用说明
  ok "=========================================="
  ok "🎉 N.E.K.O. 部署完成!"
  ok "访问地址: http://服务器IP:$MAIN_PORT"
  printf "${C_G}如需域名访问,请参考官方文档配置 SSL_DOMAIN${C_0}\n"
  if [ "$ENABLE_WATCHDOG" = 1 ]; then
    ok "看门狗已安装,每 5 分钟检查一次服务健康"
  fi
  ok "管理目录: $INSTALL_DIR"
  ok "获取实例凭证:"
  ok "  docker compose -f $INSTALL_DIR/docker-compose.yml exec --user neko -w /app neko-main uv run python -m utils.instance_access"
  ok "修改配置后重启: cd $INSTALL_DIR && docker compose up -d"
  ok "=========================================="
}

main "$@"
