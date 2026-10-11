#!/usr/bin/env bash
# 自动开漂移修复 PR —— 把 upstream-drift.sh 落盘的上游版本照抄进本仓库, 建分支, 提交,
# 推上去, 然后开(或更新)一个 PR。
#
# 设计取舍:
#   · 分支名固定为 compat/upstream-drift, 所以同时**只会有一条 PR**, 反复跑是覆盖
#     更新而不是刷屏。每次都从当前 HEAD 重建分支, 相当于自动 rebase 到最新 main。
#   · 只做「照抄上游」这一件事, 不做任何适配/改写。是否需要连带改 install.sh 由人判断,
#     所以清单里明确列出来, 并且**绝不自动合并**。
#   · 上游把某个文件删了/改名了(exit 2)时不会走到这里 —— 那种照抄不了, 得人工。
#
# 环境变量:
#   MATERIALIZE_DIR  必需。upstream-drift.sh 写出的上游新版本目录(含 .meta/)
#   DRIFT_REPORT     默认 upstream-drift.md   漂移报告, 全文塞进 PR 描述
#   BRANCH           默认 compat/upstream-drift
#   BASE_BRANCH      默认 main
#   PR_TITLE_PREFIX  默认 "[兼容性] 同步上游 docker/ 变更"
#   BOT_NAME         默认 悠怡       自动提交显示的作者名
#   BOT_EMAIL        默认 youyi@neko-auto.invalid
#                    必须是「查不到 GitHub 账号」的邮箱, 否则会被账号名覆盖
#                    (详见下面 git config 那段的注释)
#   GH_TOKEN / GITHUB_TOKEN  开 PR 用(gh 自己认这两个)
#   PR_URL_FILE      可选。把最终的 PR URL 写一行到这个文件, 供 workflow 拿去
#                    写 summary / 抑制重复的 issue。
#
# 退出码: 0 = 已开/已更新 PR, 或本来就没变化; 非 0 = 出错(需要人看)
set -euo pipefail

MATERIALIZE_DIR="${MATERIALIZE_DIR:?需要 MATERIALIZE_DIR}"
DRIFT_REPORT="${DRIFT_REPORT:-upstream-drift.md}"
BRANCH="${BRANCH:-compat/upstream-drift}"
BASE_BRANCH="${BASE_BRANCH:-main}"
PR_TITLE_PREFIX="${PR_TITLE_PREFIX:-[兼容性] 同步上游 docker/ 变更}"
PR_URL_FILE="${PR_URL_FILE:-}"

meta="$MATERIALIZE_DIR/.meta"
[ -d "$meta" ] || { echo "找不到 $meta —— 请先用 MATERIALIZE_DIR 跑 upstream-drift.sh" >&2; exit 1; }
[ -f "$meta/files" ] || { echo "找不到 $meta/files" >&2; exit 1; }

mapfile -t files < <(grep -v '^[[:space:]]*$' "$meta/files" || true)
if [ "${#files[@]}" -eq 0 ]; then
    echo "没有内容漂移的文件, 无需开 PR。"
    exit 0
fi

up_commit="$(cat "$meta/upstream-commit" 2>/dev/null || echo unknown)"
up_ref="$(cat "$meta/upstream-ref" 2>/dev/null || echo main)"
up_short="${up_commit:0:10}"

echo "漂移文件 ${#files[@]} 个, 上游 commit ${up_short}"

# --- 建分支 + 照抄 -----------------------------------------------------------
# bot 身份。有两个坑, 别随手改回去:
#
#   1) GitHub **靠邮箱反查账号**, 然后拿账号名覆盖提交里写的名字 —— 所以光把
#      user.name 改成想要的显示名是没用的。用 github-actions[bot] 那个邮箱
#      (41898282+github-actions[bot]@users.noreply.github.com), 页面就显示
#      github-actions[bot]; 用 <任意名>@users.noreply.github.com 还可能撞上
#      一个真实用户, 把提交算到陌生人头上。
#   2) 只有「邮箱查不到任何 GitHub 账号」时, GitHub 才会老老实实显示
#      user.name。所以这里用一个 RFC 2606 保留的 .invalid 域 —— 它保证永远
#      解析不到, 既不会误伤别人, 也不会被当成真实邮箱发信。
#
# 效果: 提交显示为「悠怡」+ 默认灰色头像, 不归属任何账号(这很诚实, 它就是机器)。
# 注意: PR / issue / 评论的作者不受此影响 —— GitHub 对 GITHUB_TOKEN 创建的内容
#       强制署名 github-actions[bot], 那个改不了(要改得上 GitHub App)。
BOT_NAME="${BOT_NAME:-悠怡}"
BOT_EMAIL="${BOT_EMAIL:-youyi@neko-auto.invalid}"

git config user.name  "$BOT_NAME"
git config user.email "$BOT_EMAIL"

git checkout -B "$BRANCH"

for path in "${files[@]}"; do
    src="$MATERIALIZE_DIR/$path"
    [ -f "$src" ] || { echo "缺 $src" >&2; exit 1; }
    mkdir -p "$(dirname -- "$path")"
    cp -f "$src" "$path"
    echo "  覆盖 $path"
done

git add -A

if git diff --cached --quiet; then
    echo "工作区与本分支已有内容一致, 无需提交。"
    exit 0
fi

# 每文件增删行数, 用来在 PR 里给个概览
stat_md="$(git diff --cached --numstat | awk -F'\t' '
    { printf "| `%s` | +%s | -%s |\n", $3, $1, $2 }')"

git commit -q -m "chore(compat): 同步上游 docker/ 变更 (${up_short})" \
    -m "$(printf '照抄上游 Project-N-E-K-O/N.E.K.O@%s 的以下文件:\n\n%s\n' \
        "$up_ref" "$(printf '  - %s\n' "${files[@]}")")"

echo "已提交: $(git log -1 --format='%h %s')"

# 固定分支 + force: 保证同时只有一条 PR, 且总是基于最新 main
git push --force --quiet origin "$BRANCH"
echo "已推送分支 $BRANCH"

# --- PR 描述 -----------------------------------------------------------------
body="$(mktemp)"
{
    echo "## 这是什么"
    echo
    echo "每周兼容性检查发现本仓库有 **${#files[@]}** 个文件落后于上游"
    echo "\`Project-N-E-K-O/N.E.K.O@${up_ref}\`(commit \`${up_short}\`)。"
    echo
    echo "**这个 PR 只做了一件事:把它们照抄成上游版本。** 没有任何适配或改写。"
    echo
    echo "| 文件 | 新增 | 删除 |"
    echo "| --- | --- | --- |"
    printf '%s\n' "$stat_md"
    echo
    echo "> 由 CI 自动生成并 \`--force\` 推送,分支固定为 \`${BRANCH}\` ——"
    echo "> 所以同一个问题只会有一条 PR,重新运行是覆盖更新,不会刷屏。"
    echo "> **不会自动合并。**"
    echo
    echo "## 合并前请确认"
    echo
    echo "- [ ] \`install.sh\` 的 \`NEED_FILES\` 是否需要跟着增减(上游新增/删除文件时)"
    echo "- [ ] \`docker-compose.yml\` / \`entrypoint.sh\` 是否引入新的**必填**挂载或环境变量,"
    echo "      需要同步改 \`install.sh\` 的交互流程(否则用户装机时会踩空)"
    echo "- [ ] 有没有**破坏性**变更需要写进 README 的升级说明"
    echo
    echo "有意偏离上游的文件(\`README.md\` \`watchdog/README.md\` \`install.sh\` \`watchdog/v{1,2}/*\`)"
    echo "**不在**本次覆盖范围内。"
    echo
    if [ -f "$DRIFT_REPORT" ]; then
        echo "## 详细报告"
        echo
        echo "<details><summary>展开(含逐文件 diff)</summary>"
        echo
        cat "$DRIFT_REPORT"
        echo
        echo "</details>"
    fi
    echo
    echo "<sub>由 <code>.github/workflows/weekly-compat.yml</code> 的 <code>auto-pr</code> job 生成。</sub>"
} >"$body"

# --- 开 or 更新 ---------------------------------------------------------------
num="$(gh pr list --head "$BRANCH" --state open --limit 1 --json number \
        --jq '.[0].number // empty')"

title="${PR_TITLE_PREFIX} (${up_short})"
url=""

if [ -n "$num" ]; then
    url="$(gh pr edit "$num" --title "$title" --body-file "$body" >/dev/null && \
           gh pr view "$num" --json url --jq .url)"
    echo "已更新 PR #${num}"
else
    # 仓库若没勾选 Settings → Actions → General →
    # 「Allow GitHub Actions to create and approve pull requests」,
    # GITHUB_TOKEN 是开不了 PR 的(即使 workflow 声明了 pull-requests: write)。
    # 这种情况不该把 CI 弄红 —— 退化成「给一条 compare 链接」, 同时让 report job
    # 去开 issue(那里带着完整漂移报告), 用户照样有路子走。
    if err="$(gh pr create --base "$BASE_BRANCH" --head "$BRANCH" \
                --title "$title" --body-file "$body" 2>&1)"; then
        url="$err"
        echo "$url"
    else
        printf '%s\n' "$err" >&2
        compare="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-owner/repo}/compare/${BASE_BRANCH}...${BRANCH}?expand=1"
        echo
        echo "::warning::自动开 PR 失败, 已退化成人工点击。分支已经推好了, 点这里就能建 PR: ${compare}"
        if [[ "$err" == *"not permitted to create"* ]]; then
            echo "::warning::原因是仓库没开启「Allow GitHub Actions to create and approve pull requests」"
            echo "::warning::(Settings → Actions → General → Workflow permissions)。开启后这个 job 就能全自动开 PR。"
        fi
        echo
        echo "分支 \`${BRANCH}\` 已推送, 待办仍由 issue 承接(见汇总 job)。"
    fi
fi
rm -f "$body"

if [ -n "$PR_URL_FILE" ] && [ -n "$url" ]; then
    printf '%s\n' "$url" >"$PR_URL_FILE"
fi
