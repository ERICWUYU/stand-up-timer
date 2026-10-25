#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_ARGS=()
if [[ "${STANDUP_BUILD_DISABLE_SANDBOX:-0}" == "1" ]]; then
    BUILD_ARGS+=(--disable-sandbox)
fi

# bash 3.2（macOS 自带）在 set -u 下展开空数组会报 unbound variable。
swift build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
BIN_DIR="$(swift build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --show-bin-path)"
APP="$ROOT/.build/StandUpTimer.app"
STAGING="$ROOT/.build/StandUpTimer.app.staging"
RESOURCE_BUNDLE="$BIN_DIR/StandUpTimer_StandUpTimerApp.bundle"

# 先在临时目录组装并签名，全部成功后再替换正式产物：
# 中途任何一步失败都不会毁掉上一次可用的 app。
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS"
mkdir -p "$STAGING/Contents/Resources"
cp "$BIN_DIR/StandUpTimerApp" "$STAGING/Contents/MacOS/StandUpTimerApp"
cp -R "$RESOURCE_BUNDLE" "$STAGING/Contents/Resources/"
cp "$ROOT/Support/Info.plist" "$STAGING/Contents/Info.plist"

# 签名失败必须让脚本失败：静默通过会生成通知权限异常的坏包。
codesign --force --deep --sign - "$STAGING"

rm -rf "$APP"
mv "$STAGING" "$APP"

echo "已生成：$APP"
echo "正常运行：open \"$APP\""
echo "10 秒测试：open \"$APP\" --args --test-durations 10"
