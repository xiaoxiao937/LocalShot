#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${PROJECT_DIR}/../../work/localshot-build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_DIR="${DIST_DIR}/LocalShot.app"

if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swift-module-cache"
export XDG_CACHE_HOME="$BUILD_DIR/cache"
/bin/mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$XDG_CACHE_HOME"

cd "$PROJECT_DIR"
/usr/bin/swift build --disable-sandbox -c release -debug-info-format none --enable-experimental-strip-products --scratch-path "$BUILD_DIR"

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
/bin/cp "$BUILD_DIR/release/LocalShot" "$APP_DIR/Contents/MacOS/LocalShot"
/bin/cp "$PROJECT_DIR/Config/Info.plist" "$APP_DIR/Contents/Info.plist"
/bin/cp "$PROJECT_DIR/Config/PkgInfo" "$APP_DIR/Contents/PkgInfo"
/bin/cp "$PROJECT_DIR/Config/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"

ASSET_OUTPUT="$BUILD_DIR/asset-output"
/bin/rm -rf "$ASSET_OUTPUT"
/bin/mkdir -p "$ASSET_OUTPUT"
/usr/bin/xcrun actool "$PROJECT_DIR/Assets/Assets.xcassets" \
    --compile "$ASSET_OUTPUT" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_OUTPUT/partial.plist" >/dev/null
/bin/cp "$ASSET_OUTPUT/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/bin/cp "$ASSET_OUTPUT/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"

/usr/bin/codesign --force --sign - --options runtime --entitlements "$PROJECT_DIR/Config/LocalShot.entitlements" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
