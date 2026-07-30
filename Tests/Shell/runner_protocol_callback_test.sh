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
INVALID_REQUEST_PID=""
MACOS_MAJOR_VERSION="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$(uname -m)" = "arm64" ] && [ "$MACOS_MAJOR_VERSION" -ge 15 ]; then
  EXPECTED_ROSETTA_AVX="1"
else
  EXPECTED_ROSETTA_AVX="0"
fi

cleanup() {
  if [ -n "$INVALID_REQUEST_PID" ] \
    && kill -0 "$INVALID_REQUEST_PID" >/dev/null 2>&1; then
    kill -TERM "$INVALID_REQUEST_PID" >/dev/null 2>&1 || true
    wait "$INVALID_REQUEST_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$PREFIX_PATH"
cat >"$FAKE_WINE" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "wmic" ]; then
  if [ "${4:-}" = "CreationDate,ExecutablePath,ProcessId" ]; then
    printf '%s\n' \
      'CreationDate  ExecutablePath  ProcessId' \
      '20260731060000.000000+540  C:\windows\system32\services.exe  80' \
      '20260731060001.000000+540  C:\Program Files (x86)\Steam\steam.exe  144' \
      '20260731060002.000000+540  C:\Games\Heartopia\xdt.exe  232'
    exit 0
  fi
  if [ "${4:-}" = "ExecutablePath,ProcessId" ] \
    && [ "${SWITCHYARD_TEST_LEGACY_WMIC:-0}" != "1" ]; then
    printf '%s\n' \
      'ExecutablePath  ProcessId' \
      'C:\windows\system32\services.exe  80' \
      'C:\Program Files (x86)\Steam\steam.exe  144' \
      'C:\Games\Heartopia\xdt.exe  232'
    exit 0
  fi
  printf '%s\n' \
    'ExecutablePath' \
    'C:\windows\system32\services.exe' \
    'C:\Program Files (x86)\Steam\steam.exe' \
    'C:\Games\Heartopia\xdt.exe'
  exit 0
fi
if [ "${1:-}" = "taskkill" ]; then
  printf '%s\n' '[invocation]' "$@" >>"$SWITCHYARD_TEST_ARGUMENTS_PATH"
  exit 0
fi
printf '%s\n' '[invocation]' "$@" >>"$SWITCHYARD_TEST_ARGUMENTS_PATH"
printf '%s\n' \
  "$WINEPREFIX" \
  "$SWITCHYARD_PROTOCOL_ASSOCIATIONS_FILE" \
  "rosetta=${ROSETTA_ADVERTISE_AVX:-missing}" >>"$SWITCHYARD_TEST_ENVIRONMENT_PATH"
if [ "${1:-}" = "reg" ] && [ "${2:-}" = "query" ]; then
  exit "${SWITCHYARD_TEST_QUERY_STATUS:-1}"
fi
SCRIPT
chmod +x "$FAKE_WINE"

processes="$($RUNNER_PATH list-processes --wine "$FAKE_WINE" --prefix "$PREFIX_PATH")"
test "$processes" = '["C:\\Games\\Heartopia\\xdt.exe","C:\\Program Files (x86)\\Steam\\steam.exe","C:\\windows\\system32\\services.exe"]'

process_details="$($RUNNER_PATH list-process-details --wine "$FAKE_WINE" --prefix "$PREFIX_PATH")"
test "$process_details" = '[{"executablePath":"C:\\Games\\Heartopia\\xdt.exe","processID":232},{"executablePath":"C:\\Program Files (x86)\\Steam\\steam.exe","processID":144},{"executablePath":"C:\\windows\\system32\\services.exe","processID":80}]'

legacy_process_details="$(
  SWITCHYARD_TEST_LEGACY_WMIC=1 \
    "$RUNNER_PATH" list-process-details --wine "$FAKE_WINE" --prefix "$PREFIX_PATH"
)"
test "$legacy_process_details" = '[{"executablePath":"C:\\Games\\Heartopia\\xdt.exe"},{"executablePath":"C:\\Program Files (x86)\\Steam\\steam.exe"},{"executablePath":"C:\\windows\\system32\\services.exe"}]'

: >"$ARGUMENTS_PATH"
SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" terminate-process \
    --wine "$FAKE_WINE" \
    --prefix "$PREFIX_PATH" \
    --pid 232
diff -u \
  <(printf '%s\n' '[invocation]' 'taskkill' '/PID' '232' '/F') \
  "$ARGUMENTS_PATH"
: >"$ARGUMENTS_PATH"
: >"$ENVIRONMENT_PATH"

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
    "rosetta=$EXPECTED_ROSETTA_AVX" \
    "$PREFIX_PATH" 'C:\windows\temp\switchyard-protocols-v1.txt' \
    "rosetta=$EXPECTED_ROSETTA_AVX") \
  "$ENVIRONMENT_PATH"

: >"$ARGUMENTS_PATH"
: >"$ENVIRONMENT_PATH"
cat >"$REQUEST_PATH" <<JSON
{"scheme":"xdt","rawURL":"xdt://callback\\u0000suffix","prefixPath":"$PREFIX_PATH","winePath":"$FAKE_WINE"}
JSON
chmod 600 "$REQUEST_PATH"

set +e
SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-url --request "$REQUEST_PATH" >/dev/null 2>&1 &
INVALID_REQUEST_PID="$!"
for _ in $(seq 1 100); do
  if ! kill -0 "$INVALID_REQUEST_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
if kill -0 "$INVALID_REQUEST_PID" >/dev/null 2>&1; then
  kill -TERM "$INVALID_REQUEST_PID" >/dev/null 2>&1 || true
  wait "$INVALID_REQUEST_PID" >/dev/null 2>&1 || true
  INVALID_REQUEST_PID=""
  set -e
  echo "runner did not reject a control character in the callback deadline" >&2
  exit 1
fi
wait "$INVALID_REQUEST_PID"
invalid_request_status="$?"
INVALID_REQUEST_PID=""
set -e
test "$invalid_request_status" -eq 1
test ! -e "$REQUEST_PATH"
test ! -s "$ARGUMENTS_PATH"
test ! -s "$ENVIRONMENT_PATH"

mkdir -p "$PREFIX_PATH/dosdevices" "$TEST_ROOT/ExternalLibrary/Heartopia"
ln -s "$TEST_ROOT/ExternalLibrary" "$PREFIX_PATH/dosdevices/d:"
touch "$TEST_ROOT/ExternalLibrary/Heartopia/xdt.exe"
: >"$ARGUMENTS_PATH"
: >"$ENVIRONMENT_PATH"
cat >"$REQUEST_PATH" <<JSON
{"scheme":"xdt","rawURL":"xdt://callback?code=second-synthetic-secret","prefixPath":"$PREFIX_PATH","winePath":"$FAKE_WINE","handlerExecutablePath":"D:\\\\Heartopia\\\\xdt.exe"}
JSON
chmod 600 "$REQUEST_PATH"

SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-url --request "$REQUEST_PATH"

test ! -e "$REQUEST_PATH"
diff -u \
  <(printf '%s\n' \
    '[invocation]' \
    'reg' 'query' 'HKCR\xdt\shell\open\command' '/ve' \
    '[invocation]' \
    'D:\Heartopia\xdt.exe' 'xdt://callback?code=second-synthetic-secret' \
    '[invocation]' \
    'reg' 'add' 'HKCU\Software\Classes\xdt' '/ve' '/d' 'URL:xdt protocol' '/f' \
    '[invocation]' \
    'reg' 'add' 'HKCU\Software\Classes\xdt' '/v' 'URL Protocol' '/d' '' '/f' \
    '[invocation]' \
    'reg' 'add' 'HKCU\Software\Classes\xdt\shell\open\command' '/ve' '/d' '"D:\Heartopia\xdt.exe" "%1"' '/f' \
    '[invocation]' \
    'reg' 'copy' 'HKCU\Software\Classes\xdt' 'HKCR\xdt' '/s' '/f') \
  "$ARGUMENTS_PATH"
test "$(rg -c -F -x "$PREFIX_PATH" "$ENVIRONMENT_PATH")" = "6"
test "$(rg -c -F -x 'C:\windows\temp\switchyard-protocols-v1.txt' "$ENVIRONMENT_PATH")" = "6"

: >"$ARGUMENTS_PATH"
: >"$ENVIRONMENT_PATH"
cat >"$REQUEST_PATH" <<JSON
{"scheme":"xdt","rawURL":"xdt://callback?code=existing-handler-secret","prefixPath":"$PREFIX_PATH","winePath":"$FAKE_WINE","handlerExecutablePath":"D:\\\\Heartopia\\\\xdt.exe"}
JSON
chmod 600 "$REQUEST_PATH"

SWITCHYARD_TEST_QUERY_STATUS=0 \
SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-url --request "$REQUEST_PATH"

diff -u \
  <(printf '%s\n' \
    '[invocation]' \
    'reg' 'query' 'HKCR\xdt\shell\open\command' '/ve' \
    '[invocation]' \
    'reg' 'copy' 'HKCU\Software\Classes\xdt' 'HKCR\xdt' '/s' '/f' \
    '[invocation]' \
    'start' 'xdt://callback?code=existing-handler-secret') \
  "$ARGUMENTS_PATH"
test "$(rg -c -F -x "$PREFIX_PATH" "$ENVIRONMENT_PATH")" = "3"

: >"$ARGUMENTS_PATH"
: >"$ENVIRONMENT_PATH"
cat >"$REQUEST_PATH" <<JSON
{"scheme":"xdt","rawURL":"xdt://callback?code=missing-target-secret","prefixPath":"$PREFIX_PATH","winePath":"$FAKE_WINE","handlerExecutablePath":"E:\\\\Missing\\\\xdt.exe"}
JSON
chmod 600 "$REQUEST_PATH"
if SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
  SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-url --request "$REQUEST_PATH" >/dev/null 2>&1; then
  echo "runner accepted an unregistered callback target outside the mapped Wine drives" >&2
  exit 1
fi
test ! -e "$REQUEST_PATH"
diff -u \
  <(printf '%s\n' \
    '[invocation]' \
    'reg' 'query' 'HKCR\xdt\shell\open\command' '/ve') \
  "$ARGUMENTS_PATH"

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
test "$(rg -c -F -x "rosetta=$EXPECTED_ROSETTA_AVX" "$ENVIRONMENT_PATH")" = "2"

printf 'runner protocol callback test passed\n'
