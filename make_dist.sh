#!/bin/bash
# 打包 MemBar 为可分发的 zip（含版本号）
set -e
cd "$(dirname "$0")"
# 版本号单一来源：从 Info.plist 读取，避免与打包脚本各改一处导致打错版本
VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    echo "❌ 无法从 Info.plist 读取 CFBundleShortVersionString，请检查 Info.plist" >&2
    exit 1
fi
APP="$HOME/Applications/MemBar.app"
DIST="$HOME/membar/dist"

# 先确保是最新构建
echo "==> 确保最新构建 ..."
bash build.sh >/dev/null 2>&1

echo "==> 打包 $APP → $DIST/MemBar-v$VERSION.zip ..."
mkdir -p "$DIST"
rm -f "$DIST/MemBar-v$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/MemBar-v$VERSION.zip"

echo
echo "✅ 打包完成: $DIST/MemBar-v$VERSION.zip"
echo
echo "=== 安装到其他 Mac ==="
cat <<EOF
1. 拷贝 zip 到目标 Mac
2. unzip MemBar-v$VERSION.zip -d ~/Applications/
3. open ~/Applications/MemBar.app
4. 首次启动如被 Gatekeeper 拦截（执行这一行）:
   xattr -dr com.apple.quarantine ~/Applications/MemBar.app
5. 可选开机自启（下方 osascript 以本机绝对路径生成，在其他 Mac 上执行前请把路径改成目标机实际路径）:
   osascript -e 'tell application "System Events" to make login item at end with properties {path:"$APP", hidden:false}'
EOF
