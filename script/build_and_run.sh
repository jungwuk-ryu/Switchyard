#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Switchyard"
BUNDLE_ID="dev.switchyard.Switchyard"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${SWITCHYARD_APP_VERSION:-0.3.0}"
APP_BUILD="${SWITCHYARD_APP_BUILD:-3}"
BUILD_CONFIGURATION="${SWITCHYARD_BUILD_CONFIGURATION:-debug}"
case "$BUILD_CONFIGURATION" in
  debug|release) ;;
  *) echo "SWITCHYARD_BUILD_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_BINARY="$APP_MACOS/$APP_NAME"
RUNNER_BINARY="$APP_HELPERS/switchyard-runner"
URL_HANDLER_BINARY="$APP_HELPERS/switchyard-url-handler"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MAX_SWIFT_BUILD_JOBS=13
SWIFT_BUILD_JOBS="${SWIFT_BUILD_JOBS:-$MAX_SWIFT_BUILD_JOBS}"
if [ "$SWIFT_BUILD_JOBS" -gt "$MAX_SWIFT_BUILD_JOBS" ]; then
  SWIFT_BUILD_JOBS="$MAX_SWIFT_BUILD_JOBS"
elif [ "$SWIFT_BUILD_JOBS" -lt 1 ]; then
  SWIFT_BUILD_JOBS=1
fi

if [ "${SWITCHYARD_SKIP_RUNTIME_ENSURE:-0}" != "1" ]; then
  "$ROOT_DIR/script/ensure_wine_runtime.sh"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build -c "$BUILD_CONFIGURATION" --jobs "$SWIFT_BUILD_JOBS" --product "$APP_NAME"
swift build -c "$BUILD_CONFIGURATION" --jobs "$SWIFT_BUILD_JOBS" --product switchyard-runner
swift build -c "$BUILD_CONFIGURATION" --jobs "$SWIFT_BUILD_JOBS" --product switchyard-url-handler
BUILD_BIN_PATH="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"
BUILD_RUNNER="$BUILD_BIN_PATH/switchyard-runner"
BUILD_URL_HANDLER="$BUILD_BIN_PATH/switchyard-url-handler"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_RUNNER" "$RUNNER_BINARY"
cp "$BUILD_URL_HANDLER" "$URL_HANDLER_BINARY"
cp "$ROOT_DIR/config/switchyard-wine.env" "$APP_RESOURCES/switchyard-wine.env"
chmod +x "$APP_BINARY"
chmod +x "$RUNNER_BINARY"
chmod +x "$URL_HANDLER_BINARY"

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
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>SwitchyardBuildConfiguration</key>
  <string>$BUILD_CONFIGURATION</string>
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
    verified_pid=""
    for _ in {1..20}; do
      verified_pid="$(pgrep -x "$APP_NAME" | tail -n 1 || true)"
      if [ -n "$verified_pid" ]; then
        break
      fi
      sleep 0.5
    done
    if [ -z "$verified_pid" ]; then
      echo "$APP_NAME did not start within 10 seconds" >&2
      exit 1
    fi
    kill "$verified_pid" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
