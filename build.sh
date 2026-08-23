#!/bin/bash
# 构建 MemBar 菜单栏内存监控
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/MemBar.app"
echo "==> 编译 main.swift ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/MemBar" main.swift

echo "==> 写入 Info.plist ..."
cp Info.plist "$APP/Contents/Info.plist"

if [ -f "$(dirname "$0")/AppIcon.icns" ]; then
    echo "==> 安装图标 ..."
    mkdir -p "$APP/Contents/Resources"
    cp "$(dirname "$0")/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 签名(ad-hoc) ..."
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> 停止旧实例 ..."
pkill -f "$APP/Contents/MacOS/MemBar" 2>/dev/null || true
sleep 1

echo "==> 完成: $APP"
echo "==> 启动中 ..."
open "$APP"
sleep 2
if pgrep -fl MemBar >/dev/null; then
    echo "==> ✅ MemBar 已运行: $(pgrep -fl MemBar | head -1)"
else
    echo "==> ❌ MemBar 未运行，请检查错误"
fi
