#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 默认 debug 构建；发布脚本用 STANDUP_BUILD_CONFIGURATION=release 复用同一套组装流程。
CONFIGURATION="${STANDUP_BUILD_CONFIGURATION:-debug}"
# 架构通过空格分隔的列表配置，例如 STANDUP_BUILD_ARCHS="arm64 x86_64" 生成通用二进制。
# 不设置时只编译当前机器架构。
BUILD_ARGS=(-c "$CONFIGURATION")
for ARCH in ${STANDUP_BUILD_ARCHS:-}; do
    BUILD_ARGS+=(--arch "$ARCH")
done
if [[ "${STANDUP_BUILD_DISABLE_SANDBOX:-0}" == "1" ]]; then
    BUILD_ARGS+=(--disable-sandbox)
fi

# 签名身份通过环境变量配置，仓库里不写死个人证书：
#   STANDUP_CODESIGN_IDENTITY="Apple Development: 姓名 (TEAMID)" Scripts/build-app.sh
# 未设置时退回 ad-hoc 签名（"-"），保证没有证书的机器仍能产出可运行的 app。
SIGN_IDENTITY="${STANDUP_CODESIGN_IDENTITY:--}"

# bash 3.2（macOS 自带）在 set -u 下展开空数组会报 unbound variable。
swift build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
BIN_DIR="$(swift build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} --show-bin-path)"
APP="$ROOT/.build/StandUpTimer.app"
STAGING="$ROOT/.build/StandUpTimer.app.staging"
RESOURCE_BUNDLE="$BIN_DIR/StandUpTimer_StandUpTimerApp.bundle"
ICON="$ROOT/Support/AppIcon.icns"
ASSETS="$ROOT/Support/Assets.xcassets"
ASSET_BUILD="$ROOT/.build/StandUpTimer.assets"

if [[ ! -f "$ICON" ]]; then
    echo "错误：缺少应用图标 $ICON" >&2
    exit 1
fi

if [[ ! -d "$ASSETS" ]]; then
    echo "错误：缺少图标资源目录 $ASSETS" >&2
    exit 1
fi

# 先在临时目录组装并签名，全部成功后再替换正式产物：
# 中途任何一步失败都不会毁掉上一次可用的 app。
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS"
mkdir -p "$STAGING/Contents/Resources"
cp "$BIN_DIR/StandUpTimerApp" "$STAGING/Contents/MacOS/StandUpTimerApp"

# 指定了架构列表时必须核对实际产物，避免发布包里悄悄少了某个架构。
if [[ -n "${STANDUP_BUILD_ARCHS:-}" ]]; then
    EXPECTED_ARCHS="$(printf '%s\n' $STANDUP_BUILD_ARCHS | sort | tr '\n' ' ' | sed 's/ $//')"
    ACTUAL_ARCHS="$(lipo -archs "$STAGING/Contents/MacOS/StandUpTimerApp" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$ACTUAL_ARCHS" != "$EXPECTED_ARCHS" ]]; then
        echo "错误：产物架构为 ${ACTUAL_ARCHS}，预期 ${EXPECTED_ARCHS}。" >&2
        exit 1
    fi
fi

cp -R "$RESOURCE_BUNDLE" "$STAGING/Contents/Resources/"
cp "$ICON" "$STAGING/Contents/Resources/AppIcon.icns"
cp "$ROOT/Support/Info.plist" "$STAGING/Contents/Info.plist"

# 同时提供 .icns 与 Assets.car：较新的系统界面按 CFBundleIconName 从资源目录取图标，
# 旧系统回退到 .icns。
# 注意：通知横幅的图标来自系统按 bundle id 保存的通知记录快照，与这里的资源形式无关；
# 想在已有的 bundle id 上换图标，必须换 CFBundleIdentifier（见 AGENTS.md）。
rm -rf "$ASSET_BUILD"
mkdir -p "$ASSET_BUILD"
if ! xcrun actool \
    --compile "$ASSET_BUILD" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_BUILD/asset-info.plist" \
    "$ASSETS" >/dev/null; then
    echo "错误：Assets.xcassets 编译失败。" >&2
    exit 1
fi
cp "$ASSET_BUILD/Assets.car" "$STAGING/Contents/Resources/Assets.car"

# 漏掉图标会让 Finder 和通知中心显示通用图标；在签名前就失败，避免产出看似正常的坏包。
if [[ ! -s "$STAGING/Contents/Resources/AppIcon.icns" ]]; then
    echo "错误：AppIcon.icns 未复制到 app bundle。" >&2
    exit 1
fi

if [[ ! -s "$STAGING/Contents/Resources/Assets.car" ]]; then
    echo "错误：Assets.car 未编译到 app bundle。" >&2
    exit 1
fi

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$STAGING/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ICON_NAME" != "AppIcon.icns" ]]; then
    echo "错误：Info.plist 的 CFBundleIconFile 应为 AppIcon.icns（当前：${ICON_NAME:-缺失}）。" >&2
    exit 1
fi

ICON_ASSET="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$STAGING/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$ICON_ASSET" != "AppIcon" ]]; then
    echo "错误：Info.plist 的 CFBundleIconName 应为 AppIcon（当前：${ICON_ASSET:-缺失}）。" >&2
    exit 1
fi

# 签名失败必须让脚本失败：静默通过会生成通知权限异常的坏包。
codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGING"

rm -rf "$APP"
mv "$STAGING" "$APP"

echo "已生成：$APP"
echo "正常运行：open \"$APP\""
echo "10 秒测试：open \"$APP\" --args --test-durations 10"
