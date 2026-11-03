#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PLIST="$ROOT/Support/Info.plist"
APP="$ROOT/.build/StandUpTimer.app"
DIST="$ROOT/dist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
ZIP_NAME="StandUpTimer-${VERSION}-macos-universal.zip"
ZIP="$DIST/$ZIP_NAME"

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
    echo "错误：Support/Info.plist 缺少 CFBundleShortVersionString 或 CFBundleVersion。" >&2
    exit 1
fi

# 发布包必须是通用二进制：Apple Silicon 与 Intel 都能直接运行。
# 架构校验由 build-app.sh 在签名前完成，签名身份沿用它的环境变量配置。
STANDUP_BUILD_CONFIGURATION=release \
STANDUP_BUILD_ARCHS="arm64 x86_64" \
    "$ROOT/Scripts/build-app.sh"

echo "--- 校验签名 ---"
codesign --verify --deep --strict "$APP"
echo "架构：$(lipo -archs "$APP/Contents/MacOS/StandUpTimerApp")"

mkdir -p "$DIST"
rm -f "$ZIP"
# --keepParent 让压缩包解压后直接得到 StandUpTimer.app，而不是散落的 Contents。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 校验和文件只覆盖本次发布的压缩包，避免旧版本的条目混进来。
(cd "$DIST" && shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt)

echo "版本：${VERSION}（build ${BUILD_NUMBER}）"
echo "产物：${ZIP}"
echo "校验和：${DIST}/SHA256SUMS.txt"
