#!/bin/bash
# N.E.K.O 容器健康看门狗（第一代架构 + 第二代健壮性合并版）
#
# 由 cron 每 5 分钟调用：*/5 * * * * root /www/wwwroot/NEKO/watchdog.sh
#
# 保留第一代原有能力（顺序不变）：
#   1) uid-align.sh  对齐挂载目录属主
#   2) time-sync.sh  校准容器时区/时间
#   3) 三项健康检查：容器内 nginx 主进程 / 应用端口 / 数据目录可写
#
# 合并第二代（官方 watchdog）的健壮性改进：
#   - 启动宽限期（默认 900s，按容器 StartedAt 计算；可用环境变量覆盖）
#   - 容器身份校验：优先校验 com.docker.compose.service=neko-main；
#     若设置了 org.neko.watchdog 标签且不等于 enabled，则放弃恢复权限
#   - 暂停 / 重启中 / 已停止的容器不动手
#   - 失败计数绑定「容器ID + 启动时间」，重建/重启后自动重来
#   - 每个容器ID最多连续 3 次自动重启，预算跨宽限期与 StartedAt 变化保留
#   - 预算耗尽只报告一次（不刷屏），需人工介入
#   - 重启前复核容器元数据未变化；重启用 -t 30、客户端总超时 120s
#   - 恢复后容器处于停止态时只报告、绝不自动 start（区分不了故障与人为停机）
#   - 状态文件原子写入；状态目录 root:root 0700
#   - /opt 无关：本机沿用 /www/wwwroot/NEKO/ 目录
#
# 维护暂停：touch /www/wwwroot/NEKO/state/disabled
# 恢复：    rm -f /www/wwwroot/NEKO/state/disabled
set -uo pipefail
umask 077
# cron 的 PATH 很窄，这里显式补齐；可用 NEKO_WATCHDOG_PATH 覆盖（便于回归测试）
export PATH=${NEKO_WATCHDOG_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}

BASE_DIR=${NEKO_WATCHDOG_BASE_DIR:-/www/wwwroot/NEKO}
CONTAINER=${NEKO_WATCHDOG_CONTAINER:-neko}
STATE_DIR="$BASE_DIR/state"
LOG="$BASE_DIR/logs/watchdog.log"
UID_ALIGN="$BASE_DIR/uid-align.sh"
TIME_SYNC="$BASE_DIR/time-sync.sh"
STARTUP_GRACE_SECONDS=${NEKO_WATCHDOG_STARTUP_GRACE_SECONDS:-900}
RW_PROBE='f=/app/N.E.K.O/config/.watchdog_probe_$$; touch "$f" && rm -f "$f"'
# 用 | 作分隔符，避免空标签被 read 折叠导致字段错位
METADATA_FORMAT='{{.Id}}|{{index .Config.Labels "org.neko.watchdog"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Running}}|{{.State.Paused}}|{{.State.Restarting}}|{{.State.StartedAt}}'

log() { printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
early_fail() { log "watchdog: $*"; printf 'watchdog: %s\n' "$*" >&2; exit 1; }

write_state() { # <文件名> <内容>
    local file="$1"; shift
    local tmp
    tmp=$(mktemp "$STATE_DIR/.${file}.XXXXXX") || return 1
    printf '%s\n' "$*" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STATE_DIR/$file" || { rm -f "$tmp"; return 1; }
}

# ---------- 前置校验 ----------
[ "$(id -u)" = 0 ] || { echo "watchdog: 必须以 root 运行" >&2; exit 1; }
[[ "$STARTUP_GRACE_SECONDS" =~ ^[0-9]{1,6}$ ]] || early_fail "启动宽限期非法：需 0-999999 的整数秒"
STARTUP_GRACE_SECONDS=$((10#$STARTUP_GRACE_SECONDS))
for dep in docker curl timeout flock; do
    command -v "$dep" >/dev/null 2>&1 || early_fail "缺少依赖 $dep"
done
[[ ! -L "$STATE_DIR" ]] || early_fail "状态目录是符号链接，拒绝使用"
mkdir -p "$STATE_DIR" || early_fail "无法创建状态目录"
[[ -d "$STATE_DIR" ]] || early_fail "状态目录不可用"
chmod 700 "$STATE_DIR" 2>/dev/null

# 维护暂停标志
[[ ! -e "$STATE_DIR/disabled" ]] || exit 0

# 并发保护：上一轮未结束则退出，避免 cron 重叠触发重启
exec 9>"$STATE_DIR/watchdog.lock" || early_fail "无法打开锁文件"
flock -n 9 || exit 0

# ---------- 第一代保留：属主对齐 + 时间校准（不阻断健康判定） ----------
[ -f "$UID_ALIGN" ] && bash "$UID_ALIGN" 2>/dev/null
[ -f "$TIME_SYNC" ] && bash "$TIME_SYNC" 2>/dev/null

# ---------- 容器身份 ----------
if ! metadata=$(timeout 10 docker inspect --type container -f "$METADATA_FORMAT" "$CONTAINER" 2>/dev/null); then
    # 区分「人为删除」与「daemon 查询失败」
    containers=$(timeout 10 docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.ID}}' 2>/dev/null) \
        || early_fail "无法查询容器；未尝试重启"
    [[ -z "$containers" ]] || early_fail "docker inspect 失败；未尝试重启"
    rm -f "$STATE_DIR/fail-count"
    exit 0
fi
IFS='|' read -r container_id enabled service running paused restarting started_at <<< "$metadata" \
    || early_fail "容器元数据格式异常"

# 标签显式 opt-out（未设置时沿用第一代的按容器名识别）
if [[ -n "$enabled" && "$enabled" != "enabled" ]]; then
    rm -f "$STATE_DIR/fail-count"
    exit 0
fi
# 服务名（compose 提供时）必须匹配，避免接管同名无关容器
if [[ -n "$service" && "$service" != "neko-main" ]]; then
    rm -f "$STATE_DIR/fail-count"
    exit 0
fi

# ---------- 停止态：只报告一次，绝不自动 start ----------
if [[ "$running" != true && "$paused" != true && "$restarting" != true && -e "$STATE_DIR/restart-count" ]]; then
    previous=$(cat "$STATE_DIR/restart-count" 2>/dev/null) || early_fail "无法读取重启预算"
    IFS=' ' read -r restart_id restart_count extra <<< "$previous"
    if [[ "$restart_id" == "$container_id" && "$restart_count" =~ ^[1-3]$ && -z "${extra:-}" ]]; then
        reported=
        [[ -e "$STATE_DIR/stopped-reported" ]] && reported=$(cat "$STATE_DIR/stopped-reported" 2>/dev/null)
        if [[ "$reported" != "$container_id $started_at" ]]; then
            write_state stopped-reported "$container_id $started_at" || early_fail "无法写入停止通知"
            log "容器在自动恢复后处于停止态，请人工检查启动失败或人为停机；不自动启动（维护请用 disabled）"
        fi
        exit 1
    fi
fi

# 暂停 / 重启中 / 未运行：交给 Docker 自身策略，不动手
if [[ "$running" != true || "$paused" == true || "$restarting" == true ]]; then
    rm -f "$STATE_DIR/fail-count"
    exit 0
fi
rm -f "$STATE_DIR/stopped-reported"

# ---------- 启动宽限期 ----------
started_epoch=$(date -d "$started_at" +%s) || early_fail "无法解析容器启动时间：$started_at"
now=$(date +%s)
if (( now - started_epoch < STARTUP_GRACE_SECONDS )); then
    rm -f "$STATE_DIR/fail-count"
    exit 0
fi

# ---------- 三项健康检查（第一代保留） ----------
nginx_ok=0; app_ok=0; rw_ok=0

timeout 10 docker exec "$container_id" sh -c \
    '[ -f /var/run/nginx.pid ] && kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null' \
    >/dev/null 2>&1 && nginx_ok=1

# 后端端口在容器内解析并校验，不硬编码
app_detail=
code=$(timeout 15 docker exec "$container_id" sh -c '
    port=${NEKO_MAIN_SERVER_PORT:-48911}
    case "$port" in ""|*[!0-9]*) exit 64 ;; esac
    { [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || exit 64
    exec curl --noproxy "*" -s --connect-timeout 5 --max-time 10 \
        -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/"
' 2>/dev/null); rc=$?
case "$code" in
    200|401) app_ok=1 ;;
    64)  app_detail="invalid backend port" ;;
    *)   app_detail="app probe exit $rc / http=${code:-none}" ;;
esac

timeout 10 docker exec -u neko "$container_id" sh -c "$RW_PROBE" >/dev/null 2>&1 && rw_ok=1

if [[ "$nginx_ok" = 1 && "$app_ok" = 1 && "$rw_ok" = 1 ]]; then
    rm -f "$STATE_DIR/fail-count" "$STATE_DIR/restart-count" "$STATE_DIR/exhaustion-reported"
    exit 0
fi

# ---------- 失败计数（绑定 容器ID + 启动时间） ----------
count=0
if [[ -e "$STATE_DIR/fail-count" ]]; then
    previous=$(cat "$STATE_DIR/fail-count" 2>/dev/null) || early_fail "无法读取失败计数"
    IFS=' ' read -r previous_id previous_count previous_start extra <<< "$previous"
    [[ "$previous_count" =~ ^[1-2]$ && -z "${extra:-}" ]] || early_fail "失败计数格式异常"
    if [[ "$previous_id" == "$container_id" && "$previous_start" == "$started_at" ]]; then
        count=$previous_count
    fi
fi
old_count=$count
count=$((count + 1))
(( count <= 2 )) || count=2
write_state fail-count "$container_id $count $started_at" || early_fail "无法写入失败计数"

if (( count != old_count )); then
    log "健康检查失败($count/2): nginx=$nginx_ok app=$app_ok rw=$rw_ok${app_detail:+ ($app_detail)}"
    # 保留第一代的根因线索（有界，避免刷屏；不记录响应正文）
    tail_keys=$(timeout 10 docker logs "$CONTAINER" --tail 30 2>/dev/null \
        | grep -E 'Permission denied|permission denied|ERROR|Error|error|Failed|failed|panic|FATAL|crash' \
        | tail -10)
    [[ -z "$tail_keys" ]] || { log "容器日志疑似根因："; printf '%s\n' "$tail_keys" >> "$LOG"; }
fi

if (( count >= 2 )); then
    [[ ! -e "$STATE_DIR/disabled" ]] || exit 0

    # 重启前复核容器未变化（防止计数期间被重建/人为停掉）
    current=$(timeout 10 docker inspect --type container -f "$METADATA_FORMAT" "$container_id" 2>/dev/null) \
        || early_fail "无法复核容器"
    [[ "$current" == "$metadata" ]] || { rm -f "$STATE_DIR/fail-count"; exit 0; }

    restart_count=0
    if [[ -e "$STATE_DIR/restart-count" ]]; then
        previous=$(cat "$STATE_DIR/restart-count" 2>/dev/null) || early_fail "无法读取重启预算"
        IFS=' ' read -r restart_id restart_count extra <<< "$previous"
        [[ "$restart_count" =~ ^[0-3]$ && -z "${extra:-}" ]] || early_fail "重启预算格式异常"
        [[ "$restart_id" == "$container_id" ]] || restart_count=0
    fi

    if (( restart_count >= 3 )); then
        reported=
        [[ -e "$STATE_DIR/exhaustion-reported" ]] && reported=$(cat "$STATE_DIR/exhaustion-reported" 2>/dev/null)
        if [[ "$reported" != "$container_id" ]]; then
            write_state exhaustion-reported "$container_id" || early_fail "无法写入耗尽通知"
            log "自动恢复已耗尽(3 次)，停止自动重启，请人工介入（docker logs neko / docker ps）"
        fi
        exit 1
    fi

    rm -f "$STATE_DIR/exhaustion-reported"
    write_state restart-count "$container_id $((restart_count + 1))" || early_fail "无法写入重启预算"

    if timeout 120 docker restart -t 30 "$container_id" >/dev/null 2>&1; then
        rm -f "$STATE_DIR/fail-count"
        log "已重启容器（第 $((restart_count + 1)) 次）"
    else
        # CLI 超时不代表 daemon 取消了重启，按新生命周期确认
        current=$(timeout 10 docker inspect --type container -f "$METADATA_FORMAT" "$container_id" 2>/dev/null) \
            || early_fail "无法确认重启结果；保留计数"
        IFS='|' read -r current_id current_enabled current_service current_running current_paused current_restarting current_start <<< "$current"
        if [[ "$current_id" == "$container_id" &&
              "$current_restarting" == true ]] \
           || [[ "$current_id" == "$container_id" &&
              "$current_running" == true && "$current_start" != "$started_at" ]]; then
            rm -f "$STATE_DIR/fail-count"
            log "重启命令超时，但观察到容器已重启；下轮重新计时"
        else
            early_fail "重启结果未确认；保留计数"
        fi
    fi
fi
exit 1
