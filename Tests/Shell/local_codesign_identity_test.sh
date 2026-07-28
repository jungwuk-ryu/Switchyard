#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELECTOR="$ROOT_DIR/script/local_codesign_identity.sh"

assert_equal() {
  local expected="$1"
  local actual="$2"
  local description="$3"
  if [ "$actual" != "$expected" ]; then
    echo "$description: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

explicit="Apple Development: Explicit Identity (TEAMID)"
actual="$("$SELECTOR" "$explicit" </dev/null)"
assert_equal "$explicit" "$actual" "explicit identity"

identities='
  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Example (TEAMID)"
  2) 1111111111111111111111111111111111111111 "Apple Development: First (TEAMID)"
  3) 2222222222222222222222222222222222222222 "Apple Development: Second (TEAMID)"
     3 valid identities found
'
actual="$(/usr/bin/printf '%s\n' "$identities" | "$SELECTOR")"
assert_equal \
  "1111111111111111111111111111111111111111" \
  "$actual" \
  "first Apple Development fingerprint"

invalid_identities='
  1) TOO-SHORT "Apple Development: Invalid (TEAMID)"
  2) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Example (TEAMID)"
     2 valid identities found
'
actual="$(/usr/bin/printf '%s\n' "$invalid_identities" | "$SELECTOR")"
assert_equal "" "$actual" "missing Apple Development identity"

echo "Local code-signing identity tests passed"
