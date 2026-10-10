#!/bin/bash
# N.E.K.O 容器健康看门狗：每 5 分钟由 cron 调用
# 健康判定（全部通过才算健康）：
#   1) uid-align.sh 先自动对齐挂载目录属主；time-sync.sh 校准容器时区/时间
#      （校准记录见 logs/uid-align.log、logs/time-sync.log）
#   2) 容器内 nginx 主进程存活
#   3) 应用端口 48911（容器内直连）返回 HTTP 200
#   4) 数据目录可写（以 neko 用户写挂载目录探测）
# 失败策略：第1次记录根因；连续第2次 docker restart；连续第3次（重启后仍失败）
#           停止自动重启并标记 CIRCLE 提示人工，避免无效重启循环。
BASE_DIR="${NEKO_WATCHDOG_BASE_DIR:-/www/wwwroot/NEKO}"
CONTAINER="${NEKO_WATCHDOG_CONTAINER:-neko}"
LOG="$BASE_DIR/logs/watchdog.log"
STAMP_FILE="/tmp/neko-watchdog-fail"
RW_PROBE='f=/app/N.E.K.O/config/.watchdog_probe_$$; touch "$f" && rm -f "$f"'

# 并发保护：上一次运行未结束则直接退出（避免 cron 重叠触发重启）
exec 9>/tmp/neko-watchdog.lock
flock -n 9 || exit 0

# 每次先做挂载目录 UID 对齐、容器时区/时间校准（脚本内部静默，不阻断健康判定）
bash "$BASE_DIR/uid-align.sh"
bash "$BASE_DIR/time-sync.sh"

now=$(date '+%Y-%m-%d %H:%M:%S')

# 健康检查1：容器内 nginx 主进程存活
nginx_ok=0
timeout 10 docker exec "$CONTAINER" sh -c '[ -f /var/run/nginx.pid ] && kill -0 "$(cat /var/run/nginx.pid)" 2>/dev/null' 2>/dev/null && nginx_ok=1

# 健康检查2：应用端口 48911 容器内直连返回 200
app_ok=0
code=$(timeout 10 docker exec "$CONTAINER" sh -c 'curl -s --max-time 5 -o /dev/null -w "%{http_code}" http://127.0.0.1:48911/' 2>/dev/null)
[ "$code" = "200" ] && app_ok=1

# 健康检查3：数据目录可写（以 neko 用户写挂载目录探测）
rw_ok=0
timeout 10 docker exec -u neko "$CONTAINER" sh -c "$RW_PROBE" 2>/dev/null && rw_ok=1

if [ "$nginx_ok" = "1" ] && [ "$app_ok" = "1" ] && [ "$rw_ok" = "1" ]; then
    # 健康：清除失败计数
    [ -f "$STAMP_FILE" ] && rm -f "$STAMP_FILE"
    exit 0
fi

# 失败：抓取最近日志中的疑似根因行（权限/错误/崩溃类）
tail_keys=$(timeout 10 docker logs "$CONTAINER" --tail 30 2>/dev/null | grep -E 'Permission denied|permission denied|ERROR|Error|error|Failed|failed|panic|FATAL|crash' | tail -10)

if [ ! -f "$STAMP_FILE" ]; then
    # 第1次失败：只记录，不动作
    echo "1" > "$STAMP_FILE"
    {
        echo "[$now] 健康检查失败(第1次)：nginx=$nginx_ok app=$app_ok rw=$rw_ok，下次仍失败将重启容器"
        [ -n "$tail_keys" ] && echo "[$now] 容器日志疑似根因：" && echo "$tail_keys"
    } >> "$LOG"
    exit 1
fi

count=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$STAMP_FILE"

if [ "$count" -le 2 ]; then
    # 连续第2次失败：重启容器（restart 保留容器层，恢复快）
    echo "[$now] 连续 2 次健康检查失败，重启容器" >> "$LOG"
    timeout 60 docker restart "$CONTAINER" >> "$LOG" 2>&1
else
    # 连续第3次及以后：重启后仍失败，停止自动重启，转人工
    {
        echo "[$now] CIRCLE：连续 ${count} 次健康检查失败，已停止自动重启，请人工介入（docker logs neko / docker ps）"
        [ -n "$tail_keys" ] && echo "[$now] 容器日志疑似根因：" && echo "$tail_keys"
    } >> "$LOG"
fi
exit 1
