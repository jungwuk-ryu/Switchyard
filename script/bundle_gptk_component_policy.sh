#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 SOURCE_CONFIG DESTINATION [BUILD_CONFIGURATION]" >&2
  exit 2
fi

SOURCE_CONFIG="$1"
DESTINATION="$2"
BUILD_CONFIGURATION="${3:-debug}"

case "$BUILD_CONFIGURATION" in
  debug|release) ;;
  *) echo "build configuration must be debug or release, got: $BUILD_CONFIGURATION" >&2; exit 2 ;;
esac

if [ ! -f "$SOURCE_CONFIG" ]; then
  echo "missing GPTK component configuration at $SOURCE_CONFIG" >&2
  exit 1
fi

value_for_key() {
  local key="$1"
  sed -n "s/^${key}=//p" "$SOURCE_CONFIG" | tail -n 1
}

channel_enabled="$(value_for_key SWITCHYARD_GPTK_CHANNEL_ENABLED)"
case "$channel_enabled" in
  0) ;;
  1)
    required_keys=(
      SWITCHYARD_GPTK_CHANNEL_STATUS_URL
      SWITCHYARD_GPTK_RELEASE_MANIFEST_URL
      SWITCHYARD_GPTK_MANIFEST_SIGNING_PUBLIC_KEY
      SWITCHYARD_GPTK_DISTRIBUTOR_AUTHORITY_ID
      SWITCHYARD_GPTK_INDEPENDENT_LEGAL_APPROVAL_ID
      SWITCHYARD_GPTK_NONCOMMERCIAL_ATTESTATION_ID
      SWITCHYARD_GPTK_EXPORT_CONTROLS_ATTESTATION_ID
      SWITCHYARD_GPTK_TAKEDOWN_ATTESTATION_ID
    )
    for key in "${required_keys[@]}"; do
      value="$(value_for_key "$key")"
      if [ -z "$value" ] || [[ "$value" == __* ]]; then
        echo "enabled GPTK component channels require $key" >&2
        exit 1
      fi
    done

    status_url="$(value_for_key SWITCHYARD_GPTK_CHANNEL_STATUS_URL)"
    if [[ ! "$status_url" =~ ^https://.+/gptk-component-channel\.json$ ]]; then
      echo "GPTK channel status URL must use HTTPS and end in gptk-component-channel.json" >&2
      exit 1
    fi

    manifest_url="$(value_for_key SWITCHYARD_GPTK_RELEASE_MANIFEST_URL)"
    if [[ ! "$manifest_url" =~ ^https://.+/gptk-component-release\.json$ ]]; then
      echo "GPTK release manifest URL must use HTTPS and end in gptk-component-release.json" >&2
      exit 1
    fi

    public_key="$(value_for_key SWITCHYARD_GPTK_MANIFEST_SIGNING_PUBLIC_KEY)"
    decoded_key_length="$(
      printf '%s' "$public_key" |
        /usr/bin/openssl base64 -d -A 2>/dev/null |
        /usr/bin/wc -c |
        /usr/bin/tr -d ' '
    )"
    if [ "$decoded_key_length" != "32" ]; then
      echo "GPTK manifest signing public key must be a base64-encoded 32-byte Ed25519 key" >&2
      exit 1
    fi
    ;;
  *)
    echo "SWITCHYARD_GPTK_CHANNEL_ENABLED must be 0 or 1" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$DESTINATION")"
cp "$SOURCE_CONFIG" "$DESTINATION"
