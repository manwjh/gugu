#!/bin/bash
# 启动咕咕(后台常驻)。关掉终端也不会退出。
set -e
set -o pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="./.build/release/gugu"
[ -x "$BIN" ] || BIN="./.build/debug/gugu"
# 杀掉旧实例
pkill -f "gugu/.build" 2>/dev/null || true
sleep 1
nohup "$BIN" > /tmp/gugu.log 2>&1 &
echo "咕咕已启动 (pid $!)。菜单栏找 🐤。日志: /tmp/gugu.log"
echo "停止: pkill -f gugu/.build"
