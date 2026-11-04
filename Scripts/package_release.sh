#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/LocalShot.app"
/bin/zsh "$PROJECT_DIR/Scripts/build_app.sh"
/bin/zsh "$PROJECT_DIR/Scripts/audit_privacy.sh" "$APP_DIR"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$BUILD" =~ '^[0-9]+$' ]]; then
    echo "版本号无效，停止打包。"
    exit 1
fi
ARCHIVE="$PROJECT_DIR/dist/LocalShot-$VERSION-macOS.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"

# This opt-in upload is a developer release step, never part of the app.
# Credentials must already be stored in Keychain; no secrets enter this file.
if [[ -n "${LOCALSHOT_NOTARY_PROFILE:-}" ]]; then
    if [[ "${LOCALSHOT_SIGN_IDENTITY:--}" == "-" ]]; then
        echo "公证需要 Developer ID 签名，请先设置 LOCALSHOT_SIGN_IDENTITY。"
        exit 1
    fi
    RESULT="$PROJECT_DIR/../../work/localshot-build/notarization.plist"
    /usr/bin/xcrun notarytool submit "$ARCHIVE" \
        --keychain-profile "$LOCALSHOT_NOTARY_PROFILE" \
        --wait --timeout 15m --output-format plist > "$RESULT"
    STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$RESULT")
    if [[ "$STATUS" != "Accepted" ]]; then
        echo "Apple 公证未通过：$STATUS。当前包不可标记为正式发行。"
        exit 1
    fi
    /usr/bin/xcrun stapler staple "$APP_DIR"
    /usr/bin/xcrun stapler validate "$APP_DIR"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
fi
/usr/bin/unzip -tq "$ARCHIVE"
/usr/bin/shasum -a 256 "$ARCHIVE"
echo "版本 $VERSION (build $BUILD)：$ARCHIVE"
if [[ "${LOCALSHOT_SIGN_IDENTITY:--}" == "-" ]]; then
    echo "本机临时签名构建；未完成 Developer ID 签名与 Apple 公证。"
fi
