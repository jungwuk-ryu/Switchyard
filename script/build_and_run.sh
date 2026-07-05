#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Switchyard"
BUNDLE_ID="dev.switchyard.Switchyard"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_BINARY="$APP_MACOS/$APP_NAME"
RUNNER_BINARY="$APP_HELPERS/switchyard-runner"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --product "$APP_NAME"
swift build --product switchyard-runner
BUILD_BIN_PATH="$(swift build --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"
BUILD_RUNNER="$BUILD_BIN_PATH/switchyard-runner"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES/patches/wine"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_RUNNER" "$RUNNER_BINARY"
cp "$ROOT_DIR/patches/wine/series" "$APP_RESOURCES/patches/wine/series"
cp "$ROOT_DIR"/patches/wine/*.patch "$APP_RESOURCES/patches/wine/"
chmod +x "$APP_BINARY"
chmod +x "$RUNNER_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
