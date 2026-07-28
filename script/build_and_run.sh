#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Switchyard"
BUNDLE_ID="dev.switchyard.Switchyard"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${SWITCHYARD_APP_VERSION:-0.3.2}"
APP_BUILD="${SWITCHYARD_APP_BUILD:-5}"
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  -c "$BUILD_CONFIGURATION"
  --jobs "$SWIFT_BUILD_JOBS"
)
if [ "$DISABLE_SWIFTPM_SANDBOX" = "1" ]; then
  SWIFT_BUILD_OPTIONS+=(--disable-sandbox)
fi

if [ "${SWITCHYARD_SKIP_RUNTIME_ENSURE:-0}" != "1" ]; then
  "$ROOT_DIR/script/ensure_wine_runtime.sh"
fi

[ -f "$APP_ICON_SOURCE" ] || {
  echo "missing app icon: $APP_ICON_SOURCE" >&2
  exit 1
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

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

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

wait_for_app_pid() {
  local app_pid=""
  for _ in {1..20}; do
    app_pid="$(pgrep -x "$APP_NAME" | tail -n 1 || true)"
    if [ -n "$app_pid" ]; then
      /usr/bin/printf '%s\n' "$app_pid"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    open_app
    debug_pid="$(wait_for_app_pid || true)"
    if [ -z "$debug_pid" ]; then
      echo "$APP_NAME did not start within 10 seconds" >&2
      exit 1
    fi
    lldb -p "$debug_pid"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verified_pid="$(wait_for_app_pid || true)"
    if [ -z "$verified_pid" ]; then
      echo "$APP_NAME did not start within 10 seconds" >&2
      exit 1
    fi
    kill "$verified_pid" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
