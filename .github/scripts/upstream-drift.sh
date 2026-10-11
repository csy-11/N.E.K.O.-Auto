#!/usr/bin/env bash
# 上游漂移检测 —— 本仓库里有一批文件是「逐字镜像」自上游 docker/ 目录的。
# 上游一旦改了 entrypoint / compose / 环境变量模板, 我们这份镜像就悄悄过时了,
# 而 install.sh 恰恰是把这些文件直接投喂给用户的。所以每周比一次。
#
# 实现要点:
#   不碰 GitHub API, 也不用 token —— 只做一次浅层「无 blob」fetch, 拿到的 tree
#   里就带着全部 blob SHA。于是 13 个文件全是本地比较, 没有 60 次/小时的匿名
#   限流, 也不会因为 GITHUB_TOKEN 是「仅本仓库」的安装令牌而 404。
#   只有发现不一致时才去 cat-file 取上游正文, 生成一段 diff 摘要方便定位。
#
# 注意: 比对的是「已提交内容」(LOCAL_REF=HEAD), 不是工作区。
#       本地改了还没 commit 时显示漂移是正常的, CI 里跑的永远是提交。
#
# 环境变量:
#   UPSTREAM_REPO  默认 Project-N-E-K-O/N.E.K.O
#   UPSTREAM_REF   默认 main
#   UPSTREAM_DIR   默认 docker        上游存放这些文件的子目录
#   LOCAL_REF      默认 HEAD          本地取 blob SHA 用的 git 引用
#   REPORT         默认 upstream-drift.md
#   MATERIALIZE_DIR 可选。设置后, 把每个「已漂移」文件的上游版本落到该目录的
#                   同名路径下, 并在 $MATERIALIZE_DIR/.meta/ 写三样东西:
#                     upstream-commit  上游 commit SHA
#                     upstream-ref     上游分支名
#                     files            漂移文件清单(每行一个本地路径)
#                   自动开 PR 的脚本靠这个目录工作, 不需要再 fetch 一次。
#
# 退出码(自动开 PR 的 job 靠它区分「能自动修」和「得人工看」):
#   0 = 无漂移
#   1 = 只有内容漂移      → 照抄上游即可, 可以自动开 PR
#   2 = 上游没有这个文件了 → 路径可能变了, 必须人工判断
#   3 = 拉不到上游        → 无法判定
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-Project-N-E-K-O/N.E.K.O}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
UPSTREAM_DIR="${UPSTREAM_DIR:-docker}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
LOCAL_REF="${LOCAL_REF:-HEAD}"
REPORT="${REPORT:-upstream-drift.md}"
MATERIALIZE_DIR="${MATERIALIZE_DIR:-}"

# 必须与上游逐字一致的文件。本地路径 == 上游 <UPSTREAM_DIR>/<路径>。
# 加新镜像文件时, 同时看看 install.sh 的 NEED_FILES 要不要跟着加。
MIRRORED=(
    CONFIG_REFERENCE.md
    Dockerfile
    Dockerfile.full
    README_Docker.md
    config/core_config.json.example
    docker-compose.yml
    entrypoint.sh
    env.template
    preflight.sh
    test-preflight.sh
    watchdog/install-watchdog.sh
    watchdog/test-watchdog.sh
    watchdog/watchdog.sh
)

# 有意偏离上游、因此不参与比对的文件(改了文案或加了本仓库独有逻辑):
#   watchdog/README.md                     重写成 YUI 语气 + V1/V2 选型说明(上游是简短英文)
#   README.md  install.sh  deploy.sh       本仓库独有, 上游没有
#   watchdog/v1/*  watchdog/v2/*           本仓库独有(上游只有单版本 watchdog)
#   .github/*                              本仓库独有
INTENTIONAL=(
    "watchdog/README.md|改写为 YUI 语气与 V1/V2 选型说明"
)

local_blob() { # local_blob <path> -> blob SHA(取已提交内容, 与上游同口径)
    git rev-parse --verify -q "${LOCAL_REF}:$1" 2>/dev/null && return 0
    # 非 git 检出(比如源码压缩包)时退化到工作区内容
    [ -f "$1" ] || return 1
    git hash-object -- "$1" 2>/dev/null
}

# --- 取上游 ------------------------------------------------------------------
fetch_dir="$(mktemp -d)"
trap 'rm -rf "$fetch_dir"' EXIT

echo "拉取上游 ${UPSTREAM_REPO}@${UPSTREAM_REF} (shallow, blob:none)..." >&2
if ! git -C "$fetch_dir" init -q 2>/dev/null \
    || ! git -C "$fetch_dir" remote add origin "$UPSTREAM_URL" 2>/dev/null \
    || ! git -C "$fetch_dir" fetch -q --depth 1 --no-tags --filter=blob:none \
            origin "$UPSTREAM_REF" 2>/dev/null; then
    {
        echo "## 上游漂移检测"
        echo
        echo "🚫 **拉不到上游仓库** \`${UPSTREAM_REPO}@${UPSTREAM_REF}\`(\`${UPSTREAM_URL}\`)。"
        echo
        echo "可能是网络/代理问题, 也可能是上游改名或转私有。"
        echo "本次无法判定漂移 —— 不能当作通过。"
    } >"$REPORT"
    cat "$REPORT"
    echo "FETCH_FAILED: ${UPSTREAM_REPO}@${UPSTREAM_REF}" >&2
    exit 3
fi
up_commit="$(git -C "$fetch_dir" rev-parse FETCH_HEAD)"
up_date="$(git -C "$fetch_dir" log -1 --format=%cI FETCH_HEAD 2>/dev/null || echo unknown)"

drift=0
missing=0
rows=()
details=()

for path in "${MIRRORED[@]}"; do
    if ! up_sha="$(git -C "$fetch_dir" rev-parse --verify -q "${up_commit}:${UPSTREAM_DIR}/${path}" 2>/dev/null)" \
       || [ -z "$up_sha" ]; then
        rows+=("| \`${path}\` | 🚫 上游已无此文件(\`${UPSTREAM_DIR}/${path}\`) |")
        missing=$((missing + 1))
        continue
    fi

    if ! lo_sha="$(local_blob "$path")" || [ -z "$lo_sha" ]; then
        rows+=("| \`${path}\` | 🚫 本地缺失 |")
        missing=$((missing + 1))
        continue
    fi

    if [ "$up_sha" = "$lo_sha" ]; then
        rows+=("| \`${path}\` | ✅ 一致 |")
        continue
    fi

    # 大小与 diff 都取「已提交内容」(LOCAL_REF), 与漂移判定同一口径,
    # 免得出现「本地 47528B → 上游 47528B」这种看着自相矛盾的输出。
    up_size="$(git -C "$fetch_dir" cat-file -s "$up_sha" 2>/dev/null || echo '?')"
    lo_size="$(git cat-file -s "$lo_sha" 2>/dev/null || wc -c <"$path" | tr -d ' ')"
    rows+=("| \`${path}\` | ⚠️ **已漂移** (本地 ${lo_size}B → 上游 ${up_size}B) |")
    drift=$((drift + 1))

    # 只有不一致时才取正文, 给一段可读的 diff 摘要
    tmp_up="$(mktemp)"
    tmp_lo="$(mktemp)"
    if git -C "$fetch_dir" cat-file blob "$up_sha" >"$tmp_up" 2>/dev/null \
       && git cat-file blob "$lo_sha" >"$tmp_lo" 2>/dev/null; then
        body="$(diff -u --label "local/${path}" --label "upstream/${UPSTREAM_DIR}/${path}" \
            "$tmp_lo" "$tmp_up" 2>/dev/null | tail -n +3 | head -60 || true)"
        [ -n "$body" ] && details+=("### \`${path}\`" "" '```diff' "$body" '```' "")
    fi
    # 顺手把上游版本落盘, 供 open-drift-pr.sh 直接照抄(别再 fetch 一次)
    if [ -n "$MATERIALIZE_DIR" ]; then
        mkdir -p "$MATERIALIZE_DIR/$(dirname -- "$path")"
        cp -f "$tmp_up" "$MATERIALIZE_DIR/$path"
    fi
    rm -f "$tmp_up" "$tmp_lo"
done

# --- 落盘元信息(自动开 PR 用) -----------------------------------------------
if [ -n "$MATERIALIZE_DIR" ]; then
    mkdir -p "$MATERIALIZE_DIR/.meta"
    printf '%s\n' "$up_commit" >"$MATERIALIZE_DIR/.meta/upstream-commit"
    printf '%s\n' "$UPSTREAM_REF" >"$MATERIALIZE_DIR/.meta/upstream-ref"
    # 只列「内容漂移」的, 不列上游已删除的 —— 那种没法照抄, 得人工
    for path in "${MIRRORED[@]}"; do
        [ -f "$MATERIALIZE_DIR/$path" ] && printf '%s\n' "$path"
    done >"$MATERIALIZE_DIR/.meta/files"
fi

# --- 报告 --------------------------------------------------------------------
{
    echo "## 上游漂移检测"
    echo
    echo "上游 \`${UPSTREAM_REPO}@${UPSTREAM_REF}\` = \`${up_commit:0:10}\` (${up_date})"
    echo "的 \`${UPSTREAM_DIR}/\` 对比本地 \`${LOCAL_REF}\`"
    echo
    echo "| 文件 | 状态 |"
    echo "| --- | --- |"
    printf '%s\n' "${rows[@]}"
    echo
    if [ "$drift" -eq 0 ] && [ "$missing" -eq 0 ]; then
        echo "**结论: 无漂移**, ${#MIRRORED[@]} 个镜像文件与上游完全一致。"
    else
        echo "**结论: 漂移 ${drift} 个, 取不到 ${missing} 个。**"
        echo
        echo "处理方式: 用上游内容覆盖本地同名文件, 然后确认 \`install.sh\` 的"
        echo "\`NEED_FILES\` 是否需要同步增减。\`watchdog/README.md\` 与 \`README.md\`"
        echo "是本仓库有意改写的, 不要覆盖。"
    fi
    echo
    echo "<details><summary>有意偏离上游的文件(不参与比对)</summary>"
    echo
    for it in "${INTENTIONAL[@]}"; do
        echo "- \`${it%%|*}\` —— ${it#*|}"
    done
    echo "- 本仓库独有: \`README.md\` \`install.sh\` \`deploy.sh\` \`watchdog/v{1,2}/*\` \`.github/*\`"
    echo
    echo "</details>"
    if [ "${#details[@]}" -gt 0 ]; then
        echo
        echo "### 差异详情"
        echo
        printf '%s\n' "${details[@]}"
    fi
} >"$REPORT"

cat "$REPORT"

if [ "$missing" -gt 0 ]; then
    echo "DRIFT_UNRESOLVABLE: drift=${drift} missing=${missing} (上游路径变了, 需人工)" >&2
    exit 2
fi
if [ "$drift" -gt 0 ]; then
    echo "DRIFT_DETECTED: drift=${drift}" >&2
    exit 1
fi
exit 0
