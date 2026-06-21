#!/bin/bash
# 启动咕咕(后台常驻)。关掉终端也不会退出。
set -e
set -o pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="./.build/release/gugu"
[ -x "$BIN" ] || BIN="./.build/debug/gugu"
# ad-hoc 签名:免去每次新二进制首启的 Gatekeeper 校验,窗口秒出(与 build-app.sh 一致)
codesign --force --sign - "$BIN" 2>/dev/null || true
# 杀掉旧实例
pkill -f "gugu/.build" 2>/dev/null || true
sleep 1
nohup "$BIN" > /tmp/gugu.log 2>&1 &
echo "咕咕已启动 (pid $!)。菜单栏找 🐤。日志: /tmp/gugu.log"
echo "停止: pkill -f gugu/.build"
