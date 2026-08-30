#!/usr/bin/env bash
# 运行冒烟测试
set -euo pipefail
cd "$(dirname "$0")/.."
exec nvim --headless -l tests/smoke.lua
