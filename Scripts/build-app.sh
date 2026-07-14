#!/bin/zsh

set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-release}"
APP_NAME="WakeBar"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
ICONSET="$ROOT/.build/WakeBar.iconset"

if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    echo "Configuration must be 'release' or 'debug'." >&2
    exit 64
fi

echo "Building $APP_NAME ($CONFIGURATION)…"
swift build --package-path "$ROOT" -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_BUNDLE" "$ICONSET"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$DIST_DIR"

cp "$BIN_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"

swift "$ROOT/Scripts/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/WakeBar.icns"
rm -rf "$ICONSET"

codesign --force --sign - --timestamp=none "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"
