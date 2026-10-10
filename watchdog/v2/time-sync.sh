#!/bin/bash
# N.E.K.O 容器时间/时区自动校准（由 watchdog 每 5 分钟调用）
# 背景：镜像内 /etc/localtime、/etc/timezone 为 Etc/UTC，仅靠 TZ 环境变量无法覆盖
#       不读取 TZ 的进程，导致容器内部分日志/文件时间按 UTC 记录，与实际时间相差 8 小时。
# 动作：
#   1) /etc/localtime 对齐宿主时区：优先比对文件内容指纹（兼容 compose 只读挂载），
#      内容不一致且可写时用符号链接修正，只读挂载下不一致则告警提示补挂载
#   2) /etc/timezone 内容对齐宿主时区（容器重建后会丢失，此处自动补写）
#   3) 校验容器内 TZ 环境变量与宿主时区是否一致（不一致仅告警，需改 compose 后重建容器）
#   4) 检测容器与宿主时钟偏差（共享内核时钟，偏差 >5s 仅告警，根因在宿主 NTP）
# 说明：容器不可用或读取失败时静默退出，不阻断 watchdog 健康判定。
BASE_DIR="${NEKO_WATCHDOG_BASE_DIR:-/www/wwwroot/NEKO}"
LOG="$BASE_DIR/logs/time-sync.log"
CONTAINER="${NEKO_WATCHDOG_CONTAINER:-neko}"
HOST_LOCALTIME="/etc/localtime"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# 宿主期望时区：优先 timedatectl，回退 readlink /etc/localtime
TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null)
[ -z "$TZ_NAME" ] && TZ_NAME=$(readlink -f "$HOST_LOCALTIME" 2>/dev/null | sed 's|.*/zoneinfo/||')
case "$TZ_NAME" in
    ''|*[!A-Za-z0-9_/+.-]*) exit 0 ;;   # 非法时区名，静默退出
esac

# 容器不可用则退出，交给 watchdog 健康判定处理
docker exec "$CONTAINER" true 2>/dev/null || exit 0

# 1) /etc/localtime 校准：内容指纹一致即视为已对齐（兼容只读 bind mount）
host_sum=$(md5sum "$HOST_LOCALTIME" 2>/dev/null | awk '{print $1}')
cont_sum=$(docker exec "$CONTAINER" md5sum /etc/localtime 2>/dev/null | awk '{print $1}')
if [ -n "$host_sum" ] && [ "$host_sum" != "$cont_sum" ]; then
    want="/usr/share/zoneinfo/$TZ_NAME"
    if ! docker exec "$CONTAINER" test -f "$want" 2>/dev/null; then
        log "SKIP 容器内缺少时区数据 $want，未校准"
    elif docker exec "$CONTAINER" sh -c "ln -sf '$want' /etc/localtime" 2>/dev/null; then
        log "ALIGN /etc/localtime -> $TZ_NAME"
    else
        log "WARN /etc/localtime 与宿主不一致且无法写入（可能为只读挂载），请在 compose 中挂载 /etc/localtime:ro"
    fi
fi

# 2) /etc/timezone 内容对齐（容器重建后会丢失，此处补写）
cont_tzfile=$(docker exec "$CONTAINER" cat /etc/timezone 2>/dev/null | tr -d '[:space:]')
if [ "$cont_tzfile" != "$TZ_NAME" ]; then
    if docker exec "$CONTAINER" sh -c "printf '%s\n' '$TZ_NAME' > /etc/timezone" 2>/dev/null; then
        log "ALIGN /etc/timezone: ${cont_tzfile:-空} -> $TZ_NAME"
    else
        log "WARN /etc/timezone 写入失败（当前 ${cont_tzfile:-空}），时区仍由 /etc/localtime 生效"
    fi
fi

# 3) TZ 环境变量一致性（容器 env 无法热改，不一致时仅提示）
tzenv=$(docker exec "$CONTAINER" printenv TZ 2>/dev/null)
case "$tzenv" in
    ""|"$TZ_NAME") : ;;                 # 未设置或一致：无需处理
    *) log "WARN 容器 TZ=$tzenv 与宿主时区 $TZ_NAME 不一致，建议在 compose 中修正后重建容器" ;;
esac

# 4) 时钟偏差检测（共享内核时钟，正常应为 0）
h=$(date +%s)
c=$(docker exec "$CONTAINER" date +%s 2>/dev/null)
case "$c" in
    ''|*[!0-9]*) log "SKIP 读取容器时间失败" ;;
    *)
        d=$((c - h)); [ "$d" -lt 0 ] && d=$((-d))
        if [ "$d" -gt 5 ]; then
            log "WARN 容器与宿主时钟偏差 ${d}s（容器内无法修正，请检查宿主 NTP：chrony/systemd-timesyncd）"
        fi
        ;;
esac

exit 0
