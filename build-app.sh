#!/bin/bash
# 打包成 Gugu.app 并启动。摄像头权限对 .app 包更可靠。
set -e
set -o pipefail
cd "$(dirname "$0")"

echo "编译 release…"
swift build -c release
BIN="./.build/release/gugu"
[ -x "$BIN" ] || { echo "构建失败"; exit 1; }

APP="Gugu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/gugu"
cp Info.plist "$APP/Contents/Info.plist"
cat > "$APP/Contents/PkgInfo" <<< "APPL????"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription CFBundleExecutable CFBundlePackageType; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null
done

# ad-hoc 签名(让 TCC 能稳定记住授权)
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "已生成 $APP"

# 杀旧实例并启动
pkill -f "gugu/.build" 2>/dev/null || true
pkill -f "Gugu.app" 2>/dev/null || true
sleep 1
open "$APP"
echo "咕咕已启动。菜单栏找咕咕图标。"
echo "停止: pkill -f Gugu.app"
