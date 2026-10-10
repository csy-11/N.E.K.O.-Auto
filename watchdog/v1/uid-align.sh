#!/bin/bash
# N.E.K.O 挂载目录 UID 自动对齐 —— V1（轻量版）
#
# 策略：只检查**顶层目录**属主；不一致才整体 `chown -R`。
#   ✅ 简单直接、开销极低（稳态只需一次 stat）
#   ⚠️ 有盲区：顶层属主正确、但内部子文件属主错误时**不会被发现**
#      （例如往已有目录里拷进一批新文件的情况）
#
# 适用：整目录迁移/替换（顶层属主会跟着变）的场景。
# 需要覆盖盲区请用 V2。
#
# 由看门狗每 5 分钟调用；容器不可用时静默退出，不阻断健康判定。
# 可用 NEKO_WATCHDOG_BASE_DIR / NEKO_WATCHDOG_CONTAINER 覆盖路径与容器名。
set -uo pipefail

BASE_DIR="${NEKO_WATCHDOG_BASE_DIR:-/www/wwwroot/NEKO}"
CONTAINER="${NEKO_WATCHDOG_CONTAINER:-neko}"
LOG="$BASE_DIR/logs/uid-align.log"

# 目标目录：自动适配两种部署布局
DIRS=()
# 第一代布局
for d in "N.E.K.O" "N.E.K.O-anchor" "openfang" "playwright"; do
    [ -d "$BASE_DIR/$d" ] && DIRS+=("$BASE_DIR/$d")
done
# 官方/仓库布局
[ -d "$BASE_DIR/neko-home" ] && DIRS+=("$BASE_DIR/neko-home")

UID_NEKO=$(docker exec "$CONTAINER" id -u neko 2>/dev/null)
case "$UID_NEKO" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ "$UID_NEKO" -le 0 ] && exit 0

for d in "${DIRS[@]}"; do
    own=$(stat -c %u "$d" 2>/dev/null)
    [ -z "$own" ] && continue
    [ "$own" = "$UID_NEKO" ] && continue

    if chown -R "${UID_NEKO}:${UID_NEKO}" "$d" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALIGN $d: ${own} -> ${UID_NEKO}（容器 neko UID）" >> "$LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAIL  $d: chown ${own} -> ${UID_NEKO} 失败，请人工处理" >> "$LOG"
    fi
done

exit 0
