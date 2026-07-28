#!/usr/bin/env bash
set -euo pipefail

DMG=""
OUTPUT=""
DOWNLOAD_URL_PREFIX=""
PRODUCT_LINK="https://github.com/jungwuk-ryu/Switchyard"
RELEASE_NOTES=""
GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"

usage() {
  echo "usage: $0 --dmg DMG --output XML --download-url-prefix URL [--link URL] [--release-notes FILE] [--tool GENERATE_APPCAST]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dmg) DMG="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --download-url-prefix) DOWNLOAD_URL_PREFIX="${2:-}"; shift 2 ;;
    --link) PRODUCT_LINK="${2:-}"; shift 2 ;;
    --release-notes) RELEASE_NOTES="${2:-}"; shift 2 ;;
    --tool) GENERATE_APPCAST="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[ -f "$DMG" ] || usage
[ -n "$OUTPUT" ] || usage
[ ! -e "$OUTPUT" ] || {
  echo "appcast output already exists: $OUTPUT" >&2
  exit 1
}
[[ "$DOWNLOAD_URL_PREFIX" == https://* ]] || {
  echo "download URL prefix must use HTTPS" >&2
  exit 1
}
[[ "$PRODUCT_LINK" == https://* ]] || {
  echo "product link must use HTTPS" >&2
  exit 1
}
if [ -n "$RELEASE_NOTES" ]; then
  [ -f "$RELEASE_NOTES" ] || usage
fi

if [ -z "$GENERATE_APPCAST" ]; then
  project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  GENERATE_APPCAST="$(
    /usr/bin/find "$project_root/.build/artifacts" \
      -type f \
      -name generate_appcast \
      -perm -111 \
      -print \
      -quit 2>/dev/null
  )"
fi
[ -x "$GENERATE_APPCAST" ] || {
  echo "Sparkle generate_appcast tool was not found" >&2
  exit 1
}

output_parent="$(cd "$(dirname "$OUTPUT")" && pwd)"
output_path="$output_parent/$(basename "$OUTPUT")"
temporary_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/switchyard-appcast.XXXXXX")"

cleanup() {
  /bin/rm -rf "$temporary_root"
}
trap cleanup EXIT

dmg_name="$(/usr/bin/basename "$DMG")"
/bin/cp "$DMG" "$temporary_root/$dmg_name"
if [ -n "$RELEASE_NOTES" ]; then
  notes_extension="${RELEASE_NOTES##*.}"
  /bin/cp \
    "$RELEASE_NOTES" \
    "$temporary_root/${dmg_name%.dmg}.$notes_extension"
fi

"$GENERATE_APPCAST" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$PRODUCT_LINK" \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$temporary_root/appcast.xml" \
  "$temporary_root"

generated_appcast="$temporary_root/appcast.xml"
[ -f "$generated_appcast" ] || {
  echo "Sparkle did not generate an appcast" >&2
  exit 1
}
/usr/bin/xmllint --noout "$generated_appcast"
/usr/bin/grep -q 'sparkle:edSignature=' "$generated_appcast" || {
  echo "appcast enclosure is missing its EdDSA signature" >&2
  exit 1
}
/usr/bin/grep -q '<!-- sparkle-signatures:' "$generated_appcast" || {
  echo "appcast feed is missing its signed-feed block" >&2
  exit 1
}
/usr/bin/grep -q '^edSignature:' "$generated_appcast" || {
  echo "appcast feed is missing its signed-feed signature" >&2
  exit 1
}

/bin/mv "$generated_appcast" "$output_path"
echo "generated signed appcast: $output_path"
