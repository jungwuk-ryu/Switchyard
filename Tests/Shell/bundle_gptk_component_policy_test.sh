#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT_DIR/script/bundle_gptk_component_policy.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-gptk-policy.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

DISABLED_CONFIG="$TEST_ROOT/disabled.env"
DISABLED_OUTPUT="$TEST_ROOT/disabled-output.env"
cat >"$DISABLED_CONFIG" <<'EOF'
SWITCHYARD_GPTK_CHANNEL_ENABLED=0
SWITCHYARD_GPTK_RELEASE_MANIFEST_URL=__REQUIRED_BEFORE_ENABLEMENT__
EOF

"$SCRIPT" "$DISABLED_CONFIG" "$DISABLED_OUTPUT" release
cmp "$DISABLED_CONFIG" "$DISABLED_OUTPUT"

INCOMPLETE_CONFIG="$TEST_ROOT/incomplete.env"
cat >"$INCOMPLETE_CONFIG" <<'EOF'
SWITCHYARD_GPTK_CHANNEL_ENABLED=1
SWITCHYARD_GPTK_CHANNEL_STATUS_URL=https://components.example.test/gptk-component-channel.json
SWITCHYARD_GPTK_RELEASE_MANIFEST_URL=https://components.example.test/gptk-component-release.json
EOF

if "$SCRIPT" "$INCOMPLETE_CONFIG" "$TEST_ROOT/incomplete-output.env" debug 2>/dev/null; then
  echo "enabled channel unexpectedly accepted incomplete release controls" >&2
  exit 1
fi

ENABLED_CONFIG="$TEST_ROOT/enabled.env"
ENABLED_OUTPUT="$TEST_ROOT/enabled-output.env"
PUBLIC_KEY="$(printf '01234567890123456789012345678901' | /usr/bin/openssl base64 -A)"
cat >"$ENABLED_CONFIG" <<EOF
SWITCHYARD_GPTK_CHANNEL_ENABLED=1
SWITCHYARD_GPTK_CHANNEL_STATUS_URL=https://components.example.test/gptk-component-channel.json
SWITCHYARD_GPTK_RELEASE_MANIFEST_URL=https://components.example.test/releases/gptk-component-release.json
SWITCHYARD_GPTK_MANIFEST_SIGNING_PUBLIC_KEY=$PUBLIC_KEY
SWITCHYARD_GPTK_DISTRIBUTOR_AUTHORITY_ID=authority:2026-07-24
SWITCHYARD_GPTK_INDEPENDENT_LEGAL_APPROVAL_ID=legal:2026-07-24
SWITCHYARD_GPTK_NONCOMMERCIAL_ATTESTATION_ID=noncommercial:2026-07-24
SWITCHYARD_GPTK_EXPORT_CONTROLS_ATTESTATION_ID=export:2026-07-24
SWITCHYARD_GPTK_TAKEDOWN_ATTESTATION_ID=takedown:2026-07-24
EOF

"$SCRIPT" "$ENABLED_CONFIG" "$ENABLED_OUTPUT" release
cmp "$ENABLED_CONFIG" "$ENABLED_OUTPUT"

echo "GPTK component policy bundling tests passed"
