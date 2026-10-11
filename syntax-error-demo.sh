#!/usr/bin/env bash
# ⚠️ 临时文件: 故意写坏的脚本, 用来验证 weekly-compat 的语法检查能不能抓到。
#    验证完就删 —— 不要拿它当例子参考。
set -euo pipefail

if [ -f /etc/hostname ]; then
    echo "hostname 存在"
# 故意漏掉 fi

echo "这行其实到不了"
