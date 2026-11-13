#!/bin/bash
# 构建 .app 包：swift build + 手打 bundle + ad-hoc 签名。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${1:-release}
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/WindowBack"
APP="dist/WindowBack.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WindowBack"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ad-hoc 签名：TCC（辅助功能）授权与 cdhash 绑定，重签名后需要在系统设置里重新勾选。
codesign --force --sign - --identifier dev.dct74.windowback "$APP"

echo "==> $APP"
codesign -dv "$APP" 2>&1 | sed -n '1,6p'
