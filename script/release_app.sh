#!/usr/bin/env bash
set -euo pipefail

APP=""
OUTPUT_DIR=""
IDENTITY=""
NOTARY_PROFILE=""
NOTARY_KEYCHAIN=""

usage() {
  echo "usage: $0 --app APP --output DIR --identity IDENTITY --notary-profile PROFILE [--notary-keychain PATH]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    --notary-keychain) NOTARY_KEYCHAIN="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[ -d "$APP" ] || usage
[ -n "$OUTPUT_DIR" ] || usage
[ -n "$IDENTITY" ] || usage
[ -n "$NOTARY_PROFILE" ] || usage
[ -f "$APP/Contents/Info.plist" ] || {
  echo "app Info.plist is missing" >&2
  exit 1
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sparkle_signer="$root_dir/script/sign_sparkle_framework.sh"
dmg_creator="$root_dir/script/create_dmg.sh"
app_name="$(/usr/bin/basename "$APP")"
app_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
build_configuration="$(/usr/bin/plutil -extract SwitchyardBuildConfiguration raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
updates_enabled="$(/usr/bin/plutil -extract SwitchyardUpdatesEnabled raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
feed_url="$(/usr/bin/plutil -extract SUFeedURL raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
requires_signed_feed="$(/usr/bin/plutil -extract SURequireSignedFeed raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
verifies_before_extraction="$(/usr/bin/plutil -extract SUVerifyUpdateBeforeExtraction raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
allows_automatic_updates="$(/usr/bin/plutil -extract SUAllowsAutomaticUpdates raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
automatically_updates="$(/usr/bin/plutil -extract SUAutomaticallyUpdate raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
automatic_checks="$(/usr/bin/plutil -extract SUEnableAutomaticChecks raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$bundle_identifier" = "dev.switchyard.Switchyard" ] || {
  echo "release app has an unexpected bundle identifier: $bundle_identifier" >&2
  exit 1
}
[ "$build_configuration" = "release" ] || {
  echo "release packaging requires an app built with SWITCHYARD_BUILD_CONFIGURATION=release" >&2
  exit 1
}
[ "$updates_enabled" = "true" ] || {
  echo "release packaging requires Switchyard app updates to be enabled" >&2
  exit 1
}
[[ "$feed_url" == https://* ]] || {
  echo "release app requires an HTTPS Sparkle feed" >&2
  exit 1
}
public_key_size="$(
  {
    /usr/bin/printf '%s' "$public_key" \
      | /usr/bin/base64 --decode 2>/dev/null || true
  } | /usr/bin/wc -c | /usr/bin/tr -d ' '
)"
[ "$public_key_size" = "32" ] || {
  echo "release app requires a 32-byte Ed25519 public key" >&2
  exit 1
}
for secure_update_setting in \
  "$requires_signed_feed" \
  "$verifies_before_extraction" \
  "$allows_automatic_updates" \
  "$automatically_updates"; do
  [ "$secure_update_setting" = "true" ] || {
    echo "release app is missing a required secure update setting" >&2
    exit 1
  }
done
[ "$automatic_checks" = "false" ] || {
  echo "release app must leave automatic scheduling to SwitchyardUpdater" >&2
  exit 1
}
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || {
  echo "release app does not contain Sparkle.framework" >&2
  exit 1
}

app_binary="$APP/Contents/MacOS/${app_name%.app}"
architectures="$(/usr/bin/lipo -archs "$app_binary")"
case " $architectures " in
  *" arm64 "*) ;;
  *)
    echo "release app does not contain the required arm64 architecture: $architectures" >&2
    exit 1
    ;;
esac

/bin/mkdir -p "$OUTPUT_DIR"
output_dir="$(cd "$OUTPUT_DIR" && pwd)"
signed_app="$output_dir/$app_name"
dmg_name="${app_name%.app}-${app_version}-macos-arm64.dmg"
dmg="$output_dir/$dmg_name"
checksum="$dmg.sha256"
for destination in "$signed_app" "$dmg" "$checksum"; do
  [ ! -e "$destination" ] || {
    echo "release output already exists: $destination" >&2
    exit 1
  }
done

temporary_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/switchyard-release.XXXXXX")"
mounted_dmg=0
mount_root="$temporary_root/mount"

cleanup() {
  if [ "$mounted_dmg" = "1" ]; then
    /usr/bin/hdiutil detach -quiet "$mount_root" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$temporary_root"
}
trap cleanup EXIT

submit_for_notarization() {
  local artifact="$1"
  local result_file="$2"
  local notary_arguments=(
    notarytool
    submit
    "$artifact"
    --keychain-profile "$NOTARY_PROFILE"
    --wait
    --output-format json
  )
  if [ -n "$NOTARY_KEYCHAIN" ]; then
    notary_arguments+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  /usr/bin/xcrun "${notary_arguments[@]}" > "$result_file"

  local notary_status
  local notary_id
  notary_status="$(/usr/bin/plutil -extract status raw -o - "$result_file")"
  notary_id="$(/usr/bin/plutil -extract id raw -o - "$result_file")"
  [ "$notary_status" = "Accepted" ] || {
    echo "Apple notarization did not accept $(/usr/bin/basename "$artifact"): $notary_status ($notary_id)" >&2
    exit 1
  }
  LAST_NOTARY_ID="$notary_id"
}

echo "copying app into release staging"
/usr/bin/ditto "$APP" "$signed_app"

echo "signing app executables and Sparkle helpers"
while IFS= read -r -d '' helper; do
  if /usr/bin/file -b "$helper" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign \
      --force \
      --sign "$IDENTITY" \
      --options runtime \
      --timestamp \
      "$helper"
  fi
done < <(/usr/bin/find "$signed_app/Contents/Helpers" -type f -print0)

"$sparkle_signer" \
  --framework "$signed_app/Contents/Frameworks/Sparkle.framework" \
  --identity "$IDENTITY" \
  --distribution
/usr/bin/codesign \
  --force \
  --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  "$signed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$signed_app"

echo "notarizing and stapling app"
notary_archive="$temporary_root/${app_name%.app}-notary.zip"
app_notary_result="$temporary_root/app-notary.json"
/usr/bin/ditto \
  -c \
  -k \
  --sequesterRsrc \
  --keepParent \
  "$signed_app" \
  "$notary_archive"
submit_for_notarization "$notary_archive" "$app_notary_result"
app_notary_id="$LAST_NOTARY_ID"
/usr/bin/xcrun stapler staple "$signed_app"
/usr/bin/xcrun stapler validate "$signed_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$signed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$signed_app"

echo "creating drag-to-Applications DMG"
"$dmg_creator" \
  --app "$signed_app" \
  --output "$dmg" \
  --volume-name "Switchyard $app_version"
/usr/bin/codesign \
  --force \
  --sign "$IDENTITY" \
  --timestamp \
  "$dmg"
/usr/bin/codesign --verify --strict --verbose=2 "$dmg"

echo "notarizing and stapling DMG"
dmg_notary_result="$temporary_root/dmg-notary.json"
submit_for_notarization "$dmg" "$dmg_notary_result"
dmg_notary_id="$LAST_NOTARY_ID"
/usr/bin/xcrun stapler staple "$dmg"
/usr/bin/xcrun stapler validate "$dmg"
/usr/bin/hdiutil verify "$dmg"
/usr/bin/codesign --verify --strict --verbose=2 "$dmg"
/usr/sbin/spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$dmg"

echo "validating installed app payload"
/bin/mkdir -p "$mount_root"
/usr/bin/hdiutil attach \
  -quiet \
  -readonly \
  -nobrowse \
  -mountpoint "$mount_root" \
  "$dmg"
mounted_dmg=1
mounted_app="$mount_root/$app_name"
[ -d "$mounted_app" ] || {
  echo "notarized DMG does not contain $app_name" >&2
  exit 1
}
[ -L "$mount_root/Applications" ] || {
  echo "notarized DMG does not contain an Applications symlink" >&2
  exit 1
}
[ "$(/usr/bin/readlink "$mount_root/Applications")" = "/Applications" ] || {
  echo "notarized DMG Applications link does not target /Applications" >&2
  exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mounted_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$mounted_app"
/usr/bin/hdiutil detach -quiet "$mount_root"
mounted_dmg=0

dmg_sha256="$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$dmg_sha256" "$dmg_name" > "$checksum"

echo "app release DMG: $dmg"
echo "DMG sha256: $dmg_sha256"
echo "app notarization: Accepted ($app_notary_id)"
echo "DMG notarization: Accepted ($dmg_notary_id)"
