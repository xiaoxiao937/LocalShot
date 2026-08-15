#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="${1:-${PROJECT_DIR}/dist/LocalShot.app}"
BIN="$APP_DIR/Contents/MacOS/LocalShot"

if [[ ! -x "$BIN" ]]; then
    echo "未找到可执行文件：$BIN"
    exit 1
fi

/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ENTITLEMENTS=$(/usr/bin/codesign -d --entitlements :- "$APP_DIR" 2>/dev/null)
LIBRARIES=$(/usr/bin/otool -L "$BIN")
SYMBOLS=$(/usr/bin/nm -u "$BIN" 2>/dev/null || true)
TEXT=$(/usr/bin/strings -a "$BIN")

if print -r -- "$ENTITLEMENTS" | /usr/bin/grep -Eq 'get-task-allow|network\.client|network\.server'; then
    echo "失败：发现调试或网络权限"
    exit 1
fi

if ! print -r -- "$ENTITLEMENTS" | /usr/bin/grep -q 'com.apple.security.app-sandbox'; then
    echo "失败：未启用 App Sandbox"
    exit 1
fi

if print -r -- "$LIBRARIES" | /usr/bin/grep -Eq 'CFNetwork\.framework|Network\.framework|WebKit\.framework|PrivateFrameworks'; then
    echo "失败：发现网络库、WebKit 或私有框架"
    exit 1
fi

if print -r -- "$SYMBOLS" | /usr/bin/grep -Eq 'NSURLSession|URLSession|_socket$|_connect$|_getaddrinfo$|NWConnection'; then
    echo "失败：发现网络 API"
    exit 1
fi

if print -r -- "$TEXT" | /usr/bin/grep -Eqi 'https?://|wss?://'; then
    echo "失败：二进制中发现网络地址"
    exit 1
fi

echo "隐私审计通过"
echo "- App Sandbox：已启用"
echo "- 网络权限：无"
echo "- 网络 API/库：无"
echo "- 私有框架：无"
echo "- 调试权限：无"
