#!/usr/bin/env bash
# ==============================================================================
# N.E.K.O. Auto Deploy —— 全自动部署脚本
# 从 GitHub 仓库拉取 docker 配置并完成交互式部署。
#
# 仓库:   csy-11/N.E.K.O.-Auto  分支: main(可覆盖)
#
# 两种用法:
#   方式 A) 直接一行(拉脚本并跨目录执行):
#     bash <(curl -L https://raw.githubusercontent.com/csy-11/N.E.K.O.-Auto/main/deploy.sh)
#     私有仓库则:
#     GITHUB_TOKEN=ghp_xxx bash <(curl -L -H "Authorization: Bearer $GITHUB_TOKEN" ...)
#
#   方式 B) 先拉取本脚本再执行(会校验所有依赖文件是否拉全):
#     curl -L -o deploy.sh https://raw.githubusercontent.com/csy-11/N.E.K.O.-Auto/main/deploy.sh
#     sudo bash deploy.sh
#
# 依赖: bash, curl, docker, docker compose(V2)。缺少时会提示安装命令。
# 可选: sudo(多数步骤需要 root 权限)。
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

SCRIPT_URL_RAW="${RAW_BASE}/deploy.sh"

# 安装目标目录(放 compose/.env/neko-home/logs 的地方)
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/neko-deploy}"

# 颜色(非 tty 自动关闭)
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

# -----------------------------------------------------------------------------
# 帮助
# -----------------------------------------------------------------------------
usage() {
  sed -n '2,30s/^# \{0,1\}//p' "$0"
  exit 0
}
case "${1:-}" in
  -h|--help) usage ;;
esac

# -----------------------------------------------------------------------------
# 依赖检查
# -----------------------------------------------------------------------------
check_cmd() { command -v "$1" >/dev/null 2>&1; }

check_deps() {
  local missing=()
  for c in bash curl; do
    check_cmd "$c" || missing+=("$c")
  done
  check_cmd docker || missing+=(docker)
  if check_cmd docker; then
    docker compose version >/dev/null 2>&1 || {
      warn "检测到 docker 但缺少 compose v2。"
      warn "  安装:  sudo apt-get install docker-compose-v2  或  用官方 plugin。"
      missing+=(docker-compose-plugin)
    }
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    cat <<EOF
${C_R}缺少必要组件:${C_0} ${missing[*]}
常见安装(Ubuntu):
  sudo apt-get update
  sudo apt-get install -y curl docker.io docker-compose-v2
  或将当前用户加入 docker 组:  sudo usermod -aG docker \$USER && 重新登录
${C_R}安装完成后重新运行本脚本。${C_0}
EOF
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# 从仓库拉取文件(API 优先, 回退 raw; 支持私有仓库 token)
# -----------------------------------------------------------------------------
auth_headers() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    printf '%s\n' "Authorization: Bearer $GITHUB_TOKEN"
  fi
}

# 通过 API contents(私有/公有都可)取某个文件的下载地址, 或直接取公网 raw
fetch_file() {
  # $1 = 仓库内相对路径  $2 = 本地目标路径
  local rel="$1" dest="$2"
  local tmp
  tmp="$(mktemp)"
  local api_hdr=() hdr
  for h in $(auth_headers); do api_hdr+=(-H "$h"); done

  local ok=0
  # 尝试 API(带 token 时可用; 无 token 对公有仓库也可用)
  if curl -fsSL "${api_hdr[@]}" \
      "${API_BASE}/${rel}?ref=${BRANCH}" -o "$tmp" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1 &&
       python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
      : # 已是 JSON(contents 元数据)
    else
      mkdir -p "$(dirname -- "$dest")"
      cp "$tmp" "$dest"; rm -f "$tmp"; return 0
    fi
  fi
  # 回退: raw.githubusercontent(仅公有)
  if [ -z "${GITHUB_TOKEN:-}" ] && curl -fsSL "${RAW_BASE}/${rel}" -o "$tmp" 2>/dev/null; then
    mkdir -p "$(dirname -- "$dest")"
    cp "$tmp" "$dest"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  return 1
}

# -----------------------------------------------------------------------------
# 交互式参数采集
# -----------------------------------------------------------------------------
confirm_yn() { # $1=提示 $2=默认(默认 y)
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

ask() { # $1=提示 $2=默认值 -> 输出 $REPLY
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
    CORE_API_KEY="free-access"
    info "免费版无需 API Key, 已使用 free-access。"
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

ask_watchdog() {
  if [ "$(id -u)" = 0 ] && confirm_yn "是否安装可选宿主机看门狗(防服务卡死)? [y/N]" n; then
    INSTALL_WATCHDOG=1
  else
    INSTALL_WATCHDOG=0
  fi
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
  ok "已生成 .env ($INSTALL_DIR/.env)"
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

  check_deps

  if ! confirm_yn "是否继续在整个安装目录拉取配置并部署?" y; then
    die "已取消。"
  fi

  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  info "[1/5] 从仓库拉取配置..."
  local missing=()
  for f in "${NEED_FILES[@]}"; do
    printf '  - %s ... ' "$f"
    if fetch_file "$f" "$INSTALL_DIR/$f"; then ok "OK"; else printf 'FAILED\n'; missing+=("$f"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "以下文件拉取失败: ${missing[*]}。若为私有仓库请设置 GITHUB_TOKEN 后重试。"
  fi

  info "[2/5] 交互式配置..."
  api_provider
  collect_api_key
  collect_https
  gen_env

  info "[3/5] 初始化数据目录并执行 preflight..."
  mkdir -p "$INSTALL_DIR/neko-home" "$INSTALL_DIR/logs"
  if [ "$(id -u)" = 0 ]; then
    # preflight 需要 root 才能 chown; 非 root 只能跳过(容器启动时 entrypoint 会修)
    sh "$INSTALL_DIR/preflight.sh" "$INSTALL_DIR/neko-home" "$INSTALL_DIR/logs" \
      || warn "preflight 未完全通过(可在有 sudo 时重跑: sudo sh preflight.sh)"
  else
    warn "当前非 root, 跳过 preflight(容器 entrypoint 会在首次启动时调整属主)。"
  fi

  info "[4/5] 启动服务..."
  docker compose up -d

  info "[5/5] 看门狗..."
  ask_watchdog
  if [ "$INSTALL_WATCHDOG" = "1" ]; then
    sh "$INSTALL_DIR/watchdog/install-watchdog.sh" --host || warn "看门狗安装失败(稍后可手动重试)"
  fi

  ok "============================================================"
  ok " 部署完成!"
  ok " 访问: http://<服务器IP>:$MAIN_PORT"
  ok " 管理目录: $INSTALL_DIR"
  ok " 修改配置后: cd $INSTALL_DIR && docker compose up -d"
  ok " 获取实例凭证:"
  ok "   docker compose -f $INSTALL_DIR/docker-compose.yml exec --user neko -w /app neko-main uv run python -m utils.instance_access"
  ok "============================================================"
}

main "$@"
