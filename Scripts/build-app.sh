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
ICON="$ROOT/Support/AppIcon.icns"

if [[ ! -f "$ICON" ]]; then
    echo "错误：缺少应用图标 $ICON" >&2
    exit 1
fi

# 先在临时目录组装并签名，全部成功后再替换正式产物：
# 中途任何一步失败都不会毁掉上一次可用的 app。
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS"
mkdir -p "$STAGING/Contents/Resources"
cp "$BIN_DIR/StandUpTimerApp" "$STAGING/Contents/MacOS/StandUpTimerApp"
cp -R "$RESOURCE_BUNDLE" "$STAGING/Contents/Resources/"
cp "$ICON" "$STAGING/Contents/Resources/AppIcon.icns"
cp "$ROOT/Support/Info.plist" "$STAGING/Contents/Info.plist"

# 漏掉图标会让 Finder 显示通用图标；在签名前就失败，避免产出看似正常的坏包。
if [[ ! -f "$STAGING/Contents/Resources/AppIcon.icns" ]]; then
    echo "错误：AppIcon.icns 未复制到 app bundle。" >&2
    exit 1
fi

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$STAGING/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ICON_NAME" != "AppIcon.icns" ]]; then
    echo "错误：Info.plist 的 CFBundleIconFile 应为 AppIcon.icns（当前：${ICON_NAME:-缺失}）。" >&2
    exit 1
fi

# 签名失败必须让脚本失败：静默通过会生成通知权限异常的坏包。
codesign --force --deep --sign - "$STAGING"

rm -rf "$APP"
mv "$STAGING" "$APP"

echo "已生成：$APP"
echo "正常运行：open \"$APP\""
echo "10 秒测试：open \"$APP\" --args --test-durations 10"
