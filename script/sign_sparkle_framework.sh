#!/usr/bin/env bash
set -euo pipefail

FRAMEWORK=""
IDENTITY=""
DISTRIBUTION=0

usage() {
  echo "usage: $0 --framework PATH --identity IDENTITY [--distribution]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --framework) FRAMEWORK="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --distribution) DISTRIBUTION=1; shift ;;
    *) usage ;;
  esac
done

[ -d "$FRAMEWORK/Versions/B" ] || usage
[ -n "$IDENTITY" ] || usage

signing_flags=(
  --force
  --sign "$IDENTITY"
  --options runtime
)
if [ "$DISTRIBUTION" = "1" ]; then
  signing_flags+=(--timestamp)
fi

sign_if_present() {
  local target="$1"
  shift
  if [ -e "$target" ]; then
    /usr/bin/codesign "${signing_flags[@]}" "$@" "$target"
  fi
}

sparkle_version="$FRAMEWORK/Versions/B"
sign_if_present "$sparkle_version/XPCServices/Installer.xpc"
sign_if_present \
  "$sparkle_version/XPCServices/Downloader.xpc" \
  --preserve-metadata=entitlements
sign_if_present "$sparkle_version/Autoupdate"
sign_if_present "$sparkle_version/Updater.app"
sign_if_present "$FRAMEWORK"

/usr/bin/codesign --verify --strict --verbose=2 "$FRAMEWORK"
