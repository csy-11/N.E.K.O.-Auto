#!/usr/bin/env bash
# compose 环境变量台账 —— docker-compose.yml 的 environment: 里可以用 ${VAR} 覆盖的
# 容器变量, 必须在 env.template 或 CONFIG_REFERENCE.md 里有说明。上游往 compose 里
# 加了新变量却忘了写文档时, 用户就永远不知道有这个开关; 这里每周兜一次。
#
# 只查「容器面向」的变量, 即 environment: 列表里出现的 ${VAR...}。
# compose 自身用于插值的变量(如 image: 行里的 NEKO_IMAGE / NEKO_IMAGE_VERSION)不算,
# 它们不进入容器, 改由 docker-compose.yml 的注释和 README 说明。
#
# 纯文本缩进解析, 不依赖 PyYAML(runner 上不保证有)。
#
# 环境变量:
#   COMPOSE   默认 docker-compose.yml
#   DOCS      默认 "env.template CONFIG_REFERENCE.md"
#   REPORT    默认 env-ledger.md
#
# 退出码: 0 = 全部有文档; 1 = 有未文档化的变量
set -euo pipefail

COMPOSE="${COMPOSE:-docker-compose.yml}"
DOCS="${DOCS:-env.template CONFIG_REFERENCE.md}"
REPORT="${REPORT:-env-ledger.md}"

python3 - "$COMPOSE" "$DOCS" "$REPORT" <<'PY'
import re, sys, pathlib

compose_path, docs, report_path = sys.argv[1], sys.argv[2].split(), sys.argv[3]
text = pathlib.Path(compose_path).read_text(encoding="utf-8")

# --- 抓出每个 service 的 environment: 列表 -----------------------------------
container_vars, compose_only = {}, []

lines = text.splitlines()
in_env = False
env_indent = 0
for i, line in enumerate(lines, 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    indent = len(line) - len(line.lstrip())
    if in_env and indent <= env_indent:
        in_env = False
    if re.match(r"\s*environment:\s*$", line):
        in_env, env_indent = True, indent
        continue
    if not re.match(r"\s*environment:", line):          # 内联形式 environment: [..]
        pass                                            # 本项目没用内联形式
    found = re.findall(r"\$\{([A-Z_][A-Z0-9_]*)", line)
    if not found:
        continue
    if in_env:
        for v in found:
            container_vars.setdefault(v, i)
    else:
        for v in found:
            compose_only.append((v, i))
    # 内联 environment: [A=1, B=2] 也一起算上
    if re.match(r"\s*environment:\s*\[", line):
        for v in found:
            container_vars.setdefault(v, i)

doc_text = "\n".join(
    pathlib.Path(d).read_text(encoding="utf-8") for d in docs if pathlib.Path(d).is_file()
)

missing = {v: ln for v, ln in container_vars.items() if v not in doc_text}

# --- 报告 -------------------------------------------------------------------
out = []
out += ["## compose 环境变量台账", ""]
out += [f"`{compose_path}` 的 `environment:` 里可覆盖的变量 → 是否在 "
        f"{', '.join(f'`{d}`' for d in docs)} 里有说明", ""]
out += ["| 变量 | 出处行 | 文档 |", "| --- | --- | --- |"]
for v, ln in sorted(container_vars.items(), key=lambda kv: kv[1]):
    mark = "❌ **未说明**" if v in missing else "✅"
    out += [f"| `{v}` | {compose_path}:{ln} | {mark} |"]
out += [""]

if missing:
    out += [f"**结论: {len(missing)} 个变量没有文档**, 用户不知道可以设置它们。",
            "", "把缺失的变量补进 `env.template`(带注释说明取值)与 `CONFIG_REFERENCE.md`。", ""]
else:
    out += [f"**结论: {len(container_vars)} 个容器变量全部有文档。**", ""]

if compose_only:
    out += ["<details><summary>compose 插值专用变量(不进入容器, 不参与检查)</summary>", ""]
    for v, ln in sorted(set(compose_only), key=lambda kv: kv[1]):
        out += [f"- `{v}` (`{compose_path}:{ln}`)"]
    out += ["", "这些是 `docker compose` 自己在解析 compose 文件时读的(如 `image:` 行的"
                " `NEKO_IMAGE` / `NEKO_IMAGE_VERSION`), 不需要写进 `env.template`。", "", "</details>"]

out += ["", "<details><summary>已知情况</summary>", "",
        "- `TZ` / `NEKO_*` / `SSL_DOMAIN` 等同时在 `env.template` 与 `CONFIG_REFERENCE.md`。",
        "- `XDG_DATA_HOME` / `NEKO_STORAGE_*_ROOT` 在 compose 里是写死的字面量(不带 `${}`), "
        "属于容器内部约定而非用户开关, 因此不在表内。", "", "</details>"]

report = "\n".join(out) + "\n"
pathlib.Path(report_path).write_text(report, encoding="utf-8")
print(report)

if missing:
    print(f"UNDOCUMENTED: {', '.join(sorted(missing))}", file=sys.stderr)
    sys.exit(1)
PY
