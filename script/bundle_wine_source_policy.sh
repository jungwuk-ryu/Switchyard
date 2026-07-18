#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 SOURCE_CONFIG DESTINATION [SOURCE_REVISION] [BUILD_CONFIGURATION]" >&2
  exit 2
fi

SOURCE_CONFIG="$1"
DESTINATION="$2"
SOURCE_REVISION_OVERRIDE="${3:-}"
BUILD_CONFIGURATION="${4:-debug}"

case "$BUILD_CONFIGURATION" in
  debug|release) ;;
  *) echo "build configuration must be debug or release, got: $BUILD_CONFIGURATION" >&2; exit 2 ;;
esac

if [ ! -f "$SOURCE_CONFIG" ]; then
  echo "missing Switchyard Wine source configuration at $SOURCE_CONFIG" >&2
  exit 1
fi

configured_revision="$(sed -n 's/^SWITCHYARD_WINE_REVISION=//p' "$SOURCE_CONFIG" | tail -n 1)"
source_revision="${SOURCE_REVISION_OVERRIDE:-$configured_revision}"

if [[ ! "$source_revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Switchyard Wine revision must be a full 40-character commit ID, got: $source_revision" >&2
  exit 1
fi

if [ "$BUILD_CONFIGURATION" = "release" ] &&
   [ -n "$SOURCE_REVISION_OVERRIDE" ] &&
   [ "$source_revision" != "$configured_revision" ]; then
  echo "release builds must use the Wine revision and published-runtime attestation in $SOURCE_CONFIG" >&2
  exit 1
fi

mkdir -p "$(dirname "$DESTINATION")"

if [ -z "$SOURCE_REVISION_OVERRIDE" ] || [ "$source_revision" = "$configured_revision" ]; then
  cp "$SOURCE_CONFIG" "$DESTINATION"
  exit 0
fi

temporary_destination="${DESTINATION}.tmp.$$"
cleanup() {
  rm -f "$temporary_destination"
}
trap cleanup EXIT

# A local source override has no matching published-runtime attestation. Keep
# the source identity used by runtime selection, but do not bundle stale release
# metadata that describes the repository's pinned archive.
awk -v revision="$source_revision" '
  /^SWITCHYARD_WINE_REVISION=/ {
    print "SWITCHYARD_WINE_REVISION=" revision
    found_revision = 1
    next
  }
  /^SWITCHYARD_WINE_REVISION_TIMESTAMP=/ { next }
  /^SWITCHYARD_WINE_RELEASE_/ { next }
  /^SWITCHYARD_WINE_DEVELOPER_TEAM_ID=/ { next }
  { print }
  END { if (!found_revision) exit 1 }
' "$SOURCE_CONFIG" >"$temporary_destination"

mv "$temporary_destination" "$DESTINATION"
trap - EXIT
