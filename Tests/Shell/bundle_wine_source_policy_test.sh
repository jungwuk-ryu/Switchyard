#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLER="$ROOT_DIR/script/bundle_wine_source_policy.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-wine-policy-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

SOURCE_CONFIG="$TEMP_ROOT/switchyard-wine.env"
DESTINATION="$TEMP_ROOT/bundled.env"
PINNED_REVISION="1111111111111111111111111111111111111111"
LOCAL_REVISION="2222222222222222222222222222222222222222"

cat >"$SOURCE_CONFIG" <<CONFIG
SWITCHYARD_WINE_REPOSITORY=https://example.invalid/switchyard-wine
SWITCHYARD_WINE_REVISION=$PINNED_REVISION
SWITCHYARD_WINE_REVISION_TIMESTAMP=1784282993
SWITCHYARD_WINE_HISTORY_DEPTH=256
SWITCHYARD_WINE_RELEASE_MANIFEST_URL=https://example.invalid/runtime.json
SWITCHYARD_WINE_DEVELOPER_TEAM_ID=TEAMID
SWITCHYARD_WINE_RELEASE_ARCHIVE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SWITCHYARD_WINE_RELEASE_ARCHIVE_SIZE=123
SWITCHYARD_WINE_RELEASE_NOTARIZATION_ID=notarization-id
CONFIG

"$BUNDLER" "$SOURCE_CONFIG" "$DESTINATION"
cmp "$SOURCE_CONFIG" "$DESTINATION"

"$BUNDLER" "$SOURCE_CONFIG" "$DESTINATION" "$PINNED_REVISION"
cmp "$SOURCE_CONFIG" "$DESTINATION"

"$BUNDLER" "$SOURCE_CONFIG" "$DESTINATION" "$LOCAL_REVISION"
grep -Fx "SWITCHYARD_WINE_REVISION=$LOCAL_REVISION" "$DESTINATION" >/dev/null
grep -Fx 'SWITCHYARD_WINE_HISTORY_DEPTH=256' "$DESTINATION" >/dev/null
if grep -q '^SWITCHYARD_WINE_REVISION_TIMESTAMP=' "$DESTINATION"; then
  echo "local source policy retained the pinned revision timestamp" >&2
  exit 1
fi
if grep -Eq '^SWITCHYARD_WINE_(RELEASE_|DEVELOPER_TEAM_ID=)' "$DESTINATION"; then
  echo "local source policy retained stale published-runtime metadata" >&2
  exit 1
fi

if "$BUNDLER" "$SOURCE_CONFIG" "$DESTINATION" not-a-revision >/dev/null 2>&1; then
  echo "invalid source revision was accepted" >&2
  exit 1
fi

if "$BUNDLER" "$SOURCE_CONFIG" "$DESTINATION" "$LOCAL_REVISION" release >/dev/null 2>&1; then
  echo "release build accepted a Wine revision without matching attestation" >&2
  exit 1
fi

"$BUNDLER" "$SOURCE_CONFIG" "$DESTINATION" "$PINNED_REVISION" release
cmp "$SOURCE_CONFIG" "$DESTINATION"

echo "Bundled Wine source policy tests passed"
