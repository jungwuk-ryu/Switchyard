#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWIFT_BUILD_JOBS="${SWIFT_BUILD_JOBS:-$(($(sysctl -n hw.ncpu) - 1))}"
if [ "$SWIFT_BUILD_JOBS" -gt 13 ]; then
  SWIFT_BUILD_JOBS=13
fi
if [ "$SWIFT_BUILD_JOBS" -lt 1 ]; then
  SWIFT_BUILD_JOBS=1
fi
(cd "$ROOT_DIR" && swift build --jobs "$SWIFT_BUILD_JOBS" >/dev/null)
BIN_PATH="$(cd "$ROOT_DIR" && swift build --show-bin-path)"
RUNNER="$BIN_PATH/switchyard-runner"
TEST_ROOT="$(mktemp -d)"
BIN_DIR="$TEST_ROOT/runtime/bin"
PREFIX="$TEST_ROOT/Test.container"
OTHER_PREFIX="$TEST_ROOT/Heartopia.container"
EVENTS="$TEST_ROOT/events.log"

cleanup() {
  if [ -f "$TEST_ROOT/descendant.pid" ]; then
    kill "$(cat "$TEST_ROOT/descendant.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/signal-child.pid" ]; then
    kill "$(cat "$TEST_ROOT/signal-child.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/preflight-wineserver.pid" ]; then
    kill "$(cat "$TEST_ROOT/preflight-wineserver.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/protocol-monitor.pid" ]; then
    kill "$(cat "$TEST_ROOT/protocol-monitor.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/orphan-wine.pid" ]; then
    kill -KILL "$(cat "$TEST_ROOT/orphan-wine.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/unrelated-wine.pid" ]; then
    kill -KILL "$(cat "$TEST_ROOT/unrelated-wine.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/environment-wine.pid" ]; then
    kill -KILL "$(cat "$TEST_ROOT/environment-wine.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/prefix-lock-holder.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/prefix-lock-holder.pid")" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$PREFIX" "$OTHER_PREFIX"
cat > "$BIN_DIR/wineserver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'wineserver %s prefix=%s\n' "$*" "$WINEPREFIX" >> "$TEST_EVENTS"
if [ "${1:-}" = "-w" ] && [ -n "${TEST_WINESERVER_PID_FILE:-}" ]; then
  printf '%s\n' "$$" > "$TEST_WINESERVER_PID_FILE"
fi
if [ "${1:-}" = "-k" ] && [ "${TEST_KILL_STATUS:-0}" -ne 0 ]; then
  exit "$TEST_KILL_STATUS"
fi
if [ "${1:-}" = "-w" ] && [ "${TEST_PROBE_ACTIVE:-0}" -eq 1 ]; then
  exec sleep 30
fi
if [ "${1:-}" = "-w" ] && [ "${TEST_WAIT_HANG:-0}" -eq 1 ]; then
  trap '' TERM
  exec sleep 30
fi
EOF
cat > "$BIN_DIR/switchyard-wine" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'wine %s prefix=%s\n' "$*" "$WINEPREFIX" >> "$TEST_EVENTS"
if [ "${1:-}" = "winemenubuilder.exe" ] && [ "${2:-}" = "-m" ] && [ -n "${TEST_MONITOR_PID_FILE:-}" ]; then
  printf '%s\n' "$$" > "$TEST_MONITOR_PID_FILE"
  trap 'printf "stopped\n" > "$TEST_MONITOR_STOPPED_FILE"; exit 0' TERM INT
  while :; do
    sleep 0.1
  done
fi
if [ -n "${TEST_MONITOR_PID_FILE:-}" ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$TEST_MONITOR_PID_FILE" ] && break
    sleep 0.02
  done
fi
EOF
chmod +x "$BIN_DIR/wineserver" "$BIN_DIR/switchyard-wine"

cc -Os "$ROOT_DIR/Tests/Shell/Fixtures/prefix_wine_process.c" -o "$TEST_ROOT/wine"
cc -Os "$ROOT_DIR/Tests/Shell/Fixtures/prefix_lock_holder.c" -o "$TEST_ROOT/prefix-lock-holder"

TEST_EVENTS="$EVENTS" TEST_PROBE_ACTIVE=1 "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
if TEST_EVENTS="$EVENTS" "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"; then
  echo "probe should report an inactive prefix with status 1" >&2
  exit 1
elif [ "$?" -ne 1 ]; then
  echo "inactive prefix probe returned an unexpected status" >&2
  exit 1
fi

: > "$EVENTS"
(
  "$TEST_ROOT/prefix-lock-holder" "$PREFIX" "$TEST_ROOT/prefix-lock-holder.ready" &
  wait "$!" >/dev/null 2>&1 || true
) &
prefix_lock_holder_reaper_pid=$!
for _ in {1..50}; do
  [ -s "$TEST_ROOT/prefix-lock-holder.ready" ] && break
  sleep 0.02
done
if [ ! -s "$TEST_ROOT/prefix-lock-holder.ready" ]; then
  echo "prefix lock fixture did not start" >&2
  exit 1
fi
prefix_lock_holder_pid="$(cat "$TEST_ROOT/prefix-lock-holder.ready")"
printf '%s\n' "$prefix_lock_holder_pid" > "$TEST_ROOT/prefix-lock-holder.pid"

TEST_EVENTS="$EVENTS" \
  "$RUNNER" list-processes --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX" \
  >"$TEST_ROOT/locked-list.out" 2>"$TEST_ROOT/locked-list.err" &
locked_list_pid=$!
for _ in {1..50}; do
  if lsof -a -p "$locked_list_pid" "$PREFIX/.switchyard-prefix.lock" >/dev/null 2>&1; then
    break
  fi
  sleep 0.02
done
if ! kill -0 "$locked_list_pid" >/dev/null 2>&1; then
  echo "list-processes did not wait for the prefix storage lock" >&2
  exit 1
fi
if grep -q '^wine ' "$EVENTS"; then
  echo "list-processes launched Wine while a storage lock was held" >&2
  exit 1
fi

MOVED_PREFIX="$TEST_ROOT/Renamed.container"
mv "$PREFIX" "$MOVED_PREFIX"
kill -TERM "$prefix_lock_holder_pid"
wait "$prefix_lock_holder_reaper_pid"
set +e
wait "$locked_list_pid"
locked_list_status=$?
set -e
if [ "$locked_list_status" -ne 2 ]; then
  echo "list-processes should reject a prefix moved while it waited for the storage lock" >&2
  exit 1
fi
if grep -q '^wine ' "$EVENTS"; then
  echo "list-processes launched Wine after the locked prefix moved" >&2
  exit 1
fi
mv "$MOVED_PREFIX" "$PREFIX"
rm -f "$TEST_ROOT/prefix-lock-holder.pid"
: > "$EVENTS"

(
  "$TEST_ROOT/wine" "$PREFIX" "$TEST_ROOT/orphan-wine.ready" ignore-term &
  wait "$!" >/dev/null 2>&1 || true
) &
orphan_wine_reaper_pid=$!
(
  WINEPREFIX="$PREFIX" \
    "$TEST_ROOT/wine" "$TEST_ROOT" "$TEST_ROOT/environment-wine.ready" default &
  wait "$!" >/dev/null 2>&1 || true
) &
environment_wine_reaper_pid=$!
(
  WINEPREFIX="$OTHER_PREFIX" \
    "$TEST_ROOT/wine" "$OTHER_PREFIX" "$TEST_ROOT/unrelated-wine.ready" default &
  wait "$!" >/dev/null 2>&1 || true
) &
unrelated_wine_reaper_pid=$!
for _ in {1..50}; do
  if [ -s "$TEST_ROOT/orphan-wine.ready" ] \
    && [ -s "$TEST_ROOT/environment-wine.ready" ] \
    && [ -s "$TEST_ROOT/unrelated-wine.ready" ]; then
    break
  fi
  sleep 0.02
done
if [ ! -s "$TEST_ROOT/orphan-wine.ready" ] \
  || [ ! -s "$TEST_ROOT/environment-wine.ready" ] \
  || [ ! -s "$TEST_ROOT/unrelated-wine.ready" ]; then
  echo "Wine process fixtures did not start" >&2
  exit 1
fi
orphan_wine_pid="$(cat "$TEST_ROOT/orphan-wine.ready")"
environment_wine_pid="$(cat "$TEST_ROOT/environment-wine.ready")"
unrelated_wine_pid="$(cat "$TEST_ROOT/unrelated-wine.ready")"
printf '%s\n' "$orphan_wine_pid" > "$TEST_ROOT/orphan-wine.pid"
printf '%s\n' "$environment_wine_pid" > "$TEST_ROOT/environment-wine.pid"
printf '%s\n' "$unrelated_wine_pid" > "$TEST_ROOT/unrelated-wine.pid"

set +e
TEST_EVENTS="$EVENTS" "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
orphan_probe_status=$?
set -e
if [ "$orphan_probe_status" -ne 3 ]; then
  echo "probe should distinguish orphaned Wine host processes with status 3" >&2
  exit 1
fi
TEST_EVENTS="$EVENTS" SWITCHYARD_TEST_PREFIX_PROCESS_TIMEOUT=0.1 \
  "$RUNNER" stop-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
wait "$orphan_wine_reaper_pid"
wait "$environment_wine_reaper_pid"
if kill -0 "$orphan_wine_pid" >/dev/null 2>&1; then
  echo "stop-prefix left an orphaned Wine host process alive" >&2
  exit 1
fi
if kill -0 "$environment_wine_pid" >/dev/null 2>&1; then
  echo "stop-prefix left a Wine process with the selected WINEPREFIX alive" >&2
  exit 1
fi
if ! kill -0 "$unrelated_wine_pid" >/dev/null 2>&1; then
  echo "stop-prefix terminated a Wine process belonging to another prefix" >&2
  exit 1
fi
kill -KILL "$unrelated_wine_pid" >/dev/null 2>&1 || true
wait "$unrelated_wine_reaper_pid"
rm -f "$TEST_ROOT/orphan-wine.pid" "$TEST_ROOT/environment-wine.pid" "$TEST_ROOT/unrelated-wine.pid"
: > "$EVENTS"

if TEST_EVENTS="$EVENTS" "$RUNNER" probe-prefix --wine "$TEST_ROOT/custom-wine" --prefix "$PREFIX"; then
  echo "probe should report an unsupported Wine layout" >&2
  exit 1
elif [ "$?" -ne 2 ]; then
  echo "unsupported Wine layout probe returned an unexpected status" >&2
  exit 1
fi
: > "$EVENTS"

TEST_EVENTS="$EVENTS" "$RUNNER" stop-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
expected_stop="$(printf 'wineserver -k prefix=%s\nwineserver -w prefix=%s' "$PREFIX" "$PREFIX")"
actual_stop="$(sed -n '1,2p' "$EVENTS")"
if [ "$actual_stop" != "$expected_stop" ]; then
  echo "stop-prefix did not terminate and wait for the selected Wine prefix" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_stop" "$actual_stop" >&2
  exit 1
fi

: > "$EVENTS"
if TEST_EVENTS="$EVENTS" TEST_KILL_STATUS=2 \
  "$RUNNER" stop-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX" >/dev/null 2>&1; then
  echo "stop-prefix should fail when wineserver rejects the termination request" >&2
  exit 1
fi
: > "$EVENTS"

cat > "$TEST_ROOT/replace.json" <<EOF
{
  "executable": "$BIN_DIR/switchyard-wine",
  "arguments": ["C:\\\\Program Files\\\\Steam\\\\steam.exe"],
  "environment": {"WINEPREFIX": "$PREFIX"},
  "workingDirectory": "$PREFIX",
  "logSource": "test",
  "terminateExistingPrefixSession": true
}
EOF

TEST_EVENTS="$EVENTS" "$RUNNER" run --plan "$TEST_ROOT/replace.json" >/dev/null
expected="$(printf 'wineserver -k prefix=%s\nwineserver -w prefix=%s\nwine C:\\Program Files\\Steam\\steam.exe prefix=%s' "$PREFIX" "$PREFIX" "$PREFIX")"
actual="$(sed -n '1,3p' "$EVENTS")"
if [ "$actual" != "$expected" ]; then
  echo "runner did not stop the existing prefix session before launch" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi

: > "$EVENTS"
TEST_EVENTS="$EVENTS" TEST_KILL_STATUS=1 "$RUNNER" run --plan "$TEST_ROOT/replace.json" >/dev/null
actual="$(sed -n '1,3p' "$EVENTS")"
if [ "$actual" != "$expected" ]; then
  echo "runner should launch when no existing wineserver is running" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi

: > "$EVENTS"
started_at=$SECONDS
if TEST_EVENTS="$EVENTS" TEST_WAIT_HANG=1 SWITCHYARD_TEST_WINESERVER_TIMEOUT=0.1 \
  "$RUNNER" run --plan "$TEST_ROOT/replace.json" >/dev/null 2>&1; then
  echo "runner should fail when wineserver ignores the termination deadline" >&2
  exit 1
fi
if [ "$((SECONDS - started_at))" -gt 3 ]; then
  echo "runner timeout exceeded its hard deadline" >&2
  exit 1
fi

: > "$EVENTS"
TEST_EVENTS="$EVENTS" TEST_WAIT_HANG=1 \
  TEST_WINESERVER_PID_FILE="$TEST_ROOT/preflight-wineserver.pid" \
  SWITCHYARD_TEST_WINESERVER_TIMEOUT=30 \
  "$RUNNER" run --plan "$TEST_ROOT/replace.json" >/dev/null 2>&1 &
preflight_runner_pid=$!
for _ in {1..50}; do
  if [ -s "$TEST_ROOT/preflight-wineserver.pid" ]; then
    break
  fi
  sleep 0.1
done
if [ ! -s "$TEST_ROOT/preflight-wineserver.pid" ]; then
  echo "preflight signal test did not start wineserver" >&2
  exit 1
fi

kill -TERM "$preflight_runner_pid"
set +e
wait "$preflight_runner_pid"
preflight_runner_status=$?
set -e
if [ "$preflight_runner_status" -ne 143 ]; then
  echo "runner returned $preflight_runner_status instead of 143 during wineserver preflight" >&2
  exit 1
fi
preflight_wineserver_pid="$(cat "$TEST_ROOT/preflight-wineserver.pid")"
for _ in {1..50}; do
  if ! kill -0 "$preflight_wineserver_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if kill -0 "$preflight_wineserver_pid" >/dev/null 2>&1; then
  echo "runner left a wineserver child alive after SIGTERM" >&2
  exit 1
fi

: > "$EVENTS"
perl -0pe 's/,\n  "terminateExistingPrefixSession": true//' "$TEST_ROOT/replace.json" > "$TEST_ROOT/reuse.json"
TEST_EVENTS="$EVENTS" "$RUNNER" run --plan "$TEST_ROOT/reuse.json" >/dev/null
if [ "$(sed -n '1p' "$EVENTS")" != "wine C:\\Program Files\\Steam\\steam.exe prefix=$PREFIX" ]; then
  echo "legacy command plans should launch without terminating the prefix session" >&2
  exit 1
fi

: > "$EVENTS"
cat > "$TEST_ROOT/monitor.json" <<EOF
{
  "executable": "$BIN_DIR/switchyard-wine",
  "arguments": ["C:\\\\Game.exe"],
  "environment": {
    "WINEPREFIX": "$PREFIX",
    "SWITCHYARD_PROTOCOL_ASSOCIATIONS_FILE": "C:\\\\windows\\\\temp\\\\switchyard-protocols-v1.txt",
    "TEST_MONITOR_PID_FILE": "$TEST_ROOT/protocol-monitor.pid",
    "TEST_MONITOR_STOPPED_FILE": "$TEST_ROOT/protocol-monitor.stopped"
  },
  "workingDirectory": "$PREFIX",
  "logSource": "protocol-monitor-lifetime-test"
}
EOF

TEST_EVENTS="$EVENTS" "$RUNNER" run --plan "$TEST_ROOT/monitor.json" >/dev/null
if [ ! -s "$TEST_ROOT/protocol-monitor.pid" ] || [ ! -s "$TEST_ROOT/protocol-monitor.stopped" ]; then
  echo "runner did not stop the Wine protocol monitor after the main process exited" >&2
  exit 1
fi
if kill -0 "$(cat "$TEST_ROOT/protocol-monitor.pid")" >/dev/null 2>&1; then
  echo "Wine protocol monitor remained alive after runner exit" >&2
  exit 1
fi

DEBUG_LOG="$TEST_ROOT/logs/debug.log"
cat > "$TEST_ROOT/logging.json" <<EOF
{
  "executable": "/bin/sh",
  "arguments": ["-c", "printf 'stdout-line\\n'; printf 'stderr-line\\n' >&2", "--token=do-not-record"],
  "environment": {},
  "workingDirectory": "$TEST_ROOT",
  "logSource": "logging-test",
  "debugLogPath": "$DEBUG_LOG"
}
EOF

"$RUNNER" run --plan "$TEST_ROOT/logging.json" >/dev/null 2>/dev/null
if [ "$(stat -f '%Lp' "$DEBUG_LOG")" != "600" ] || [ "$(stat -f '%Lp' "$(dirname "$DEBUG_LOG")")" != "700" ]; then
  echo "runner debug logs must be private to the current user" >&2
  exit 1
fi
if ! grep -q 'stdout-line' "$DEBUG_LOG" || ! grep -q 'stderr-line' "$DEBUG_LOG"; then
  echo "runner did not drain stdout and stderr into the debug log" >&2
  exit 1
fi
if grep -q 'do-not-record' "$DEBUG_LOG"; then
  echo "runner wrote a command-line argument value into the debug log" >&2
  exit 1
fi
if ! grep -q 'argumentCount=3' "$DEBUG_LOG"; then
  echo "runner did not record redacted launch metadata" >&2
  exit 1
fi

cat > "$TEST_ROOT/inherit-pipes.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 30 &
printf '%s\n' "$!" > "$DESCENDANT_PID_FILE"
EOF
chmod +x "$TEST_ROOT/inherit-pipes.sh"
cat > "$TEST_ROOT/inherit-pipes.json" <<EOF
{
  "executable": "$TEST_ROOT/inherit-pipes.sh",
  "arguments": [],
  "environment": {"DESCENDANT_PID_FILE": "$TEST_ROOT/descendant.pid"},
  "workingDirectory": "$TEST_ROOT",
  "logSource": "inherited-output-test"
}
EOF

started_at=$SECONDS
SWITCHYARD_TEST_OUTPUT_DRAIN_TIMEOUT=0.1 \
  "$RUNNER" run --plan "$TEST_ROOT/inherit-pipes.json" >/dev/null 2>/dev/null
if [ "$((SECONDS - started_at))" -gt 3 ]; then
  echo "runner waited indefinitely for output inherited by a descendant" >&2
  exit 1
fi
if [ ! -s "$TEST_ROOT/descendant.pid" ]; then
  echo "inherited-output test did not start its descendant" >&2
  exit 1
fi
kill "$(cat "$TEST_ROOT/descendant.pid")" >/dev/null 2>&1 || true

cat > "$TEST_ROOT/signal-child.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'printf "terminated\n" > "$TEST_SIGNAL_MARKER"; exit 0' TERM INT
printf '%s\n' "$$" > "$TEST_SIGNAL_PID_FILE"
while :; do
  sleep 1
done
EOF
chmod +x "$TEST_ROOT/signal-child.sh"
cat > "$TEST_ROOT/signal.json" <<EOF
{
  "executable": "$TEST_ROOT/signal-child.sh",
  "arguments": [],
  "environment": {
    "TEST_SIGNAL_MARKER": "$TEST_ROOT/signal-child.terminated",
    "TEST_SIGNAL_PID_FILE": "$TEST_ROOT/signal-child.pid"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "signal-test"
}
EOF

"$RUNNER" run --plan "$TEST_ROOT/signal.json" >/dev/null 2>/dev/null &
runner_pid=$!
for _ in {1..50}; do
  if [ -s "$TEST_ROOT/signal-child.pid" ]; then
    break
  fi
  sleep 0.1
done
if [ ! -s "$TEST_ROOT/signal-child.pid" ]; then
  echo "signal test did not start its child process" >&2
  exit 1
fi

kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
runner_status=$?
set -e
if [ "$runner_status" -ne 143 ]; then
  echo "runner returned $runner_status instead of 143 after SIGTERM" >&2
  exit 1
fi
for _ in {1..50}; do
  if [ -s "$TEST_ROOT/signal-child.terminated" ]; then
    break
  fi
  sleep 0.1
done
if [ ! -s "$TEST_ROOT/signal-child.terminated" ]; then
  echo "runner did not forward SIGTERM to its child process" >&2
  exit 1
fi

echo "runner_prefix_session tests passed"
