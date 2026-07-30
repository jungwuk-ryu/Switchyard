#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER_PATH="${SWITCHYARD_RUNNER_PATH:-$ROOT_DIR/.build/debug/switchyard-runner}"
SHORTCUT_HANDLER_PATH="${SWITCHYARD_SHORTCUT_HANDLER_PATH:-$ROOT_DIR/.build/debug/switchyard-shortcut-handler}"
TEST_PARENT="${TMPDIR:-/tmp}"
TEST_ROOT="$(mktemp -d "${TEST_PARENT%/}/switchyard-prefix-lock-deadline.XXXXXX")"
PREFIX_PATH="$TEST_ROOT/Test.container"
LOCK_PATH="$PREFIX_PATH/.switchyard-prefix.lock"
READY_PATH="$TEST_ROOT/lock-ready"
FAKE_WINE="$TEST_ROOT/wine"
COMMAND_PID=""
LOCK_HOLDER_PID=""
HANDLER_PID=""
FAKE_RUNNER_PID=""
FAKE_RUNNER_IDENTITY=""
CLEANUP_PROBE_PID=""

stop_owned_child() {
  local process_id="$1"
  if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
    kill -TERM "$process_id" >/dev/null 2>&1 || true
  fi
  if [ -n "$process_id" ]; then
    wait "$process_id" >/dev/null 2>&1 || true
  fi
}

fake_runner_identity() {
  local process_id="$1"
  local command_line
  local start_time

  case "$process_id" in
    ""|*[!0-9]*) return 1 ;;
  esac
  command_line="$(ps -ww -p "$process_id" -o command= 2>/dev/null)" || return 1
  case "$command_line" in
    *"$FAKE_RUNNER"*) ;;
    *) return 1 ;;
  esac
  start_time="$(ps -ww -p "$process_id" -o lstart= 2>/dev/null)" || return 1
  [ -n "$start_time" ] || return 1
  printf '%s|%s\n' "$start_time" "$command_line"
}

fake_runner_is_still_owned() {
  local current_identity
  [ -n "$FAKE_RUNNER_PID" ] || return 1
  [ -n "$FAKE_RUNNER_IDENTITY" ] || return 1
  current_identity="$(fake_runner_identity "$FAKE_RUNNER_PID")" || return 1
  [ "$current_identity" = "$FAKE_RUNNER_IDENTITY" ]
}

stop_owned_fake_runner() {
  local process_id="$FAKE_RUNNER_PID"
  if ! fake_runner_is_still_owned; then
    FAKE_RUNNER_PID=""
    FAKE_RUNNER_IDENTITY=""
    return
  fi

  kill -TERM "$process_id" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    if ! fake_runner_is_still_owned; then
      FAKE_RUNNER_PID=""
      FAKE_RUNNER_IDENTITY=""
      return
    fi
    sleep 0.02
  done

  if fake_runner_is_still_owned; then
    kill -KILL "$process_id" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 50); do
    if ! fake_runner_is_still_owned; then
      FAKE_RUNNER_PID=""
      FAKE_RUNNER_IDENTITY=""
      return
    fi
    sleep 0.02
  done
}

cleanup() {
  stop_owned_child "$COMMAND_PID"
  stop_owned_fake_runner
  stop_owned_child "$CLEANUP_PROBE_PID"
  stop_owned_child "$HANDLER_PID"
  stop_owned_child "$LOCK_HOLDER_PID"
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_owned_with_deadline() {
  local stdout_path="$1"
  local stderr_path="$2"
  shift 2
  "$@" >"$stdout_path" 2>"$stderr_path" &
  COMMAND_PID="$!"

  for _ in $(seq 1 300); do
    if ! kill -0 "$COMMAND_PID" >/dev/null 2>&1; then
      local status=0
      wait "$COMMAND_PID" || status="$?"
      COMMAND_PID=""
      return "$status"
    fi
    sleep 0.02
  done

  local timed_out_pid="$COMMAND_PID"
  kill -TERM "$timed_out_pid" >/dev/null 2>&1 || true
  wait "$timed_out_pid" >/dev/null 2>&1 || true
  COMMAND_PID=""
  echo "owned command $timed_out_pid exceeded its test deadline" >&2
  return 124
}

mkdir -p "$PREFIX_PATH"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_WINE"
chmod +x "$FAKE_WINE"

python3 - "$LOCK_PATH" "$READY_PATH" <<'PY' &
import fcntl
import os
import signal
import sys

descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
os.fchmod(descriptor, 0o600)
fcntl.flock(descriptor, fcntl.LOCK_EX)
with open(sys.argv[2], "w", encoding="utf-8") as ready:
    ready.write("ready\n")

def stop(_signal, _frame):
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while True:
    signal.pause()
PY
LOCK_HOLDER_PID="$!"

for _ in $(seq 1 100); do
  if [ -e "$READY_PATH" ]; then
    break
  fi
  if ! kill -0 "$LOCK_HOLDER_PID" >/dev/null 2>&1; then
    wait "$LOCK_HOLDER_PID" >/dev/null 2>&1 || true
    LOCK_HOLDER_PID=""
    echo "lock holder exited before acquiring the fixture lock" >&2
    exit 1
  fi
  sleep 0.02
done
test -e "$READY_PATH"

REQUEST_PATH="$TEST_ROOT/url-request.json"
cat >"$REQUEST_PATH" <<JSON
{"scheme":"switchyard-test","rawURL":"switchyard-test://callback","prefixPath":"$PREFIX_PATH","winePath":"$FAKE_WINE"}
JSON
chmod 600 "$REQUEST_PATH"

set +e
run_owned_with_deadline \
  "$TEST_ROOT/url.stdout" \
  "$TEST_ROOT/url.stderr" \
  "$RUNNER_PATH" open-url --request "$REQUEST_PATH"
url_status="$?"
set -e
test "$url_status" -eq 1
test ! -e "$REQUEST_PATH"
rg -F "Timed out while waiting to access the Wine prefix." "$TEST_ROOT/url.stderr" >/dev/null

DESKTOP_PATH="$PREFIX_PATH/drive_c/users/steamuser/Desktop"
mkdir -p "$DESKTOP_PATH"
printf 'synthetic shortcut\n' >"$DESKTOP_PATH/Test.lnk"
REQUEST_PATH="$TEST_ROOT/shortcut-request.json"
cat >"$REQUEST_PATH" <<JSON
{
  "shortcutID": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "prefixPath": "$PREFIX_PATH",
  "winePath": "$FAKE_WINE",
  "windowsShortcutPath": "C:\\\\users\\\\steamuser\\\\Desktop\\\\Test.lnk"
}
JSON
chmod 600 "$REQUEST_PATH"

set +e
run_owned_with_deadline \
  "$TEST_ROOT/shortcut.stdout" \
  "$TEST_ROOT/shortcut.stderr" \
  "$RUNNER_PATH" open-shortcut --request "$REQUEST_PATH"
shortcut_status="$?"
set -e
test "$shortcut_status" -eq 1
test ! -e "$REQUEST_PATH"
rg -F "Timed out while waiting to access the Wine prefix." "$TEST_ROOT/shortcut.stderr" >/dev/null

stop_owned_child "$LOCK_HOLDER_PID"
LOCK_HOLDER_PID=""

TEST_HOME="$TEST_ROOT/home"
BRIDGE_ROOT="$TEST_HOME/Library/Application Support/Switchyard/DesktopShortcutBridge"
HANDLER_APP="$TEST_ROOT/TestShortcut.app"
HANDLER_EXECUTABLE="$HANDLER_APP/Contents/MacOS/switchyard-shortcut-handler"
FAKE_RUNNER="$TEST_ROOT/fake-runner"
FAKE_RUNNER_PID_PATH="$TEST_ROOT/fake-runner.pid"
FAKE_RUNNER_SIGNAL_PATH="$TEST_ROOT/fake-runner.signal"
mkdir -p "$BRIDGE_ROOT" "$HANDLER_APP/Contents/MacOS"
cp "$SHORTCUT_HANDLER_PATH" "$HANDLER_EXECUTABLE"

cat >"$HANDLER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>switchyard-shortcut-handler</string>
  <key>CFBundleIdentifier</key>
  <string>dev.switchyard.tests.shortcut-deadline</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>SwitchyardDesktopShortcutID</key>
  <string>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</string>
</dict>
</plist>
PLIST

cat >"$FAKE_RUNNER" <<'SCRIPT'
#!/usr/bin/env python3
import os
import signal

with open(os.environ["SWITCHYARD_TEST_FAKE_RUNNER_PID_PATH"], "w", encoding="utf-8") as output:
    output.write(f"{os.getpid()}\n")

def record_term(_signal, _frame):
    with open(
        os.environ["SWITCHYARD_TEST_FAKE_RUNNER_SIGNAL_PATH"],
        "w",
        encoding="utf-8",
    ) as output:
        output.write("term\n")

signal.signal(signal.SIGTERM, record_term)
while True:
    signal.pause()
SCRIPT
chmod +x "$FAKE_RUNNER"

cat >"$BRIDGE_ROOT/routes-v1.json" <<JSON
{
  "version": 1,
  "routes": [
    {
      "id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "containerID": "11111111-1111-1111-1111-111111111111",
      "prefixPath": "$PREFIX_PATH",
      "winePath": "$FAKE_WINE",
      "runnerPath": "$FAKE_RUNNER",
      "windowsShortcutPath": "C:\\\\users\\\\steamuser\\\\Desktop\\\\Test.lnk"
    }
  ]
}
JSON

CFFIXED_USER_HOME="$TEST_HOME" \
SWITCHYARD_TEST_HANDLER_RUNNER_TIMEOUT="0.5" \
SWITCHYARD_TEST_FAKE_RUNNER_PID_PATH="$FAKE_RUNNER_PID_PATH" \
SWITCHYARD_TEST_FAKE_RUNNER_SIGNAL_PATH="$FAKE_RUNNER_SIGNAL_PATH" \
  "$HANDLER_EXECUTABLE" >"$TEST_ROOT/handler.stdout" 2>"$TEST_ROOT/handler.stderr" &
HANDLER_PID="$!"

for _ in $(seq 1 100); do
  if [ -s "$FAKE_RUNNER_PID_PATH" ]; then
    candidate_pid="$(cat "$FAKE_RUNNER_PID_PATH")"
    candidate_identity="$(fake_runner_identity "$candidate_pid" || true)"
    if [ -n "$candidate_identity" ]; then
      FAKE_RUNNER_PID="$candidate_pid"
      FAKE_RUNNER_IDENTITY="$candidate_identity"
      break
    fi
  fi
  if ! kill -0 "$HANDLER_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.02
done
if [ -z "$FAKE_RUNNER_IDENTITY" ]; then
  echo "shortcut handler did not launch an identifiable fake runner" >&2
  sed -n '1,120p' "$TEST_ROOT/handler.stderr" >&2
  exit 1
fi

for _ in $(seq 1 250); do
  if ! kill -0 "$HANDLER_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.02
done
if kill -0 "$HANDLER_PID" >/dev/null 2>&1; then
  echo "shortcut handler exceeded its test deadline" >&2
  exit 1
fi
wait "$HANDLER_PID"
HANDLER_PID=""

if [ ! -e "$FAKE_RUNNER_PID_PATH" ]; then
  echo "shortcut handler did not launch its fake runner" >&2
  sed -n '1,120p' "$TEST_ROOT/handler.stderr" >&2
  exit 1
fi
test -e "$FAKE_RUNNER_SIGNAL_PATH"
if fake_runner_is_still_owned; then
  echo "shortcut handler left fake runner $FAKE_RUNNER_PID alive" >&2
  exit 1
fi
FAKE_RUNNER_PID=""
FAKE_RUNNER_IDENTITY=""
test -z "$(find "$BRIDGE_ROOT/Requests" -type f -print -quit 2>/dev/null)"
rg -F "did not finish opening the desktop shortcut within 30 seconds" \
  "$TEST_ROOT/handler.stderr" >/dev/null

rm -f "$FAKE_RUNNER_PID_PATH" "$FAKE_RUNNER_SIGNAL_PATH"
(
  set +e
  SWITCHYARD_TEST_FAKE_RUNNER_PID_PATH="$FAKE_RUNNER_PID_PATH" \
  SWITCHYARD_TEST_FAKE_RUNNER_SIGNAL_PATH="$FAKE_RUNNER_SIGNAL_PATH" \
    "$FAKE_RUNNER" cleanup-probe
  exit "$?"
) 2>/dev/null &
CLEANUP_PROBE_PID="$!"
for _ in $(seq 1 100); do
  if [ -s "$FAKE_RUNNER_PID_PATH" ]; then
    candidate_pid="$(cat "$FAKE_RUNNER_PID_PATH")"
    candidate_identity="$(fake_runner_identity "$candidate_pid" || true)"
    if [ -n "$candidate_identity" ]; then
      FAKE_RUNNER_PID="$candidate_pid"
      FAKE_RUNNER_IDENTITY="$candidate_identity"
      break
    fi
  fi
  sleep 0.02
done
test -n "$FAKE_RUNNER_IDENTITY"
stop_owned_fake_runner
cleanup_probe_status=0
wait "$CLEANUP_PROBE_PID" 2>/dev/null || cleanup_probe_status="$?"
CLEANUP_PROBE_PID=""
test "$cleanup_probe_status" -eq 137
test -e "$FAKE_RUNNER_SIGNAL_PATH"
test -z "$FAKE_RUNNER_PID"
test -z "$FAKE_RUNNER_IDENTITY"

printf 'prefix lock deadline test passed\n'
