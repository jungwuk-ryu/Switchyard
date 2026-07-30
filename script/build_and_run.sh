#!/usr/bin/env bash
set -euo pipefail

LAUNCH_OBSERVATION_ATTEMPTS=20
LAUNCH_OBSERVATION_DELAY=0.5

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--help]" >&2
}

trim_process_field() {
  /usr/bin/sed \
    -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//'
}

process_start_identity() {
  local pid="$1"
  /bin/ps -ww -p "$pid" -o lstart= 2>/dev/null | trim_process_field
}

process_executable_path() {
  local pid="$1"
  /bin/ps -ww -p "$pid" -o comm= 2>/dev/null | trim_process_field
}

process_command_line() {
  local pid="$1"
  /bin/ps -ww -p "$pid" -o command= 2>/dev/null | trim_process_field
}

process_state() {
  local pid="$1"
  /bin/ps -ww -p "$pid" -o state= 2>/dev/null | trim_process_field
}

process_matches_launch() {
  local pid="$1"
  local expected_start_identity="$2"
  local expected_executable="$3"
  local launch_argument="$4"
  local current_start_identity
  local current_command_line
  local current_state

  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$(process_executable_path "$pid")" = "$expected_executable" ] || return 1
  current_start_identity="$(process_start_identity "$pid")"
  [ -n "$current_start_identity" ] || return 1
  [ "$current_start_identity" = "$expected_start_identity" ] || return 1
  current_state="$(process_state "$pid")"
  case "$current_state" in
    Z*) return 1 ;;
  esac
  current_command_line="$(process_command_line "$pid")"
  case " $current_command_line " in
    *" $launch_argument "*) return 0 ;;
    *) return 1 ;;
  esac
}

tagged_process_records() {
  local expected_executable="$1"
  local launch_argument="$2"
  local candidate_pid
  local candidate_executable
  local candidate_command_line
  local candidate_start_identity

  while IFS=' ' read -r candidate_pid candidate_executable; do
    [ "$candidate_executable" = "$expected_executable" ] || continue
    candidate_command_line="$(process_command_line "$candidate_pid")"
    case " $candidate_command_line " in
      *" $launch_argument "*) ;;
      *) continue ;;
    esac
    candidate_start_identity="$(process_start_identity "$candidate_pid")"
    [ -n "$candidate_start_identity" ] || continue
    /usr/bin/printf '%s\t%s\n' "$candidate_pid" "$candidate_start_identity"
  done < <(/bin/ps -ww -axo pid=,comm=)
}

wait_for_tagged_process_record() {
  local expected_executable="$1"
  local launch_argument="$2"
  local attempts="${3:-20}"
  local delay="${4:-0.5}"
  local records
  local record_count

  while [ "$attempts" -gt 0 ]; do
    records="$(tagged_process_records "$expected_executable" "$launch_argument")"
    record_count="$(
      /usr/bin/printf '%s\n' "$records" \
        | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }'
    )"
    if [ "$record_count" -eq 1 ]; then
      /usr/bin/printf '%s\n' "$records"
      return 0
    fi
    if [ "$record_count" -gt 1 ]; then
      echo "refusing to select between multiple processes with the same launch identity" >&2
      return 1
    fi
    attempts=$((attempts - 1))
    if [ "$attempts" -gt 0 ]; then
      sleep "$delay"
    fi
  done
  return 1
}

terminate_tagged_process() {
  local pid="$1"
  local start_identity="$2"
  local expected_executable="$3"
  local launch_argument="$4"
  local term_attempts="${5:-30}"
  local kill_attempts="${6:-20}"

  if ! process_matches_launch \
    "$pid" \
    "$start_identity" \
    "$expected_executable" \
    "$launch_argument"; then
    return 0
  fi

  kill -TERM "$pid" >/dev/null 2>&1 || true
  while [ "$term_attempts" -gt 0 ]; do
    if ! process_matches_launch \
      "$pid" \
      "$start_identity" \
      "$expected_executable" \
      "$launch_argument"; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    term_attempts=$((term_attempts - 1))
    sleep 0.1
  done

  kill -KILL "$pid" >/dev/null 2>&1 || true
  while [ "$kill_attempts" -gt 0 ]; do
    if ! process_matches_launch \
      "$pid" \
      "$start_identity" \
      "$expected_executable" \
      "$launch_argument"; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    kill_attempts=$((kill_attempts - 1))
    sleep 0.1
  done

  echo "tracked app process $pid did not exit after SIGKILL" >&2
  return 1
}

cleanup_tracked_app() {
  local exit_status=$?
  local record

  if [ "${CLEANUP_TRACKED_APP_ON_EXIT:-0}" = "1" ]; then
    if [ -z "${TRACKED_APP_PID:-}" ] \
      && [ -n "${TRACKED_APP_EXECUTABLE:-}" ] \
      && [ -n "${TRACKED_APP_LAUNCH_ARGUMENT:-}" ]; then
      record="$(
        wait_for_tagged_process_record \
          "$TRACKED_APP_EXECUTABLE" \
          "$TRACKED_APP_LAUNCH_ARGUMENT" \
          "$LAUNCH_OBSERVATION_ATTEMPTS" \
          "$LAUNCH_OBSERVATION_DELAY" \
          || true
      )"
      if [ -n "$record" ]; then
        TRACKED_APP_PID="${record%%	*}"
        TRACKED_APP_START_IDENTITY="${record#*	}"
      fi
    fi
    if [ -n "${TRACKED_APP_PID:-}" ] \
      && [ -n "${TRACKED_APP_START_IDENTITY:-}" ]; then
      terminate_tagged_process \
        "$TRACKED_APP_PID" \
        "$TRACKED_APP_START_IDENTITY" \
        "$TRACKED_APP_EXECUTABLE" \
        "$TRACKED_APP_LAUNCH_ARGUMENT" \
        || true
    fi
  fi
  return "$exit_status"
}

main() {
MODE="${1:-run}"
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  --help|help|-h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

TRACKED_APP_PID=""
TRACKED_APP_START_IDENTITY=""
TRACKED_APP_EXECUTABLE=""
TRACKED_APP_LAUNCH_ARGUMENT=""
CLEANUP_TRACKED_APP_ON_EXIT=0
trap cleanup_tracked_app EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

APP_NAME="Switchyard"
BUNDLE_ID="dev.switchyard.Switchyard"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${SWITCHYARD_APP_VERSION:-0.4.2}"
APP_BUILD="${SWITCHYARD_APP_BUILD:-8}"
BUILD_CONFIGURATION="${SWITCHYARD_BUILD_CONFIGURATION:-debug}"
case "$BUILD_CONFIGURATION" in
  debug|release) ;;
  *) echo "SWITCHYARD_BUILD_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac
DISABLE_SWIFTPM_SANDBOX="${SWITCHYARD_DISABLE_SWIFTPM_SANDBOX:-0}"
case "$DISABLE_SWIFTPM_SANDBOX" in
  0|1) ;;
  *) echo "SWITCHYARD_DISABLE_SWIFTPM_SANDBOX must be 0 or 1" >&2; exit 2 ;;
esac

IDENTITY_SELECTOR="$ROOT_DIR/script/local_codesign_identity.sh"
SPARKLE_SIGNER="$ROOT_DIR/script/sign_sparkle_framework.sh"
APP_UPDATE_CONFIG="$ROOT_DIR/config/app-update.env"
configured_appcast_url="$(sed -n 's/^SWITCHYARD_APPCAST_URL=//p' "$APP_UPDATE_CONFIG" | tail -n 1)"
configured_sparkle_public_key="$(sed -n 's/^SWITCHYARD_SPARKLE_PUBLIC_KEY=//p' "$APP_UPDATE_CONFIG" | tail -n 1)"
APPCAST_URL="${SWITCHYARD_APPCAST_URL:-$configured_appcast_url}"
SPARKLE_PUBLIC_KEY="${SWITCHYARD_SPARKLE_PUBLIC_KEY:-$configured_sparkle_public_key}"
ENABLE_APP_UPDATES="${SWITCHYARD_ENABLE_APP_UPDATES:-}"
if [ -z "$ENABLE_APP_UPDATES" ]; then
  if [ "$BUILD_CONFIGURATION" = "release" ]; then
    ENABLE_APP_UPDATES=1
  else
    ENABLE_APP_UPDATES=0
  fi
fi
case "$ENABLE_APP_UPDATES" in
  0|1) ;;
  *) echo "SWITCHYARD_ENABLE_APP_UPDATES must be 0 or 1" >&2; exit 2 ;;
esac
if [ "$ENABLE_APP_UPDATES" = "1" ]; then
  [[ "$APPCAST_URL" == https://* ]] || {
    echo "app updates require an HTTPS SWITCHYARD_APPCAST_URL" >&2
    exit 1
  }
  [ -n "$SPARKLE_PUBLIC_KEY" ] || {
    echo "app updates require SWITCHYARD_SPARKLE_PUBLIC_KEY" >&2
    exit 1
  }
fi
if [ -n "${SWITCHYARD_CODESIGN_IDENTITY:-}" ]; then
  LOCAL_CODESIGN_IDENTITY="$("$IDENTITY_SELECTOR" "$SWITCHYARD_CODESIGN_IDENTITY")"
else
  LOCAL_CODESIGN_IDENTITY="$(
    { /usr/bin/security find-identity -p codesigning -v 2>/dev/null || true; } \
      | "$IDENTITY_SELECTOR"
  )"
fi
if [ -z "$LOCAL_CODESIGN_IDENTITY" ]; then
  LOCAL_CODESIGN_IDENTITY="-"
fi

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_THIRD_PARTY_NOTICES="$APP_RESOURCES/ThirdPartyNotices"
APP_BINARY="$APP_MACOS/$APP_NAME"
RUNNER_BINARY="$APP_HELPERS/switchyard-runner"
URL_HANDLER_BINARY="$APP_HELPERS/switchyard-url-handler"
SHORTCUT_HANDLER_BINARY="$APP_HELPERS/switchyard-shortcut-handler"
LOCALIZATION_BUNDLE_NAME="Switchyard_SwitchyardLocalization.bundle"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SPARKLE_FRAMEWORK="$APP_FRAMEWORKS/Sparkle.framework"
APP_ICON_SOURCE="$ROOT_DIR/assets/branding/Switchyard.icns"
APP_ICON="$APP_RESOURCES/Switchyard.icns"
hardware_threads="$(
  /usr/sbin/sysctl -n hw.ncpu 2>/dev/null \
    || /usr/bin/getconf _NPROCESSORS_ONLN 2>/dev/null \
    || /usr/bin/printf '2\n'
)"
case "$hardware_threads" in
  ''|*[!0-9]*) hardware_threads=2 ;;
esac
MAX_SWIFT_BUILD_JOBS=$((hardware_threads > 1 ? hardware_threads - 1 : 1))
SWIFT_BUILD_JOBS="${SWIFT_BUILD_JOBS:-$MAX_SWIFT_BUILD_JOBS}"
if [ "$SWIFT_BUILD_JOBS" -gt "$MAX_SWIFT_BUILD_JOBS" ]; then
  SWIFT_BUILD_JOBS="$MAX_SWIFT_BUILD_JOBS"
elif [ "$SWIFT_BUILD_JOBS" -lt 1 ]; then
  SWIFT_BUILD_JOBS=1
fi
SWIFT_BUILD_OPTIONS=(
  --package-path "$ROOT_DIR"
  -c "$BUILD_CONFIGURATION"
  --jobs "$SWIFT_BUILD_JOBS"
)
if [ "$DISABLE_SWIFTPM_SANDBOX" = "1" ]; then
  SWIFT_BUILD_OPTIONS+=(--disable-sandbox)
fi

[ -f "$APP_ICON_SOURCE" ] || {
  echo "missing app icon: $APP_ICON_SOURCE" >&2
  exit 1
}

if [ "${SWITCHYARD_SKIP_RUNTIME_ENSURE:-0}" != "1" ]; then
  "$ROOT_DIR/script/ensure_wine_runtime.sh"
fi

swift build "${SWIFT_BUILD_OPTIONS[@]}" --product "$APP_NAME"
swift build "${SWIFT_BUILD_OPTIONS[@]}" --product switchyard-runner
swift build "${SWIFT_BUILD_OPTIONS[@]}" --product switchyard-url-handler
swift build "${SWIFT_BUILD_OPTIONS[@]}" --product switchyard-shortcut-handler
BUILD_BIN_PATH="$(swift build "${SWIFT_BUILD_OPTIONS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"
BUILD_RUNNER="$BUILD_BIN_PATH/switchyard-runner"
BUILD_URL_HANDLER="$BUILD_BIN_PATH/switchyard-url-handler"
BUILD_SHORTCUT_HANDLER="$BUILD_BIN_PATH/switchyard-shortcut-handler"
LOCALIZATION_BUNDLE="$BUILD_BIN_PATH/$LOCALIZATION_BUNDLE_NAME"
SPARKLE_FRAMEWORK_SOURCE="$(
  /usr/bin/find "$ROOT_DIR/.build/artifacts" \
    -type d \
    -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' \
    -print \
    -quit
)"
SPARKLE_LICENSE_SOURCE="$(
  /usr/bin/find "$ROOT_DIR/.build/artifacts" \
    -type f \
    -path '*/Sparkle/LICENSE' \
    -print \
    -quit
)"

[ -d "$LOCALIZATION_BUNDLE" ] || {
  echo "missing localization resource bundle: $LOCALIZATION_BUNDLE" >&2
  exit 1
}
[ -d "$SPARKLE_FRAMEWORK_SOURCE" ] || {
  echo "missing Sparkle framework in SwiftPM artifacts" >&2
  exit 1
}
[ -f "$SPARKLE_LICENSE_SOURCE" ] || {
  echo "missing Sparkle license in SwiftPM artifacts" >&2
  exit 1
}

rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_MACOS" \
  "$APP_HELPERS" \
  "$APP_RESOURCES" \
  "$APP_FRAMEWORKS" \
  "$APP_THIRD_PARTY_NOTICES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_RUNNER" "$RUNNER_BINARY"
cp "$BUILD_URL_HANDLER" "$URL_HANDLER_BINARY"
cp "$BUILD_SHORTCUT_HANDLER" "$SHORTCUT_HANDLER_BINARY"
cp "$APP_ICON_SOURCE" "$APP_ICON"
/usr/bin/ditto "$SPARKLE_FRAMEWORK_SOURCE" "$SPARKLE_FRAMEWORK"
cp "$SPARKLE_LICENSE_SOURCE" "$APP_THIRD_PARTY_NOTICES/Sparkle-LICENSE.txt"
cp -R "$LOCALIZATION_BUNDLE" "$APP_RESOURCES/$LOCALIZATION_BUNDLE_NAME"
for localization_directory in "$LOCALIZATION_BUNDLE"/*.lproj; do
  [ -d "$localization_directory" ] || continue
  cp -R "$localization_directory" "$APP_RESOURCES/"
done
"$ROOT_DIR/script/bundle_wine_source_policy.sh" \
  "$ROOT_DIR/config/switchyard-wine.env" \
  "$APP_RESOURCES/switchyard-wine.env" \
  "${SWITCHYARD_WINE_REVISION:-}" \
  "$BUILD_CONFIGURATION"
"$ROOT_DIR/script/bundle_gptk_component_policy.sh" \
  "$ROOT_DIR/config/gptk-component.env" \
  "$APP_RESOURCES/gptk-component.env" \
  "$BUILD_CONFIGURATION"
chmod +x "$APP_BINARY"
chmod +x "$RUNNER_BINARY"
chmod +x "$URL_HANDLER_BINARY"
chmod +x "$SHORTCUT_HANDLER_BINARY"

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
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ko</string>
    <string>zh-Hans</string>
    <string>zh-Hant</string>
    <string>ja</string>
    <string>ru</string>
    <string>de</string>
    <string>fr</string>
    <string>es</string>
    <string>pt-BR</string>
  </array>
  <key>CFBundleIconFile</key>
  <string>Switchyard.icns</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>SwitchyardBuildConfiguration</key>
  <string>$BUILD_CONFIGURATION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Windows Executable</string>
      <key>CFBundleTypeRole</key>
      <string>Shell</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.microsoft.windows-executable</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Windows Installer Package</string>
      <key>CFBundleTypeRole</key>
      <string>Shell</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>msi</string>
      </array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [ "$ENABLE_APP_UPDATES" = "1" ]; then
  /usr/bin/plutil -insert SwitchyardUpdatesEnabled -bool true "$INFO_PLIST"
  /usr/bin/plutil -insert SUFeedURL -string "$APPCAST_URL" "$INFO_PLIST"
  /usr/bin/plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$INFO_PLIST"
  /usr/bin/plutil -insert SURequireSignedFeed -bool true "$INFO_PLIST"
  /usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$INFO_PLIST"
  /usr/bin/plutil -insert SUSignedFeedFailureExpirationInterval -integer 0 "$INFO_PLIST"
  /usr/bin/plutil -insert SUEnableAutomaticChecks -bool false "$INFO_PLIST"
  /usr/bin/plutil -insert SUAllowsAutomaticUpdates -bool true "$INFO_PLIST"
  /usr/bin/plutil -insert SUAutomaticallyUpdate -bool true "$INFO_PLIST"
  /usr/bin/plutil -insert SUEnableSystemProfiling -bool false "$INFO_PLIST"
else
  /usr/bin/plutil -insert SwitchyardUpdatesEnabled -bool false "$INFO_PLIST"
fi

if ! /usr/bin/otool -l "$APP_BINARY" \
  | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
  /usr/bin/install_name_tool \
    -add_rpath '@executable_path/../Frameworks' \
    "$APP_BINARY"
fi

"$SPARKLE_SIGNER" \
  --framework "$SPARKLE_FRAMEWORK" \
  --identity "$LOCAL_CODESIGN_IDENTITY"
for helper_binary in \
  "$RUNNER_BINARY" \
  "$URL_HANDLER_BINARY" \
  "$SHORTCUT_HANDLER_BINARY"; do
  /usr/bin/codesign --force --sign "$LOCAL_CODESIGN_IDENTITY" "$helper_binary" >/dev/null
done
/usr/bin/codesign --force --sign "$LOCAL_CODESIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

if [ "$LOCAL_CODESIGN_IDENTITY" = "-" ]; then
  echo "warning: no persistent code-signing identity is available; macOS may require Screen Recording permission again after a rebuild" >&2
else
  echo "signed local app with persistent identity: $LOCAL_CODESIGN_IDENTITY"
fi

open_app_and_track() {
  local launch_token
  local record

  launch_token="$(/usr/bin/uuidgen)"
  TRACKED_APP_EXECUTABLE="$APP_BINARY"
  TRACKED_APP_LAUNCH_ARGUMENT="--switchyard-launch-token=$launch_token"
  CLEANUP_TRACKED_APP_ON_EXIT=1

  /usr/bin/open \
    -n \
    "$APP_BUNDLE" \
    --args \
    "$TRACKED_APP_LAUNCH_ARGUMENT"

  record="$(
    wait_for_tagged_process_record \
      "$TRACKED_APP_EXECUTABLE" \
      "$TRACKED_APP_LAUNCH_ARGUMENT" \
      "$LAUNCH_OBSERVATION_ATTEMPTS" \
      "$LAUNCH_OBSERVATION_DELAY" \
      || true
  )"
  if [ -z "$record" ]; then
    echo "$APP_NAME did not start with the expected bundle executable within 10 seconds" >&2
    return 1
  fi

  TRACKED_APP_PID="${record%%	*}"
  TRACKED_APP_START_IDENTITY="${record#*	}"
}

case "$MODE" in
  run)
    open_app_and_track
    CLEANUP_TRACKED_APP_ON_EXIT=0
    ;;
  --debug|debug)
    open_app_and_track
    lldb -p "$TRACKED_APP_PID"
    CLEANUP_TRACKED_APP_ON_EXIT=0
    ;;
  --logs|logs)
    open_app_and_track
    /usr/bin/log stream \
      --info \
      --style compact \
      --predicate "processIdentifier == $TRACKED_APP_PID"
    CLEANUP_TRACKED_APP_ON_EXIT=0
    ;;
  --telemetry|telemetry)
    open_app_and_track
    /usr/bin/log stream \
      --info \
      --style compact \
      --predicate "processIdentifier == $TRACKED_APP_PID AND subsystem == \"$BUNDLE_ID\""
    CLEANUP_TRACKED_APP_ON_EXIT=0
    ;;
  --verify|verify)
    open_app_and_track
    if ! terminate_tagged_process \
      "$TRACKED_APP_PID" \
      "$TRACKED_APP_START_IDENTITY" \
      "$TRACKED_APP_EXECUTABLE" \
      "$TRACKED_APP_LAUNCH_ARGUMENT"; then
      exit 1
    fi
    TRACKED_APP_PID=""
    TRACKED_APP_START_IDENTITY=""
    CLEANUP_TRACKED_APP_ON_EXIT=0
    ;;
esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
