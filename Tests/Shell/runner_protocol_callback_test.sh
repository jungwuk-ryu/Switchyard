#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER_PATH="${SWITCHYARD_RUNNER_PATH:-$ROOT_DIR/.build/debug/switchyard-runner}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-protocol-callback.XXXXXX")"
PREFIX_PATH="$TEST_ROOT/Test.container"
FAKE_WINE="$TEST_ROOT/wine"
REQUEST_PATH="$TEST_ROOT/request.json"
ARGUMENTS_PATH="$TEST_ROOT/arguments.txt"
ENVIRONMENT_PATH="$TEST_ROOT/environment.txt"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$PREFIX_PATH"
cat >"$FAKE_WINE" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '[invocation]' "$@" >>"$SWITCHYARD_TEST_ARGUMENTS_PATH"
printf '%s\n' "$WINEPREFIX" "$SWITCHYARD_PROTOCOL_ASSOCIATIONS_FILE" >>"$SWITCHYARD_TEST_ENVIRONMENT_PATH"
SCRIPT
chmod +x "$FAKE_WINE"

cat >"$REQUEST_PATH" <<JSON
{"scheme":"xdt","rawURL":"xdt://callback?code=synthetic-secret","prefixPath":"$PREFIX_PATH","winePath":"$FAKE_WINE"}
JSON
chmod 600 "$REQUEST_PATH"

SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-url --request "$REQUEST_PATH"

test ! -e "$REQUEST_PATH"
diff -u \
  <(printf '%s\n' \
    '[invocation]' \
    'reg' 'copy' 'HKCU\Software\Classes\xdt' 'HKCR\xdt' '/s' '/f' \
    '[invocation]' \
    'start' 'xdt://callback?code=synthetic-secret') \
  "$ARGUMENTS_PATH"
diff -u \
  <(printf '%s\n' \
    "$PREFIX_PATH" 'C:\windows\temp\switchyard-protocols-v1.txt' \
    "$PREFIX_PATH" 'C:\windows\temp\switchyard-protocols-v1.txt') \
  "$ENVIRONMENT_PATH"

: >"$ARGUMENTS_PATH"
: >"$ENVIRONMENT_PATH"
PLAN_PATH="$TEST_ROOT/plan.json"
cat >"$PLAN_PATH" <<JSON
{
  "executable": "$FAKE_WINE",
  "arguments": ["C:\\\\Game.exe"],
  "environment": {
    "WINEPREFIX": "$PREFIX_PATH",
    "SWITCHYARD_PROTOCOL_ASSOCIATIONS_FILE": "C:\\\\windows\\\\temp\\\\switchyard-protocols-v1.txt"
  },
  "workingDirectory": "$PREFIX_PATH",
  "logSource": "protocol-monitor-test"
}
JSON

SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" run --plan "$PLAN_PATH" >/dev/null
for _ in 1 2 3 4 5; do
  invocation_count="$(rg -c '^\[invocation\]$' "$ARGUMENTS_PATH" || true)"
  [ "$invocation_count" = "2" ] && break
  sleep 0.1
done
test "$(rg -c '^\[invocation\]$' "$ARGUMENTS_PATH")" = "2"
test "$(rg -c -x 'winemenubuilder.exe' "$ARGUMENTS_PATH")" = "1"
test "$(rg -c -x -- '-m' "$ARGUMENTS_PATH")" = "1"
test "$(rg -c -F -x 'C:\Game.exe' "$ARGUMENTS_PATH")" = "1"
test "$(rg -c -F -x "$PREFIX_PATH" "$ENVIRONMENT_PATH")" = "2"
test "$(rg -c -F -x 'C:\windows\temp\switchyard-protocols-v1.txt' "$ENVIRONMENT_PATH")" = "2"

printf 'runner protocol callback test passed\n'
