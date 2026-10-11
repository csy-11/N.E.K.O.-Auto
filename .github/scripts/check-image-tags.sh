#!/usr/bin/env bash
# 镜像可用性检查 —— install.sh / docker-compose.yml 默认拉的都是 GHCR 上的
#   ghcr.io/project-n-e-k-o/n.e.k.o:{latest,latest-full}
# 上游要是重命名或删了 tag, 安装脚本会在用户机器上「拉不到镜像」, 但本仓库毫无感知。
# 所以每周匿名问一次 registry。
#
# 分两档:
#   · 官方 GHCR tag  → 必须是 200, 否则判失败(这是硬依赖)
#   · 国内加速镜像源 → 只报告可达性。GitHub 的 runner 在海外, 加速源不通★不代表★
#                     国内用户拉不到, 所以这里永远不判失败, 只写进报告。
#
# 环境变量:
#   IMAGE_REPO  默认 project-n-e-k-o/n.e.k.o
#   TAGS        空格分隔, 默认 "latest latest-full"
#   MIRRORS     空格分隔的加速源主机名
#   REPORT      默认 image-tags.md
#
# 退出码: 0 = 官方 tag 全部可用; 1 = 有 tag 缺失/取不到 token
set -euo pipefail

IMAGE_REPO="${IMAGE_REPO:-project-n-e-k-o/n.e.k.o}"
TAGS="${TAGS:-latest latest-full}"
MIRRORS="${MIRRORS:-docker.gh-proxy.org docker.m.daocloud.io docker.1ms.run ghcr.nju.edu.cn}"
REPORT="${REPORT:-image-tags.md}"

MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json'

fail_n=0
tag_rows=()
detail=()

# --- 1. 官方 GHCR: 匿名 token + manifest HEAD -------------------------------
token="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 \
    "https://ghcr.io/token?scope=repository:${IMAGE_REPO}:pull&service=ghcr.io" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"

if [ -z "$token" ]; then
    echo "无法从 ghcr.io 取到匿名 pull token" >&2
    {
        echo "## 镜像可用性"
        echo
        echo "🚫 **取不到 ghcr.io 匿名 pull token**, 无法检查镜像 tag(可能是网络或 registry 故障)。"
    } >"$REPORT"
    cat "$REPORT"
    exit 1
fi

hdrs="$(mktemp)"
trap 'rm -f "$hdrs"' EXIT

for tag in $TAGS; do
    code="$(curl -s -o /dev/null -D "$hdrs" -w '%{http_code}' \
        --connect-timeout 10 --max-time 45 --retry 2 --retry-delay 2 \
        -I \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: ${MANIFEST_ACCEPT}" \
        "https://ghcr.io/v2/${IMAGE_REPO}/manifests/${tag}" || echo 000)"
    digest="$(tr -d '\r' <"$hdrs" | awk 'tolower($1)=="docker-content-digest:"{print $2}' | tail -1)"

    case "$code" in
        200)
            tag_rows+=("| \`${tag}\` | ✅ 可用 | \`${digest:-n/a}\` |")
            ;;
        404)
            tag_rows+=("| \`${tag}\` | ❌ **不存在** | — |")
            detail+=("- \`${tag}\` 返回 404: 上游可能改了 tag 命名。" \
                "  检查 install.sh 的 \`NEKO_IMAGE_PATH\` / compose 的默认 tag。")
            fail_n=$((fail_n + 1))
            ;;
        *)
            tag_rows+=("| \`${tag}\` | ⚠️ HTTP ${code} | — |")
            fail_n=$((fail_n + 1))
            ;;
    esac
done

# --- 2. 国内加速源: 仅报告 --------------------------------------------------
mirror_rows=()
for host in $MIRRORS; do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 8 --max-time 20 \
        "https://${host}/v2/" || echo 000)"
    # registry 对未鉴权请求返回 401 是正常的"活着"信号, 301/302 也算通
    case "$code" in
        200|301|302|401|403) mirror_rows+=("| \`${host}\` | ✅ 可达 (HTTP ${code}) |") ;;
        *) mirror_rows+=("| \`${host}\` | ⚪ 探测失败 (HTTP ${code}) |") ;;
    esac
done

# --- 3. 报告 ----------------------------------------------------------------
{
    echo "## 镜像可用性"
    echo
    echo "官方 registry: \`ghcr.io/${IMAGE_REPO}\` (匿名 pull token 校验)"
    echo
    echo "| tag | 状态 | digest |"
    echo "| --- | --- | --- |"
    printf '%s\n' "${tag_rows[@]}"
    echo
    if [ "$fail_n" -eq 0 ]; then
        echo "**结论: 安装脚本依赖的 tag 全部存在。**"
    else
        echo "**结论: ${fail_n} 个 tag 有问题**, 安装脚本在用户机器上会失败。"
        echo
        printf '%s\n' "${detail[@]}"
    fi
    echo
    echo "<details><summary>国内加速源可达性(仅供参考, 失败不算错)</summary>"
    echo
    echo "GitHub runner 在海外, 这些源不通不代表国内用户拉不到; 反向也不成立。"
    echo "真要验证加速源, 应在国内网络里跑。"
    echo
    echo "| 源 | 探测 |"
    echo "| --- | --- |"
    printf '%s\n' "${mirror_rows[@]}"
    echo
    echo "</details>"
} >"$REPORT"

cat "$REPORT"
[ "$fail_n" -eq 0 ] || exit 1
