#!/usr/bin/env bash
set -euo pipefail

APP=""
OUTPUT=""
VOLUME_NAME=""

usage() {
  echo "usage: $0 --app APP --output DMG --volume-name NAME" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --volume-name) VOLUME_NAME="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[ -d "$APP" ] || usage
[ -f "$APP/Contents/Info.plist" ] || {
  echo "app Info.plist is missing" >&2
  exit 1
}
[ -n "$OUTPUT" ] || usage
[ "${OUTPUT##*.}" = "dmg" ] || {
  echo "DMG output must use the .dmg extension" >&2
  exit 1
}
[ -n "$VOLUME_NAME" ] || usage
[ ! -e "$OUTPUT" ] || {
  echo "DMG output already exists: $OUTPUT" >&2
  exit 1
}

output_parent="$(cd "$(dirname "$OUTPUT")" && pwd)"
output_path="$output_parent/$(basename "$OUTPUT")"
temporary_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/switchyard-dmg.XXXXXX")"
content_root="$temporary_root/content"
mount_root="$temporary_root/mount"
mounted=0

cleanup() {
  if [ "$mounted" = "1" ]; then
    /usr/bin/hdiutil detach -quiet "$mount_root" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$temporary_root"
}
trap cleanup EXIT

/bin/mkdir -p "$content_root" "$mount_root"
app_name="$(/usr/bin/basename "$APP")"
/usr/bin/ditto "$APP" "$content_root/$app_name"
/bin/ln -s /Applications "$content_root/Applications"

/usr/bin/hdiutil create \
  -quiet \
  -fs HFS+ \
  -format UDZO \
  -volname "$VOLUME_NAME" \
  -srcfolder "$content_root" \
  "$output_path"
/usr/bin/hdiutil verify "$output_path"

/usr/bin/hdiutil attach \
  -quiet \
  -readonly \
  -nobrowse \
  -mountpoint "$mount_root" \
  "$output_path"
mounted=1

[ -d "$mount_root/$app_name" ] || {
  echo "DMG does not contain $app_name" >&2
  exit 1
}
[ -L "$mount_root/Applications" ] || {
  echo "DMG does not contain an Applications symlink" >&2
  exit 1
}
[ "$(/usr/bin/readlink "$mount_root/Applications")" = "/Applications" ] || {
  echo "DMG Applications link does not target /Applications" >&2
  exit 1
}

/usr/bin/hdiutil detach -quiet "$mount_root"
mounted=0
echo "created DMG: $output_path"
