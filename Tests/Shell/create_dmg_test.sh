#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CREATOR="$ROOT_DIR/script/create_dmg.sh"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/switchyard-create-dmg-test.XXXXXX")"

cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

APP="$TEST_ROOT/Switchyard.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$TEST_ROOT/output"
/bin/cp /usr/bin/true "$APP/Contents/MacOS/Switchyard"
/bin/cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Switchyard</string>
  <key>CFBundleIdentifier</key>
  <string>dev.switchyard.CreateDMGTest</string>
  <key>CFBundleName</key>
  <string>Switchyard</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"

DMG="$TEST_ROOT/output/Switchyard-test-macos-arm64.dmg"
"$CREATOR" \
  --app "$APP" \
  --output "$DMG" \
  --volume-name "Switchyard Test"

[ -f "$DMG" ] || {
  echo "DMG creator did not produce an artifact" >&2
  exit 1
}
/usr/bin/hdiutil verify "$DMG"

echo "create_dmg.sh test passed"
