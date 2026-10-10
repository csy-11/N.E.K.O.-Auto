#!/bin/bash
# N.E.K.O 挂载目录 UID/GID 自动对齐 —— V2（完整版）
#
# 相比 V1 的改进：
#   1) 应用数据目录「完整遍历到每个条目」：V1 只 stat 顶层，存在盲区 ——
#      顶层属主正确、但迁移拷进来的子文件属主错误时不会被发现。
#      本版遍历到每个条目，只修复不符的，修完即止（幂等）。
#   2) **同时对齐 user 与 group**：任一不符即修复，避免只判 user 造成的漏网。
#   3) 大目录（playwright 等只读浏览器资产）仅对齐顶层：
#      内部文件全是 644/755，属主不影响读取，无需递归。
#   4) chown/find 统一包 ionice -c3 + nice -n19：只在空闲 I/O 类执行，不与应用争抢磁盘。
#   5) find 加 -xdev：不跨文件系统，避免误改嵌套挂载的宿主资源。
#
# 说明：全部已对齐时，find 只做一次遍历、不产生任何写操作。
# 由看门狗每 5 分钟调用；容器不可用时静默退出，不阻断健康判定。
# 可用 NEKO_WATCHDOG_BASE_DIR / NEKO_WATCHDOG_CONTAINER 覆盖路径与容器名。
set -uo pipefail

BASE_DIR="${NEKO_WATCHDOG_BASE_DIR:-/www/wwwroot/NEKO}"
CONTAINER="${NEKO_WATCHDOG_CONTAINER:-neko}"
LOG="$BASE_DIR/logs/uid-align.log"

# 完整遍历对齐：应用数据目录（应用会写入，属主必须正确）
FULL_DIRS=()
# 第一代布局
for d in "N.E.K.O" "N.E.K.O-anchor" "openfang"; do
    [ -d "$BASE_DIR/$d" ] && FULL_DIRS+=("$BASE_DIR/$d")
done
# 官方/仓库布局
[ -d "$BASE_DIR/neko-home" ] && FULL_DIRS+=("$BASE_DIR/neko-home")

# 仅顶层对齐：只读浏览器资产（内部 644/755，属主不影响读取）
TOP_DIRS=()
[ -d "$BASE_DIR/playwright" ] && TOP_DIRS+=("$BASE_DIR/playwright")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# 以最低优先级执行：空闲 I/O 类 + 最低 CPU 优先级，避免影响应用
lowio() {
    if command -v ionice >/dev/null 2>&1; then
        ionice -c3 nice -n 19 "$@"
    else
        nice -n 19 "$@"
    fi
}

# 容器不可用或查询失败时静默退出
UID_NEKO=$(docker exec "$CONTAINER" id -u neko 2>/dev/null)
GID_NEKO=$(docker exec "$CONTAINER" id -g neko 2>/dev/null)
case "$UID_NEKO" in
    ''|*[!0-9]*) exit 0 ;;
esac
case "$GID_NEKO" in
    ''|*[!0-9]*) exit 0 ;;
esac
[ "$UID_NEKO" -le 0 ] && exit 0
[ "$GID_NEKO" -le 0 ] && exit 0

TARGET="${UID_NEKO}:${GID_NEKO}"

# 1) 应用数据目录：完整遍历，只修复 user 或 group 不符的条目
for d in "${FULL_DIRS[@]}"; do
    [ -d "$d" ] || continue
    fixed=$(
        lowio find "$d" -xdev \( ! -user "$UID_NEKO" -o ! -group "$GID_NEKO" \) \
            -exec chown -h "$TARGET" {} + -print 2>/dev/null \
        | wc -l | tr -d ' '
    )
    [ -z "$fixed" ] && fixed=0
    if [ "$fixed" -gt 0 ]; then
        log "ALIGN $d: 修复 ${fixed} 个属主/属组不符的条目 -> $TARGET（完整遍历）"
    fi
done

# 2) 只读目录：仅顶层
for d in "${TOP_DIRS[@]}"; do
    [ -d "$d" ] || continue
    own=$(stat -c %u:%g "$d" 2>/dev/null)
    [ -z "$own" ] && continue
    [ "$own" = "$TARGET" ] && continue

    if lowio chown -h "$TARGET" "$d" 2>/dev/null; then
        log "ALIGN $d: 顶层 ${own} -> $TARGET（仅顶层，不递归）"
    else
        log "FAIL  $d: chown ${own} -> $TARGET 失败，请人工处理"
    fi
done

exit 0
