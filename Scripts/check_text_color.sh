#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
PROBE_DIR=$(/usr/bin/mktemp -d /tmp/localshot-color-check.XXXXXX)
trap '/usr/bin/find "$PROBE_DIR" -depth -delete' EXIT
if [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
cd "$PROJECT_DIR"
{
    for source in Sources/LocalShot/*.swift; do
        if [[ "$source" != Sources/LocalShot/AppMain.swift ]]; then
            /usr/bin/sed 's/private let defaults = UserDefaults.standard/private let defaults = ColorProbeDefaults.shared/' "$source"
        fi
    done
    /bin/cat Scripts/check_text_color.swift
} | /usr/bin/xcrun swiftc -parse-as-library -swift-version 5 \
    -module-cache-path "$PROBE_DIR/cache" - -o "$PROBE_DIR/check"
"$PROBE_DIR/check"
