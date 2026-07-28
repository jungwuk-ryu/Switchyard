#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DMG_CREATOR="$ROOT_DIR/script/create_dmg.sh"
APPCAST_GENERATOR="$ROOT_DIR/script/generate_appcast.sh"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/switchyard-appcast-test.XXXXXX")"
APP="$TEST_ROOT/Switchyard.app"
CONTENTS="$APP/Contents"
INFO_PLIST="$CONTENTS/Info.plist"
DMG="$TEST_ROOT/Switchyard-99.0.0-macos-arm64.dmg"
APPCAST="$TEST_ROOT/output/appcast.xml"

cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

[ ! -e "$ROOT_DIR/appcast.xml" ] || {
  echo "refusing to overwrite an existing repository-root appcast.xml" >&2
  exit 1
}

key_material="$(
  /usr/bin/swift -e '
    import CryptoKit
    import Foundation
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    print(key.publicKey.rawRepresentation.base64EncodedString())
  '
)"
private_key="$(/usr/bin/printf '%s\n' "$key_material" | /usr/bin/sed -n '1p')"
public_key="$(/usr/bin/printf '%s\n' "$key_material" | /usr/bin/sed -n '2p')"

/bin/mkdir -p "$CONTENTS/MacOS" "$(dirname "$APPCAST")"
/bin/cp /usr/bin/true "$CONTENTS/MacOS/Switchyard"
/usr/bin/plutil -create xml1 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string Switchyard "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string dev.switchyard.AppcastTest "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleName -string Switchyard "$INFO_PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string 99.0.0 "$INFO_PLIST"
/usr/bin/plutil -insert CFBundleVersion -string 990000 "$INFO_PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 14.0 "$INFO_PLIST"
/usr/bin/plutil -insert SUFeedURL -string https://example.test/appcast.xml "$INFO_PLIST"
/usr/bin/plutil -insert SUPublicEDKey -string "$public_key" "$INFO_PLIST"
/usr/bin/plutil -insert SURequireSignedFeed -bool true "$INFO_PLIST"
/usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$INFO_PLIST"
/usr/bin/codesign --force --sign - "$APP"

"$DMG_CREATOR" \
  --app "$APP" \
  --output "$DMG" \
  --volume-name "Switchyard Appcast Test"
/usr/bin/printf '%s\n' "$private_key" \
  | "$APPCAST_GENERATOR" \
      --dmg "$DMG" \
      --output "$APPCAST" \
      --download-url-prefix "https://example.test/releases/v99.0.0/"

[ -f "$APPCAST" ] || {
  echo "signed appcast was not written to the requested output path" >&2
  exit 1
}
[ ! -e "$ROOT_DIR/appcast.xml" ] || {
  echo "appcast generator wrote outside the requested output path" >&2
  exit 1
}
/usr/bin/xmllint --noout "$APPCAST"
/usr/bin/grep -q 'sparkle:edSignature=' "$APPCAST"
/usr/bin/grep -q '<!-- sparkle-signatures:' "$APPCAST"
/usr/bin/grep -q '^edSignature:' "$APPCAST"

echo "generate_appcast.sh test passed"
