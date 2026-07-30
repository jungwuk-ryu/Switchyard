#!/usr/bin/env bash
set -euo pipefail

DMG=""
OUTPUT=""
DOWNLOAD_URL_PREFIX=""
PRODUCT_LINK="https://github.com/jungwuk-ryu/Switchyard"
RELEASE_NOTES=""
REQUESTED_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
unset SPARKLE_ED_PRIVATE_KEY

fail() {
  echo "$1" >&2
  exit 1
}

plist_raw_value() {
  local plist="$1"
  local key_path="$2"
  /usr/bin/plutil -extract "$key_path" raw -o - "$plist" 2>/dev/null
}

path_has_trusted_permissions() {
  local path="$1"
  local owner mode
  owner="$(/usr/bin/stat -f '%u' "$path")" || return 1
  mode="$(/usr/bin/stat -f '%Lp' "$path")" || return 1
  case "$owner" in
    0|"$(/usr/bin/id -u)") ;;
    *) return 1 ;;
  esac
  case "$mode" in
    ""|*[!0-7]*) return 1 ;;
  esac
  (( (8#$mode & 0022) == 0 ))
}

require_trusted_directory() {
  local path="$1"
  if [ -L "$path" ] ||
    [ ! -d "$path" ] ||
    ! path_has_trusted_permissions "$path"; then
    fail "untrusted Sparkle artifact directory: $path"
  fi
}

require_trusted_regular_file() {
  local path="$1"
  if [ -L "$path" ] ||
    [ ! -f "$path" ] ||
    [ "$(/usr/bin/stat -f '%l' "$path")" -ne 1 ] ||
    ! path_has_trusted_permissions "$path"; then
    fail "untrusted Sparkle artifact file: $path"
  fi
}

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
    --tool) REQUESTED_GENERATE_APPCAST="${2:-}"; shift 2 ;;
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

project_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
resolved_file="$project_root/Package.resolved"
workspace_state="$project_root/.build/workspace-state.json"

require_trusted_directory "$project_root"
require_trusted_regular_file "$resolved_file"
require_trusted_directory "$project_root/.build"
require_trusted_directory "$project_root/.build/artifacts"
require_trusted_regular_file "$workspace_state"

if ! resolved_pin_count="$(plist_raw_value "$resolved_file" pins)"; then
  fail "Package.resolved does not contain dependency pins"
fi
[[ "$resolved_pin_count" =~ ^[0-9]+$ ]] ||
  fail "Package.resolved dependency pins are invalid"

sparkle_pin_count=0
sparkle_identity=""
sparkle_version=""
sparkle_revision=""
for ((pin_index = 0; pin_index < resolved_pin_count; pin_index += 1)); do
  identity="$(plist_raw_value "$resolved_file" "pins.$pin_index.identity" || true)"
  [ "$identity" = "sparkle" ] || continue
  sparkle_pin_count=$((sparkle_pin_count + 1))
  sparkle_identity="$identity"
  sparkle_location="$(plist_raw_value "$resolved_file" "pins.$pin_index.location" || true)"
  sparkle_kind="$(plist_raw_value "$resolved_file" "pins.$pin_index.kind" || true)"
  sparkle_version="$(plist_raw_value "$resolved_file" "pins.$pin_index.state.version" || true)"
  sparkle_revision="$(plist_raw_value "$resolved_file" "pins.$pin_index.state.revision" || true)"
done

[ "$sparkle_pin_count" -eq 1 ] ||
  fail "Package.resolved must contain exactly one Sparkle pin"
[ "$sparkle_location" = "https://github.com/sparkle-project/Sparkle" ] &&
  [ "$sparkle_kind" = "remoteSourceControl" ] &&
  [[ "$sparkle_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
  [[ "$sparkle_revision" =~ ^[[:xdigit:]]{40}$ ]] || {
    fail "Package.resolved contains an unsupported Sparkle pin"
  }

if ! workspace_dependency_count="$(plist_raw_value "$workspace_state" object.dependencies)"; then
  fail "SwiftPM workspace state does not contain dependencies"
fi
[[ "$workspace_dependency_count" =~ ^[0-9]+$ ]] ||
  fail "SwiftPM workspace dependency state is invalid"

matching_workspace_dependencies=0
for ((dependency_index = 0; dependency_index < workspace_dependency_count; dependency_index += 1)); do
  identity="$(
    plist_raw_value \
      "$workspace_state" \
      "object.dependencies.$dependency_index.packageRef.identity" || true
  )"
  [ "$identity" = "$sparkle_identity" ] || continue
  matching_workspace_dependencies=$((matching_workspace_dependencies + 1))
  workspace_location="$(
    plist_raw_value \
      "$workspace_state" \
      "object.dependencies.$dependency_index.packageRef.location" || true
  )"
  workspace_version="$(
    plist_raw_value \
      "$workspace_state" \
      "object.dependencies.$dependency_index.state.checkoutState.version" || true
  )"
  workspace_revision="$(
    plist_raw_value \
      "$workspace_state" \
      "object.dependencies.$dependency_index.state.checkoutState.revision" || true
  )"
done

[ "$matching_workspace_dependencies" -eq 1 ] &&
  [ "$workspace_location" = "$sparkle_location" ] &&
  [ "$workspace_version" = "$sparkle_version" ] &&
  [ "$workspace_revision" = "$sparkle_revision" ] || {
    fail "SwiftPM Sparkle dependency does not match Package.resolved"
  }

if ! workspace_artifact_count="$(plist_raw_value "$workspace_state" object.artifacts)"; then
  fail "SwiftPM workspace state does not contain binary artifacts"
fi
[[ "$workspace_artifact_count" =~ ^[0-9]+$ ]] ||
  fail "SwiftPM workspace artifact state is invalid"

matching_sparkle_artifacts=0
sparkle_artifact_path=""
sparkle_artifact_url=""
sparkle_artifact_checksum=""
for ((artifact_index = 0; artifact_index < workspace_artifact_count; artifact_index += 1)); do
  identity="$(
    plist_raw_value \
      "$workspace_state" \
      "object.artifacts.$artifact_index.packageRef.identity" || true
  )"
  target_name="$(
    plist_raw_value \
      "$workspace_state" \
      "object.artifacts.$artifact_index.targetName" || true
  )"
  [ "$identity" = "$sparkle_identity" ] && [ "$target_name" = "Sparkle" ] || continue
  matching_sparkle_artifacts=$((matching_sparkle_artifacts + 1))
  artifact_location="$(
    plist_raw_value \
      "$workspace_state" \
      "object.artifacts.$artifact_index.packageRef.location" || true
  )"
  sparkle_artifact_path="$(
    plist_raw_value "$workspace_state" "object.artifacts.$artifact_index.path" || true
  )"
  sparkle_artifact_url="$(
    plist_raw_value "$workspace_state" "object.artifacts.$artifact_index.source.url" || true
  )"
  sparkle_artifact_checksum="$(
    plist_raw_value "$workspace_state" "object.artifacts.$artifact_index.source.checksum" || true
  )"
done

sparkle_artifact_root="$project_root/.build/artifacts/$sparkle_identity/Sparkle"
expected_artifact_path="$sparkle_artifact_root/Sparkle.xcframework"
expected_artifact_url="https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-for-Swift-Package-Manager.zip"
GENERATE_APPCAST="$sparkle_artifact_root/bin/generate_appcast"

[ "$matching_sparkle_artifacts" -eq 1 ] &&
  [ "$artifact_location" = "$sparkle_location" ] &&
  [ "$sparkle_artifact_path" = "$expected_artifact_path" ] &&
  [ "$sparkle_artifact_url" = "$expected_artifact_url" ] &&
  [[ "$sparkle_artifact_checksum" =~ ^[[:xdigit:]]{64}$ ]] || {
    fail "SwiftPM Sparkle artifact does not match Package.resolved"
  }

require_trusted_directory "$project_root/.build/artifacts/$sparkle_identity"
require_trusted_directory "$sparkle_artifact_root"
require_trusted_directory "$expected_artifact_path"
require_trusted_directory "$sparkle_artifact_root/bin"
require_trusted_regular_file "$GENERATE_APPCAST"
[ -x "$GENERATE_APPCAST" ] ||
  fail "Sparkle generate_appcast tool is not executable"

candidate_paths=()
artifact_discovery_failed=0
while IFS= read -r -d '' candidate_path; do
  if [ -z "$candidate_path" ]; then
    artifact_discovery_failed=1
  else
    candidate_paths[${#candidate_paths[@]}]="$candidate_path"
  fi
done < <(
  /usr/bin/find \
    "$project_root/.build/artifacts" \
    -name generate_appcast \
    -print0 2>/dev/null ||
    /usr/bin/printf '\0'
)

[ "$artifact_discovery_failed" -eq 0 ] &&
  [ "${#candidate_paths[@]}" -eq 1 ] &&
  [ "${candidate_paths[0]}" = "$GENERATE_APPCAST" ] || {
    fail "Sparkle artifact tree contains an ambiguous generate_appcast tool"
  }

if [ -n "$REQUESTED_GENERATE_APPCAST" ] &&
  [ "$REQUESTED_GENERATE_APPCAST" != "$GENERATE_APPCAST" ]; then
  fail "only the resolved SwiftPM generate_appcast tool is allowed"
fi

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
