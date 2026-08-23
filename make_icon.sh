#!/bin/bash
# 生成 AppIcon.icns 并安装到 MemBar.app
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/MemBar.app"
TMP=/tmp/membar_icon
ICONSET="$TMP/AppIcon.iconset"

echo "==> 1/4 生成 1024px 图标 ..."
rm -rf "$TMP"
mkdir -p "$TMP"
swiftc -O icon_gen.swift -o "$TMP/icon_gen" 2>/dev/null
"$TMP/icon_gen"

echo "==> 2/4 生成多尺寸 ..."
mkdir -p "$ICONSET"
sips -z 16 16   "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32   "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32 32   "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64   "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128 128 "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256 "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_128x128@2x.png">/dev/null
sips -z 256 256 "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512 "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_256x256@2x.png">/dev/null
sips -z 512 512 "$TMP/AppIcon-1024.png" --out "$ICONSET/icon_512x512.png"   >/dev/null
cp "$TMP/AppIcon-1024.png" "$ICONSET/icon_512x512@2x.png"

echo "==> 3/4 打包 icns ..."
iconutil -c icns "$ICONSET" -o "$TMP/AppIcon.icns"

echo "==> 4/4 安装并重启 MemBar ..."
mkdir -p "$APP/Contents/Resources"
cp "$TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
pkill -f "MemBar.app/Contents/MacOS/MemBar" 2>/dev/null || true
sleep 1
open "$APP"
sleep 2
pgrep -fl MemBar >/dev/null && echo "==> ✅ MemBar 已重启，新图标生效" || echo "==> ❌ 启动失败"
