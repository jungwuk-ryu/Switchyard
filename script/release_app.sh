#!/usr/bin/env bash
set -euo pipefail

APP=""
OUTPUT_DIR=""
IDENTITY=""
NOTARY_PROFILE=""

usage() {
  echo "usage: $0 --app APP --output DIR --identity IDENTITY --notary-profile PROFILE" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[ -d "$APP" ] || usage
[ -n "$OUTPUT_DIR" ] || usage
[ -n "$IDENTITY" ] || usage
[ -n "$NOTARY_PROFILE" ] || usage
[ -f "$APP/Contents/Info.plist" ] || { echo "app Info.plist is missing" >&2; exit 1; }

app_name="$(/usr/bin/basename "$APP")"
app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
build_configuration="$(/usr/bin/plutil -extract SwitchyardBuildConfiguration raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$build_configuration" = "release" ] || {
  echo "release packaging requires an app built with SWITCHYARD_BUILD_CONFIGURATION=release" >&2
  exit 1
}
archive_name="${app_name%.app}-${app_version}-developer-id.zip"
signed_app="$OUTPUT_DIR/$app_name"
archive="$OUTPUT_DIR/$archive_name"
checksum="$archive.sha256"

/bin/mkdir -p "$OUTPUT_DIR"
for destination in "$signed_app" "$archive" "$checksum"; do
  [ ! -e "$destination" ] || {
    echo "release output already exists: $destination" >&2
    exit 1
  }
done

echo "copying app into release staging"
/bin/cp -cR "$APP" "$signed_app"

echo "signing app executables"
while IFS= read -r -d '' item; do
  if /usr/bin/file -b "$item" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp "$item"
  fi
done < <(/usr/bin/find "$signed_app/Contents" -type f -print0)
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp "$signed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$signed_app"

echo "submitting app for notarization"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$signed_app" "$archive"
notary_result="$(/usr/bin/mktemp)"
cleanup() {
  /bin/rm -f "$notary_result"
}
trap cleanup EXIT
/usr/bin/xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format json > "$notary_result"
notary_status="$(/usr/bin/plutil -extract status raw -o - "$notary_result")"
notary_id="$(/usr/bin/plutil -extract id raw -o - "$notary_result")"
[ "$notary_status" = "Accepted" ] || {
  echo "Apple notarization did not accept the app: $notary_status ($notary_id)" >&2
  exit 1
}

/usr/bin/xcrun stapler staple "$signed_app"
/usr/bin/xcrun stapler validate "$signed_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$signed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$signed_app"

/bin/rm -f "$archive"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$signed_app" "$archive"
archive_sha256="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$archive_sha256" "$archive_name" > "$checksum"

echo "app release archive: $archive"
echo "app archive sha256: $archive_sha256"
echo "app notarization: $notary_status ($notary_id)"
