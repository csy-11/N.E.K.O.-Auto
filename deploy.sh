#!/usr/bin/env bash
# ==============================================================================
# 兼容转发器(旧的 deploy.sh 名字)。
# 实际逻辑已迁移到同目录的 install.sh。
# 保留此文件仅为让老命令(收藏的 curl .../deploy.sh)继续可用。
# 新用法请直接用 install.sh(见 README.md)。
# ==============================================================================
set -euo pipefail
DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
if [ ! -x "$DIR/install.sh" ] && [ ! -f "$DIR/install.sh" ]; then
  echo "install: 找不到同目录的 install.sh($DIR/install.sh)" >&2
  echo "请确认你是从 N.E.K.O.-Auto 仓库拉取的完整文件。" >&2
  exit 1
fi
exec bash "$DIR/install.sh" "$@"
