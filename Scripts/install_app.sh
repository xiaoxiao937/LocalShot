#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/LocalShot.app"
DESTINATION="/Applications/LocalShot.app"
if [[ ! -x "$APP_DIR/Contents/MacOS/LocalShot" ]]; then
    echo "请先运行 Scripts/package_release.sh。"
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
PROCESS_STATUS=0
/usr/bin/pgrep -x LocalShot >/dev/null || PROCESS_STATUS=$?
if [[ "$PROCESS_STATUS" == 0 ]]; then
    echo "LocalShot 正在运行。请先在设置或菜单栏点“退出 LocalShot”，再运行安装脚本。"
    echo "安装尚未执行，以免新版文件与旧进程混用。"
    exit 2
fi
if [[ "$PROCESS_STATUS" != 1 ]]; then
    echo "无法检查运行中的 LocalShot，安装未执行。请在终端重新运行此脚本。"
    exit 3
fi
STAGING=$(/usr/bin/mktemp -d /Applications/.LocalShot-install.XXXXXX)
STAGED_APP="$STAGING/LocalShot.app"
PREVIOUS_APP="$STAGING/previous.app"
INSTALLED=0
restore_previous() {
    if [[ "$INSTALLED" == 0 && -d "$PREVIOUS_APP" ]]; then
        if [[ -d "$DESTINATION" ]]; then
            /bin/mv "$DESTINATION" "$STAGING/failed.app"
        fi
        /bin/mv "$PREVIOUS_APP" "$DESTINATION"
        echo "安装中止，已恢复原来的 LocalShot。临时副本保留于：$STAGING"
    fi
}
trap restore_previous EXIT
/usr/bin/ditto "$APP_DIR" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
/usr/bin/cmp "$APP_DIR/Contents/MacOS/LocalShot" "$STAGED_APP/Contents/MacOS/LocalShot"
# Check again after staging in case LaunchServices restarted the old process.
PROCESS_STATUS=0
/usr/bin/pgrep -x LocalShot >/dev/null || PROCESS_STATUS=$?
if [[ "$PROCESS_STATUS" != 1 ]]; then
    echo "LocalShot 已重新启动或进程检查失败，尚未替换应用。临时副本：$STAGING"
    exit 2
fi
if [[ -d "$DESTINATION" ]]; then /bin/mv "$DESTINATION" "$PREVIOUS_APP"; fi
/bin/mv "$STAGED_APP" "$DESTINATION"
/usr/bin/codesign --verify --deep --strict "$DESTINATION"
/usr/bin/cmp "$APP_DIR/Contents/MacOS/LocalShot" "$DESTINATION/Contents/MacOS/LocalShot"
INSTALLED=1
if [[ -d "$PREVIOUS_APP" ]]; then
    TRASH_DIR="$HOME/.Trash"
    if [[ -d "$TRASH_DIR" && -w "$TRASH_DIR" ]]; then
        /bin/mv "$PREVIOUS_APP" "$TRASH_DIR/LocalShot-previous-${STAGING:t}.app"
        /bin/rmdir "$STAGING"
        echo "旧 App 已移入废纸篓，可恢复。"
    else
        echo "旧 App 的可恢复备份位于：$PREVIOUS_APP"
    fi
else
    /bin/rmdir "$STAGING"
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DESTINATION/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DESTINATION/Contents/Info.plist")
echo "已安装 LocalShot $VERSION (build $BUILD)。从应用程序重新打开后生效。"
