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
  if [ -f "$TEST_ROOT/registry-pipe-holder.pid" ]; then
    kill -KILL "$(cat "$TEST_ROOT/registry-pipe-holder.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/registry-pipe-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/registry-pipe-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/protocol-monitor.pid" ]; then
    kill "$(cat "$TEST_ROOT/protocol-monitor.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/high-volume-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/high-volume-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/high-volume-drainer.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/high-volume-drainer.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/disconnected-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/disconnected-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/disconnected-reader.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/disconnected-reader.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/live-prefix-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/live-prefix-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/live-prefix-descendant.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/live-prefix-descendant.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/live-prefix-probe-wine.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/live-prefix-probe-wine.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/signal-drain-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/signal-drain-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/signal-drain-descendant.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/signal-drain-descendant.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/signal-drain-probe-wine.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/signal-drain-probe-wine.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/clear-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/clear-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/rollover-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/rollover-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/bounded-prefix-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/bounded-prefix-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/bounded-prefix-descendant.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/bounded-prefix-descendant.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/orphan-wine.pid" ]; then
    kill -KILL "$(cat "$TEST_ROOT/orphan-wine.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/active-probe-wine.pid" ]; then
    kill "$(cat "$TEST_ROOT/active-probe-wine.pid")" >/dev/null 2>&1 || true
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
  if [ -f "$TEST_ROOT/locked-list.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/locked-list.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/signal-locked-list.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/signal-locked-list.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/live-activity-lock-holder.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/live-activity-lock-holder.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/live-activation-runner.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/live-activation-runner.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/live-activation-lock-holder.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/live-activation-lock-holder.pid")" >/dev/null 2>&1 || true
  fi
  if [ -f "$TEST_ROOT/locked-probe.pid" ]; then
    kill -TERM "$(cat "$TEST_ROOT/locked-probe.pid")" >/dev/null 2>&1 || true
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
if [ "${1:-}" = "reg" ] && [ "${TEST_REGISTRY_SLEEP:-0}" -eq 1 ]; then
  trap '' TERM
  exec sleep 30
fi
if [ "${1:-}" = "reg" ] && [ "${TEST_REGISTRY_STATUS:-0}" -ne 0 ]; then
  exit "$TEST_REGISTRY_STATUS"
fi
if [ "${1:-}" = "reg" ] \
  && [ -n "${TEST_REGISTRY_PIPE_HOLDER_PID_FILE:-}" ] \
  && [ ! -e "$TEST_REGISTRY_PIPE_HOLDER_PID_FILE" ]; then
  (
    trap '' HUP TERM
    exec sleep 30
  ) &
  printf '%s\n' "$!" > "$TEST_REGISTRY_PIPE_HOLDER_PID_FILE"
fi
if [ -n "${TEST_LIVE_DESCENDANT_READY:-}" ]; then
  (
    printf 'ready\n' > "$TEST_LIVE_DESCENDANT_READY"
    while [ ! -e "$TEST_LIVE_DESCENDANT_RELEASE" ]; do
      sleep 0.05
    done
    printf 'after-direct-child-exit\n'
  ) &
  printf '%s\n' "$!" > "$TEST_LIVE_DESCENDANT_PID_FILE"
  exit 0
fi
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

if TEST_EVENTS="$EVENTS" "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"; then
  echo "probe should report an inactive prefix with status 1" >&2
  exit 1
elif [ "$?" -ne 1 ]; then
  echo "inactive prefix probe returned an unexpected status" >&2
  exit 1
fi
if [ -s "$EVENTS" ]; then
  echo "inactive prefix probe launched wineserver" >&2
  exit 1
fi
inactive_inspection_json="$(
  TEST_EVENTS="$EVENTS" \
    "$RUNNER" inspect-session --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
)"
if [ "$inactive_inspection_json" != '{"hostProcessIDs":[],"state":"inactive"}' ]; then
  echo "inactive session inspection returned unexpected JSON: $inactive_inspection_json" >&2
  exit 1
fi
if [ -s "$EVENTS" ]; then
  echo "inactive session inspection launched wineserver" >&2
  exit 1
fi

(
  "$TEST_ROOT/wine" "$PREFIX" "$TEST_ROOT/active-probe-wine.ready" default &
  wait "$!" >/dev/null 2>&1 || true
) &
active_probe_wine_reaper_pid=$!
for _ in {1..50}; do
  [ -s "$TEST_ROOT/active-probe-wine.ready" ] && break
  sleep 0.02
done
if [ ! -s "$TEST_ROOT/active-probe-wine.ready" ]; then
  echo "active prefix probe fixture did not start" >&2
  exit 1
fi
active_probe_wine_pid="$(cat "$TEST_ROOT/active-probe-wine.ready")"
printf '%s\n' "$active_probe_wine_pid" > "$TEST_ROOT/active-probe-wine.pid"

TEST_EVENTS="$EVENTS" TEST_PROBE_ACTIVE=1 \
  "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
active_inspection_json="$(
  TEST_EVENTS="$EVENTS" TEST_PROBE_ACTIVE=1 \
    "$RUNNER" inspect-session --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
)"
expected_active_inspection_json="{\"hostProcessIDs\":[$active_probe_wine_pid],\"state\":\"active\"}"
if [ "$active_inspection_json" != "$expected_active_inspection_json" ]; then
  echo "active session inspection omitted state or host PID: $active_inspection_json" >&2
  exit 1
fi
kill "$active_probe_wine_pid"
wait "$active_probe_wine_reaper_pid"
rm -f "$TEST_ROOT/active-probe-wine.pid"

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

set +e
TEST_EVENTS="$EVENTS" \
  "$RUNNER" probe-prefix-host --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX" \
  >"$TEST_ROOT/locked-host-probe.out" 2>"$TEST_ROOT/locked-host-probe.err" &
locked_host_probe_pid=$!
set -e
for _ in {1..50}; do
  if ! kill -0 "$locked_host_probe_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.02
done
if kill -0 "$locked_host_probe_pid" >/dev/null 2>&1; then
  kill -TERM "$locked_host_probe_pid" >/dev/null 2>&1 || true
  wait "$locked_host_probe_pid" >/dev/null 2>&1 || true
  echo "probe-prefix-host waited on a storage lock it is meant to recheck from inside" >&2
  exit 1
fi
set +e
wait "$locked_host_probe_pid"
locked_host_probe_status=$?
set -e
if [ "$locked_host_probe_status" -ne 1 ]; then
  echo "probe-prefix-host should report an inactive prefix while the caller holds its storage lock" >&2
  exit 1
fi
if [ -s "$EVENTS" ]; then
  echo "probe-prefix-host launched Wine while a storage lock was held" >&2
  exit 1
fi

TEST_EVENTS="$EVENTS" SWITCHYARD_TEST_SIGNAL_EXIT_TIMEOUT=0.1 \
  "$RUNNER" list-processes --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX" \
  >"$TEST_ROOT/signal-locked-list.out" 2>"$TEST_ROOT/signal-locked-list.err" &
signal_locked_list_pid=$!
printf '%s\n' "$signal_locked_list_pid" > "$TEST_ROOT/signal-locked-list.pid"
for _ in {1..50}; do
  if lsof -a -p "$signal_locked_list_pid" \
    "$PREFIX/.switchyard-prefix.lock" >/dev/null 2>&1; then
    break
  fi
  sleep 0.02
done
if ! lsof -a -p "$signal_locked_list_pid" \
  "$PREFIX/.switchyard-prefix.lock" >/dev/null 2>&1; then
  echo "signal-lock fixture did not block on the prefix lock" >&2
  exit 1
fi
kill -TERM "$signal_locked_list_pid"
for _ in {1..100}; do
  if ! kill -0 "$signal_locked_list_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
if kill -0 "$signal_locked_list_pid" >/dev/null 2>&1; then
  kill -KILL "$signal_locked_list_pid" >/dev/null 2>&1 || true
  echo "locked runner command did not honor the SIGTERM deadline" >&2
  exit 1
fi
set +e
wait "$signal_locked_list_pid"
signal_locked_list_status=$?
set -e
rm -f "$TEST_ROOT/signal-locked-list.pid"
if [ "$signal_locked_list_status" -ne 143 ]; then
  echo "locked runner command returned $signal_locked_list_status instead of 143 after SIGTERM" >&2
  exit 1
fi

TEST_EVENTS="$EVENTS" \
  "$RUNNER" list-processes --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX" \
  >"$TEST_ROOT/locked-list.out" 2>"$TEST_ROOT/locked-list.err" &
locked_list_pid=$!
printf '%s\n' "$locked_list_pid" > "$TEST_ROOT/locked-list.pid"
TEST_EVENTS="$EVENTS" \
  "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX" \
  >"$TEST_ROOT/locked-probe.out" 2>"$TEST_ROOT/locked-probe.err" &
locked_probe_pid=$!
printf '%s\n' "$locked_probe_pid" > "$TEST_ROOT/locked-probe.pid"
for _ in {1..50}; do
  if lsof -a -p "$locked_list_pid" "$PREFIX/.switchyard-prefix.lock" >/dev/null 2>&1 \
    && lsof -a -p "$locked_probe_pid" "$PREFIX/.switchyard-prefix.lock" >/dev/null 2>&1; then
    break
  fi
  sleep 0.02
done
if ! kill -0 "$locked_list_pid" >/dev/null 2>&1; then
  echo "list-processes did not wait for the prefix storage lock" >&2
  exit 1
fi
if ! kill -0 "$locked_probe_pid" >/dev/null 2>&1; then
  echo "probe-prefix did not wait for the prefix storage lock" >&2
  exit 1
fi
if [ -s "$EVENTS" ]; then
  echo "a Wine-backed inspection command launched Wine while a storage lock was held" >&2
  exit 1
fi

MOVED_PREFIX="$TEST_ROOT/Renamed.container"
mv "$PREFIX" "$MOVED_PREFIX"
kill -TERM "$prefix_lock_holder_pid"
wait "$prefix_lock_holder_reaper_pid"
set +e
wait "$locked_list_pid"
locked_list_status=$?
wait "$locked_probe_pid"
locked_probe_status=$?
set -e
if [ "$locked_list_status" -ne 2 ]; then
  echo "list-processes should reject a prefix moved while it waited for the storage lock" >&2
  exit 1
fi
if [ "$locked_probe_status" -ne 2 ]; then
  echo "probe-prefix should reject a prefix moved while it waited for the storage lock" >&2
  exit 1
fi
if [ -s "$EVENTS" ]; then
  echo "a Wine-backed inspection command launched Wine after the locked prefix moved" >&2
  exit 1
fi
mv "$MOVED_PREFIX" "$PREFIX"
rm -f "$TEST_ROOT/prefix-lock-holder.pid" "$TEST_ROOT/locked-list.pid" "$TEST_ROOT/locked-probe.pid"
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
TEST_EVENTS="$EVENTS" "$RUNNER" probe-prefix-host --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
orphan_host_probe_status=$?
set -e
if [ "$orphan_host_probe_status" -ne 3 ]; then
  echo "probe-prefix-host should detect Wine host processes with status 3" >&2
  exit 1
fi
if [ -s "$EVENTS" ]; then
  echo "probe-prefix-host launched Wine while checking existing host processes" >&2
  exit 1
fi

host_processes_json="$(
  TEST_EVENTS="$EVENTS" \
    "$RUNNER" list-host-processes --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
)"
for expected_pid in "$orphan_wine_pid" "$environment_wine_pid"; do
  if ! printf '%s\n' "$host_processes_json" \
    | grep -Eq "(^|\\[|,)$expected_pid(,|\\])"; then
    echo "list-host-processes omitted Wine host process $expected_pid" >&2
    exit 1
  fi
done
if printf '%s\n' "$host_processes_json" \
  | grep -Eq "(^|\\[|,)$unrelated_wine_pid(,|\\])"; then
  echo "list-host-processes included a Wine process from another prefix" >&2
  exit 1
fi
if [ -s "$EVENTS" ]; then
  echo "list-host-processes launched Wine while inspecting host processes" >&2
  exit 1
fi
orphan_inspection_json="$(
  TEST_EVENTS="$EVENTS" \
    "$RUNNER" inspect-session --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
)"
expected_orphan_process_ids="$(
  printf '%s\n%s\n' "$orphan_wine_pid" "$environment_wine_pid" | sort -n | paste -sd, -
)"
expected_orphan_inspection_json="{\"hostProcessIDs\":[$expected_orphan_process_ids],\"state\":\"orphaned\"}"
if [ "$orphan_inspection_json" != "$expected_orphan_inspection_json" ]; then
  echo "orphaned session inspection omitted state or host PID: $orphan_inspection_json" >&2
  exit 1
fi

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

assert_display_mode() {
  mode="$1"
  retina_value="$2"
  dpi_value="$3"
  plan_path="$TEST_ROOT/display-$mode.json"
  cat > "$plan_path" <<EOF
{
  "executable": "$BIN_DIR/switchyard-wine",
  "arguments": ["C:\\\\Game.exe"],
  "environment": {"WINEPREFIX": "$PREFIX"},
  "workingDirectory": "$PREFIX",
  "logSource": "display-test",
  "containerDisplayMode": "$mode"
}
EOF

  : > "$EVENTS"
  TEST_EVENTS="$EVENTS" "$RUNNER" run --plan "$plan_path" >/dev/null
  expected_display="$(printf \
    'wine reg add HKCU\\Software\\Wine\\Mac Driver /v RetinaMode /t REG_SZ /d %s /f prefix=%s\nwine reg add HKCU\\Control Panel\\Desktop /v LogPixels /t REG_DWORD /d %s /f prefix=%s\nwineserver -k prefix=%s\nwineserver -w prefix=%s\nwine C:\\Game.exe prefix=%s' \
    "$retina_value" "$PREFIX" "$dpi_value" "$PREFIX" "$PREFIX" "$PREFIX" "$PREFIX")"
  actual_display="$(sed -n '1,5p' "$EVENTS")"
  if [ "$actual_display" != "$expected_display" ]; then
    echo "runner did not restart Wine after applying display mode $mode" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected_display" "$actual_display" >&2
    exit 1
  fi
}

assert_display_mode standard N 96
assert_display_mode retina Y 96
assert_display_mode retinaWithLargerInterface Y 192

: > "$EVENTS"
TEST_EVENTS="$EVENTS" \
  TEST_REGISTRY_PIPE_HOLDER_PID_FILE="$TEST_ROOT/registry-pipe-holder.pid" \
  "$RUNNER" run --plan "$TEST_ROOT/display-retina.json" >/dev/null 2>&1 &
registry_pipe_runner_pid=$!
printf '%s\n' "$registry_pipe_runner_pid" > "$TEST_ROOT/registry-pipe-runner.pid"
for _ in {1..60}; do
  if ! kill -0 "$registry_pipe_runner_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
if kill -0 "$registry_pipe_runner_pid" >/dev/null 2>&1; then
  echo "runner waited for a wineserver descendant to close a registry output pipe" >&2
  exit 1
fi
wait "$registry_pipe_runner_pid"
rm -f "$TEST_ROOT/registry-pipe-runner.pid"
if [ "$(tail -n 1 "$EVENTS")" != "wine C:\\Game.exe prefix=$PREFIX" ]; then
  echo "runner did not launch the target after a cold registry helper exited" >&2
  exit 1
fi
kill -KILL "$(cat "$TEST_ROOT/registry-pipe-holder.pid")" >/dev/null 2>&1 || true
rm -f "$TEST_ROOT/registry-pipe-holder.pid"

: > "$EVENTS"
if TEST_EVENTS="$EVENTS" TEST_REGISTRY_STATUS=9 \
  "$RUNNER" run --plan "$TEST_ROOT/display-retina.json" >/dev/null 2>&1; then
  echo "runner should fail when the Wine display registry update fails" >&2
  exit 1
fi
if [ "$(wc -l < "$EVENTS" | tr -d ' ')" -ne 3 ]; then
  echo "runner launched the target after a Wine display registry update failed" >&2
  exit 1
fi

: > "$EVENTS"
registry_timeout_started_at=$SECONDS
if TEST_EVENTS="$EVENTS" TEST_REGISTRY_SLEEP=1 SWITCHYARD_TEST_WINE_REGISTRY_TIMEOUT=0.1 \
  "$RUNNER" run --plan "$TEST_ROOT/display-retina.json" >/dev/null 2>&1; then
  echo "runner should fail when a Wine display registry update times out" >&2
  exit 1
fi
if [ "$((SECONDS - registry_timeout_started_at))" -gt 3 ]; then
  echo "runner did not stop a timed-out Wine display registry update promptly" >&2
  exit 1
fi
if [ "$(wc -l < "$EVENTS" | tr -d ' ')" -ne 3 ]; then
  echo "runner launched the target after a Wine display registry update timed out" >&2
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

cat > "$TEST_ROOT/repeated-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for index in {1..1000}; do
  printf '%d.000:%04x:warn:d3d_perf:wined3d_cs_map_upload_bo repeated warning\n' \
    "$index" "$((index % 16))" >&2
done
EOF
chmod +x "$TEST_ROOT/repeated-output.sh"
REPEATED_LIVE_LOG="$TEST_ROOT/live/repeated.jsonl"
REPEATED_FORWARDED_OUTPUT="$TEST_ROOT/repeated-forwarded-output.log"
LIVE_ACTIVITY_LOCK="$TEST_ROOT/live/.view-active.lock"
LIVE_ACTIVITY_READY="$TEST_ROOT/live-activity.ready"
LIVE_ACTIVITY_RELEASE="$TEST_ROOT/live-activity.release"
mkdir -p "$TEST_ROOT/live"
: > "$LIVE_ACTIVITY_LOCK"
chmod 600 "$LIVE_ACTIVITY_LOCK"
perl -MFcntl=:flock -e '
  my ($lock_path, $ready_path, $release_path) = @ARGV;
  open(my $lock_handle, "+<", $lock_path) or die $!;
  flock($lock_handle, LOCK_EX) or die $!;
  open(my $ready_handle, ">", $ready_path) or die $!;
  print {$ready_handle} "ready\n";
  close($ready_handle);
  while (!-e $release_path) {
    select(undef, undef, undef, 0.05);
  }
' "$LIVE_ACTIVITY_LOCK" "$LIVE_ACTIVITY_READY" "$LIVE_ACTIVITY_RELEASE" &
printf '%s\n' "$!" > "$TEST_ROOT/live-activity-lock-holder.pid"
for _ in {1..50}; do
  if [ -s "$LIVE_ACTIVITY_READY" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$LIVE_ACTIVITY_READY" ]; then
  echo "live log view activity lock holder did not start" >&2
  exit 1
fi
cat > "$TEST_ROOT/repeated-output.json" <<EOF
{
  "executable": "$TEST_ROOT/repeated-output.sh",
  "arguments": [],
  "environment": {},
  "workingDirectory": "$TEST_ROOT",
  "logSource": "repeated-output-test",
  "liveLogPath": "$REPEATED_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF

"$RUNNER" run --plan "$TEST_ROOT/repeated-output.json" \
  >"$REPEATED_FORWARDED_OUTPUT" 2>&1
if [ -s "$REPEATED_FORWARDED_OUTPUT" ]; then
  echo "runner forwarded output that was already routed through the live journal" >&2
  exit 1
fi
repeated_live_line_count="$(wc -l < "$REPEATED_LIVE_LOG" | tr -d ' ')"
if [ "$repeated_live_line_count" -ge 32 ]; then
  echo "runner did not compact repeated live log entries" >&2
  exit 1
fi
repeated_live_id_count="$(
  grep -o '"id":"[^"]*"' "$REPEATED_LIVE_LOG" | wc -l | tr -d ' '
)"
repeated_live_unique_id_count="$(
  grep -o '"id":"[^"]*"' "$REPEATED_LIVE_LOG" | sort -u | wc -l | tr -d ' '
)"
if [ "$repeated_live_id_count" -ne "$repeated_live_unique_id_count" ]; then
  echo "runner reused live log identities for repetition summaries" >&2
  exit 1
fi
represented_repetitions="$(
  grep -o '"occurrenceCount":[0-9]*' "$REPEATED_LIVE_LOG" \
    | awk -F: '{ total += $2 } END { print total + 0 }'
)"
if [ "$represented_repetitions" -ne 999 ]; then
  echo "runner did not preserve the repeated live log occurrence count" >&2
  exit 1
fi
repeated_summary_line="$(
  grep -n '"occurrenceCount":' "$REPEATED_LIVE_LOG" | tail -n 1 | cut -d: -f1
)"
repeated_exit_line="$(
  grep -n 'switchyard-runner exit' "$REPEATED_LIVE_LOG" | tail -n 1 | cut -d: -f1
)"
if [ "$repeated_summary_line" -ge "$repeated_exit_line" ]; then
  echo "runner persisted a repetition summary after a newer log entry" >&2
  exit 1
fi

touch "$LIVE_ACTIVITY_RELEASE"
wait "$(cat "$TEST_ROOT/live-activity-lock-holder.pid")"
rm -f "$TEST_ROOT/live-activity-lock-holder.pid"

INACTIVE_LIVE_LOG="$TEST_ROOT/live/inactive.jsonl"
cat > "$TEST_ROOT/inactive-output.json" <<EOF
{
  "executable": "$TEST_ROOT/repeated-output.sh",
  "arguments": [],
  "environment": {},
  "workingDirectory": "$TEST_ROOT",
  "logSource": "inactive-output-test",
  "liveLogPath": "$INACTIVE_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF

"$RUNNER" run --plan "$TEST_ROOT/inactive-output.json" >/dev/null 2>/dev/null
if grep -q '"occurrenceCount":' "$INACTIVE_LIVE_LOG"; then
  echo "runner filtered live logs while the Logs view was inactive" >&2
  exit 1
fi
inactive_repeated_line_count="$(
  grep -c 'repeated warning' "$INACTIVE_LIVE_LOG" | tr -d ' '
)"
if [ "$inactive_repeated_line_count" -ne 1000 ]; then
  echo "runner did not retain inactive live logs for later replay" >&2
  exit 1
fi

LIVE_ACTIVATION_READY="$TEST_ROOT/live-activation-child.ready"
LIVE_ACTIVATION_RELEASE="$TEST_ROOT/live-activation-child.release"
LIVE_ACTIVATION_LOCK_READY="$TEST_ROOT/live-activation-lock.ready"
LIVE_ACTIVATION_LOCK_RELEASE="$TEST_ROOT/live-activation-lock.release"
LIVE_ACTIVATION_LOG="$TEST_ROOT/live/activation.jsonl"
cat > "$TEST_ROOT/live-activation-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'buffered-before-activation\n' >&2
printf 'ready\n' > "$TEST_LIVE_ACTIVATION_READY"
while [ ! -e "$TEST_LIVE_ACTIVATION_RELEASE" ]; do
  sleep 0.05
done
printf 'written-after-activation\n' >&2
EOF
chmod +x "$TEST_ROOT/live-activation-output.sh"
cat > "$TEST_ROOT/live-activation-output.json" <<EOF
{
  "executable": "$TEST_ROOT/live-activation-output.sh",
  "arguments": [],
  "environment": {
    "TEST_LIVE_ACTIVATION_READY": "$LIVE_ACTIVATION_READY",
    "TEST_LIVE_ACTIVATION_RELEASE": "$LIVE_ACTIVATION_RELEASE"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "live-activation-test",
  "liveLogPath": "$LIVE_ACTIVATION_LOG",
  "forwardCapturedOutput": false
}
EOF

"$RUNNER" run --plan "$TEST_ROOT/live-activation-output.json" >/dev/null 2>/dev/null &
printf '%s\n' "$!" > "$TEST_ROOT/live-activation-runner.pid"
for _ in {1..50}; do
  if [ -s "$LIVE_ACTIVATION_READY" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$LIVE_ACTIVATION_READY" ]; then
  echo "inactive live log fixture did not start" >&2
  exit 1
fi
sleep 0.35
if ! grep -q 'buffered-before-activation' "$LIVE_ACTIVATION_LOG"; then
  echo "runner did not durably batch logs while the Logs view was inactive" >&2
  exit 1
fi
if grep -q '"occurrenceCount":' "$LIVE_ACTIVATION_LOG"; then
  echo "runner filtered batched logs while the Logs view was inactive" >&2
  exit 1
fi

perl -MFcntl=:flock -e '
  my ($lock_path, $ready_path, $release_path) = @ARGV;
  open(my $lock_handle, "+<", $lock_path) or die $!;
  flock($lock_handle, LOCK_EX) or die $!;
  open(my $ready_handle, ">", $ready_path) or die $!;
  print {$ready_handle} "ready\n";
  close($ready_handle);
  while (!-e $release_path) {
    select(undef, undef, undef, 0.05);
  }
' "$LIVE_ACTIVITY_LOCK" "$LIVE_ACTIVATION_LOCK_READY" "$LIVE_ACTIVATION_LOCK_RELEASE" &
printf '%s\n' "$!" > "$TEST_ROOT/live-activation-lock-holder.pid"
for _ in {1..50}; do
  if [ -s "$LIVE_ACTIVATION_LOCK_READY" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$LIVE_ACTIVATION_LOCK_READY" ]; then
  echo "live log activation lock holder did not start" >&2
  exit 1
fi
for _ in {1..50}; do
  if grep -q 'buffered-before-activation' "$LIVE_ACTIVATION_LOG"; then
    break
  fi
  sleep 0.05
done
if ! grep -q 'buffered-before-activation' "$LIVE_ACTIVATION_LOG"; then
  echo "runner did not flush existing logs when Logs became active" >&2
  exit 1
fi

touch "$LIVE_ACTIVATION_RELEASE"
wait "$(cat "$TEST_ROOT/live-activation-runner.pid")"
rm -f "$TEST_ROOT/live-activation-runner.pid"
touch "$LIVE_ACTIVATION_LOCK_RELEASE"
wait "$(cat "$TEST_ROOT/live-activation-lock-holder.pid")"
rm -f "$TEST_ROOT/live-activation-lock-holder.pid"
if ! grep -q 'written-after-activation' "$LIVE_ACTIVATION_LOG"; then
  echo "runner did not keep filtering after Logs became active" >&2
  exit 1
fi
rm -f "$LIVE_ACTIVITY_LOCK"

cat > "$TEST_ROOT/clear-pending-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for index in {1..10}; do
  printf '%d.000:0010:warn:d3d_perf:pending clear warning\n' "$index" >&2
done
printf 'ready\n' > "$TEST_CLEAR_READY"
while [ ! -e "$TEST_CLEAR_RELEASE" ]; do
  sleep 0.05
done
printf '11.000:0010:warn:d3d_perf:pending clear warning\n' >&2
printf 'after-clear-marker\n' >&2
EOF
chmod +x "$TEST_ROOT/clear-pending-output.sh"
cat > "$TEST_ROOT/regrow-cleared-journal.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dd if=/dev/zero bs=8192 count=1 2>/dev/null | tr '\0' 'r'
printf '\n'
EOF
chmod +x "$TEST_ROOT/regrow-cleared-journal.sh"
CLEAR_LIVE_LOG="$TEST_ROOT/live/clear-pending.jsonl"
cat > "$TEST_ROOT/clear-pending-output.json" <<EOF
{
  "executable": "$TEST_ROOT/clear-pending-output.sh",
  "arguments": [],
  "environment": {
    "TEST_CLEAR_READY": "$TEST_ROOT/clear-pending-output.ready",
    "TEST_CLEAR_RELEASE": "$TEST_ROOT/clear-pending-output.release"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "clear-pending-output-test",
  "liveLogPath": "$CLEAR_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF
cat > "$TEST_ROOT/regrow-cleared-journal.json" <<EOF
{
  "executable": "$TEST_ROOT/regrow-cleared-journal.sh",
  "arguments": [],
  "environment": {},
  "workingDirectory": "$TEST_ROOT",
  "logSource": "regrow-cleared-journal-test",
  "liveLogPath": "$CLEAR_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF

"$RUNNER" run --plan "$TEST_ROOT/clear-pending-output.json" \
  >/dev/null 2>/dev/null &
clear_runner_pid=$!
printf '%s\n' "$clear_runner_pid" > "$TEST_ROOT/clear-runner.pid"
for _ in {1..100}; do
  if [ -s "$TEST_ROOT/clear-pending-output.ready" ] \
    && grep -q 'pending clear warning' "$CLEAR_LIVE_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/clear-pending-output.ready" ] \
  || ! grep -q 'pending clear warning' "$CLEAR_LIVE_LOG" 2>/dev/null; then
  echo "clear-pending fixture did not produce its initial live log entry" >&2
  exit 1
fi
clear_pre_reset_size="$(stat -f '%z' "$CLEAR_LIVE_LOG")"
dd if=/dev/urandom of="${CLEAR_LIVE_LOG}.generation" \
  bs=16 count=1 2>/dev/null
: > "$CLEAR_LIVE_LOG"
"$RUNNER" run --plan "$TEST_ROOT/regrow-cleared-journal.json" \
  >/dev/null 2>/dev/null
if [ "$(stat -f '%z' "$CLEAR_LIVE_LOG")" -lt "$clear_pre_reset_size" ]; then
  echo "multi-writer fixture did not regrow the cleared journal" >&2
  exit 1
fi
touch "$TEST_ROOT/clear-pending-output.release"
wait "$clear_runner_pid"
rm -f "$TEST_ROOT/clear-runner.pid"
if [ "$(grep -c 'pending clear warning' "$CLEAR_LIVE_LOG")" -ne 1 ]; then
  echo "runner restored repetitions that were removed by clearing the journal" >&2
  exit 1
fi
if grep -q '"occurrenceCount":' "$CLEAR_LIVE_LOG"; then
  echo "runner mixed pre-clear repetitions into the post-clear journal" >&2
  exit 1
fi
if ! grep -q 'after-clear-marker' "$CLEAR_LIVE_LOG"; then
  echo "runner stopped live logging after the journal was cleared" >&2
  exit 1
fi

: > "$LIVE_ACTIVITY_LOCK"
chmod 600 "$LIVE_ACTIVITY_LOCK"
INACTIVE_CLEAR_LIVE_LOG="$TEST_ROOT/live/inactive-clear.jsonl"
cat > "$TEST_ROOT/inactive-clear-output.json" <<EOF
{
  "executable": "$TEST_ROOT/clear-pending-output.sh",
  "arguments": [],
  "environment": {
    "TEST_CLEAR_READY": "$TEST_ROOT/inactive-clear-output.ready",
    "TEST_CLEAR_RELEASE": "$TEST_ROOT/inactive-clear-output.release"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "inactive-clear-output-test",
  "liveLogPath": "$INACTIVE_CLEAR_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF

"$RUNNER" run --plan "$TEST_ROOT/inactive-clear-output.json" \
  >/dev/null 2>/dev/null &
inactive_clear_runner_pid=$!
printf '%s\n' "$inactive_clear_runner_pid" > "$TEST_ROOT/clear-runner.pid"
for _ in {1..100}; do
  if [ -s "$TEST_ROOT/inactive-clear-output.ready" ] \
    && grep -q 'pending clear warning' "$INACTIVE_CLEAR_LIVE_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/inactive-clear-output.ready" ] \
  || ! grep -q 'pending clear warning' "$INACTIVE_CLEAR_LIVE_LOG" 2>/dev/null; then
  echo "inactive clear fixture did not durably batch its initial logs" >&2
  exit 1
fi
dd if=/dev/urandom of="${INACTIVE_CLEAR_LIVE_LOG}.generation" \
  bs=16 count=1 2>/dev/null
: > "$INACTIVE_CLEAR_LIVE_LOG"
touch "$TEST_ROOT/inactive-clear-output.release"
wait "$inactive_clear_runner_pid"
rm -f "$TEST_ROOT/clear-runner.pid"
if [ "$(grep -c 'pending clear warning' "$INACTIVE_CLEAR_LIVE_LOG")" -ne 1 ]; then
  echo "inactive runner restored logs removed by clearing the journal" >&2
  exit 1
fi
if grep -q '"occurrenceCount":' "$INACTIVE_CLEAR_LIVE_LOG"; then
  echo "inactive runner filtered post-clear logs" >&2
  exit 1
fi
if ! grep -q 'after-clear-marker' "$INACTIVE_CLEAR_LIVE_LOG"; then
  echo "inactive runner discarded logs emitted immediately after clear" >&2
  exit 1
fi
rm -f "$LIVE_ACTIVITY_LOCK"

cat > "$TEST_ROOT/rollover-pending-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dd if=/dev/zero bs=2500 count=1 2>/dev/null | tr '\0' 'p'
printf '\n'
for index in {1..10}; do
  printf '%d.000:0010:warn:d3d_perf:pending rollover warning\n' "$index" >&2
done
printf 'ready\n' > "$TEST_ROLLOVER_READY"
while [ ! -e "$TEST_ROLLOVER_RELEASE" ]; do
  sleep 0.05
done
printf '11.000:0010:warn:d3d_perf:pending rollover warning\n' >&2
printf 'after-rollover-marker\n' >&2
EOF
cat > "$TEST_ROOT/rollover-fill-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rollover-fill-'
dd if=/dev/zero bs=6500 count=1 2>/dev/null | tr '\0' 'f'
printf '\n'
EOF
chmod +x \
  "$TEST_ROOT/rollover-pending-output.sh" \
  "$TEST_ROOT/rollover-fill-output.sh"
ROLLOVER_LIVE_LOG="$TEST_ROOT/live/rollover-pending.jsonl"
cat > "$TEST_ROOT/rollover-pending-output.json" <<EOF
{
  "executable": "$TEST_ROOT/rollover-pending-output.sh",
  "arguments": [],
  "environment": {
    "TEST_ROLLOVER_READY": "$TEST_ROOT/rollover-pending-output.ready",
    "TEST_ROLLOVER_RELEASE": "$TEST_ROOT/rollover-pending-output.release"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "rollover-pending-output-test",
  "liveLogPath": "$ROLLOVER_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF
cat > "$TEST_ROOT/rollover-fill-output.json" <<EOF
{
  "executable": "$TEST_ROOT/rollover-fill-output.sh",
  "arguments": [],
  "environment": {},
  "workingDirectory": "$TEST_ROOT",
  "logSource": "rollover-fill-output-test",
  "liveLogPath": "$ROLLOVER_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF

SWITCHYARD_TEST_LIVE_LOG_MAX_BYTES=9000 \
  "$RUNNER" run --plan "$TEST_ROOT/rollover-pending-output.json" \
  >/dev/null 2>/dev/null &
rollover_runner_pid=$!
printf '%s\n' "$rollover_runner_pid" > "$TEST_ROOT/rollover-runner.pid"
for _ in {1..100}; do
  if [ -s "$TEST_ROOT/rollover-pending-output.ready" ] \
    && grep -q 'pending rollover warning' "$ROLLOVER_LIVE_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/rollover-pending-output.ready" ] \
  || ! grep -q 'pending rollover warning' "$ROLLOVER_LIVE_LOG" 2>/dev/null; then
  echo "rollover-pending fixture did not produce its initial live log entry" >&2
  exit 1
fi
rollover_pre_reset_size="$(stat -f '%z' "$ROLLOVER_LIVE_LOG")"
cp "${ROLLOVER_LIVE_LOG}.generation" \
  "$TEST_ROOT/rollover-before.generation"
SWITCHYARD_TEST_LIVE_LOG_MAX_BYTES=9000 \
  "$RUNNER" run --plan "$TEST_ROOT/rollover-fill-output.json" \
  >/dev/null 2>/dev/null
if cmp -s \
  "$TEST_ROOT/rollover-before.generation" \
  "${ROLLOVER_LIVE_LOG}.generation"; then
  echo "runner rollover did not advance the live log reset generation" >&2
  exit 1
fi
if [ "$(stat -f '%z' "$ROLLOVER_LIVE_LOG")" -lt "$rollover_pre_reset_size" ]; then
  echo "multi-writer rollover fixture did not regrow the journal" >&2
  exit 1
fi
rollover_fill_line="$(
  grep -n '"message":"rollover-fill-' "$ROLLOVER_LIVE_LOG" \
    | tail -n 1 | cut -d: -f1
)"
rollover_warning_line="$(
  grep -n 'Live log journal reached its size limit' "$ROLLOVER_LIVE_LOG" \
    | tail -n 1 | cut -d: -f1
)"
if [ "$rollover_fill_line" -ge "$rollover_warning_line" ]; then
  echo "runner persisted the rollover warning before the retained log entry" >&2
  exit 1
fi
cp "${ROLLOVER_LIVE_LOG}.generation" \
  "$TEST_ROOT/rollover-after-fill.generation"
touch "$TEST_ROOT/rollover-pending-output.release"
wait "$rollover_runner_pid"
rm -f "$TEST_ROOT/rollover-runner.pid"
if ! cmp -s \
  "$TEST_ROOT/rollover-after-fill.generation" \
  "${ROLLOVER_LIVE_LOG}.generation"; then
  echo "rollover fixture unexpectedly crossed the journal limit again" >&2
  exit 1
fi
if [ "$(grep -c 'pending rollover warning' "$ROLLOVER_LIVE_LOG")" -ne 1 ]; then
  echo "runner restored repetitions that were removed by journal rollover" >&2
  exit 1
fi
if grep -q '"occurrenceCount":' "$ROLLOVER_LIVE_LOG"; then
  echo "runner mixed pre-rollover repetitions into the new journal" >&2
  exit 1
fi
if ! grep -q 'after-rollover-marker' "$ROLLOVER_LIVE_LOG"; then
  echo "runner stopped live logging after journal rollover" >&2
  exit 1
fi

cat > "$TEST_ROOT/disconnected-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'before-disconnect\n'
printf 'ready\n' > "$TEST_DISCONNECTED_READY"
while [ ! -e "$TEST_DISCONNECTED_RELEASE" ]; do
  sleep 0.05
done
printf 'after-disconnect\n'
EOF
chmod +x "$TEST_ROOT/disconnected-output.sh"
DISCONNECTED_LIVE_LOG="$TEST_ROOT/live/disconnected.jsonl"
cat > "$TEST_ROOT/disconnected-output.json" <<EOF
{
  "executable": "$TEST_ROOT/disconnected-output.sh",
  "arguments": [],
  "environment": {
    "TEST_DISCONNECTED_READY": "$TEST_ROOT/disconnected-output.ready",
    "TEST_DISCONNECTED_RELEASE": "$TEST_ROOT/disconnected-output.release"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "disconnected-output-test",
  "liveLogPath": "$DISCONNECTED_LIVE_LOG"
}
EOF

mkfifo "$TEST_ROOT/disconnected-runner.out"
(
  IFS= read -r _
  printf 'closed\n' > "$TEST_ROOT/disconnected-reader.closed"
) <"$TEST_ROOT/disconnected-runner.out" &
disconnected_reader_pid=$!
printf '%s\n' "$disconnected_reader_pid" > "$TEST_ROOT/disconnected-reader.pid"
"$RUNNER" run --plan "$TEST_ROOT/disconnected-output.json" \
  >"$TEST_ROOT/disconnected-runner.out" 2>&1 &
disconnected_runner_pid=$!
printf '%s\n' "$disconnected_runner_pid" > "$TEST_ROOT/disconnected-runner.pid"
for _ in {1..100}; do
  [ -s "$TEST_ROOT/disconnected-output.ready" ] \
    && [ -s "$TEST_ROOT/disconnected-reader.closed" ] \
    && break
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/disconnected-output.ready" ] \
  || [ ! -s "$TEST_ROOT/disconnected-reader.closed" ]; then
  echo "disconnected output fixture did not reach its release gate" >&2
  exit 1
fi
touch "$TEST_ROOT/disconnected-output.release"
wait "$disconnected_runner_pid"
wait "$disconnected_reader_pid"
rm -f "$TEST_ROOT/disconnected-runner.pid" "$TEST_ROOT/disconnected-reader.pid"
if ! grep -q 'after-disconnect' "$DISCONNECTED_LIVE_LOG"; then
  echo "runner stopped updating the live journal after its app output pipe closed" >&2
  exit 1
fi
if [ "$(stat -f '%Lp' "$DISCONNECTED_LIVE_LOG")" != "600" ] \
  || [ "$(stat -f '%Lp' "$(dirname "$DISCONNECTED_LIVE_LOG")")" != "700" ]; then
  echo "runner live log journals must be private to the current user" >&2
  exit 1
fi

ACTIVE_PREFIX_LIVE_LOG="$TEST_ROOT/live/active-prefix.jsonl"
cat > "$TEST_ROOT/active-prefix-output.json" <<EOF
{
  "executable": "$BIN_DIR/switchyard-wine",
  "arguments": ["C:\\\\Games\\\\Launcher.exe"],
  "environment": {
    "WINEPREFIX": "$PREFIX",
    "TEST_LIVE_DESCENDANT_PID_FILE": "$TEST_ROOT/live-prefix-descendant.pid",
    "TEST_LIVE_DESCENDANT_READY": "$TEST_ROOT/live-prefix-descendant.ready",
    "TEST_LIVE_DESCENDANT_RELEASE": "$TEST_ROOT/live-prefix-descendant.release"
  },
  "workingDirectory": "$PREFIX",
  "logSource": "active-prefix-output-test",
  "liveLogPath": "$ACTIVE_PREFIX_LIVE_LOG"
}
EOF

(
  "$TEST_ROOT/wine" "$PREFIX" "$TEST_ROOT/live-prefix-probe-wine.ready" default &
  wait "$!" >/dev/null 2>&1 || true
) &
live_prefix_probe_wine_reaper_pid=$!
for _ in {1..50}; do
  [ -s "$TEST_ROOT/live-prefix-probe-wine.ready" ] && break
  sleep 0.02
done
if [ ! -s "$TEST_ROOT/live-prefix-probe-wine.ready" ]; then
  echo "active-prefix probe Wine fixture did not start" >&2
  exit 1
fi
live_prefix_probe_wine_pid="$(cat "$TEST_ROOT/live-prefix-probe-wine.ready")"
printf '%s\n' "$live_prefix_probe_wine_pid" > "$TEST_ROOT/live-prefix-probe-wine.pid"

TEST_EVENTS="$EVENTS" TEST_PROBE_ACTIVE=1 SWITCHYARD_TEST_OUTPUT_DRAIN_TIMEOUT=0.1 \
  "$RUNNER" run --plan "$TEST_ROOT/active-prefix-output.json" >/dev/null 2>/dev/null &
live_prefix_runner_pid=$!
printf '%s\n' "$live_prefix_runner_pid" > "$TEST_ROOT/live-prefix-runner.pid"
for _ in {1..100}; do
  [ -s "$TEST_ROOT/live-prefix-descendant.ready" ] && break
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/live-prefix-descendant.ready" ]; then
  echo "active-prefix output fixture did not start its descendant" >&2
  exit 1
fi
sleep 0.5
if ! kill -0 "$live_prefix_runner_pid" >/dev/null 2>&1; then
  echo "runner stopped live logging while wineserver still reported an active prefix" >&2
  exit 1
fi
touch "$TEST_ROOT/live-prefix-descendant.release"
wait "$live_prefix_runner_pid"
kill -TERM "$live_prefix_probe_wine_pid"
wait "$live_prefix_probe_wine_reaper_pid"
rm -f \
  "$TEST_ROOT/live-prefix-runner.pid" \
  "$TEST_ROOT/live-prefix-descendant.pid" \
  "$TEST_ROOT/live-prefix-probe-wine.pid"
if ! grep -q 'after-direct-child-exit' "$ACTIVE_PREFIX_LIVE_LOG"; then
  echo "runner did not retain descendant output while wineserver remained active" >&2
  exit 1
fi

SIGNAL_DRAIN_LIVE_LOG="$TEST_ROOT/live/signal-drain.jsonl"
cat > "$TEST_ROOT/signal-drain-output.json" <<EOF
{
  "executable": "$BIN_DIR/switchyard-wine",
  "arguments": ["C:\\\\Games\\\\Launcher.exe"],
  "environment": {
    "WINEPREFIX": "$PREFIX",
    "TEST_LIVE_DESCENDANT_PID_FILE": "$TEST_ROOT/signal-drain-descendant.pid",
    "TEST_LIVE_DESCENDANT_READY": "$TEST_ROOT/signal-drain-descendant.ready",
    "TEST_LIVE_DESCENDANT_RELEASE": "$TEST_ROOT/signal-drain-descendant.release"
  },
  "workingDirectory": "$PREFIX",
  "logSource": "signal-drain-output-test",
  "liveLogPath": "$SIGNAL_DRAIN_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF

(
  "$TEST_ROOT/wine" "$PREFIX" "$TEST_ROOT/signal-drain-probe-wine.ready" default &
  wait "$!" >/dev/null 2>&1 || true
) &
signal_drain_probe_wine_reaper_pid=$!
for _ in {1..50}; do
  [ -s "$TEST_ROOT/signal-drain-probe-wine.ready" ] && break
  sleep 0.02
done
if [ ! -s "$TEST_ROOT/signal-drain-probe-wine.ready" ]; then
  echo "signal-drain probe Wine fixture did not start" >&2
  exit 1
fi
signal_drain_probe_wine_pid="$(
  cat "$TEST_ROOT/signal-drain-probe-wine.ready"
)"
printf '%s\n' "$signal_drain_probe_wine_pid" \
  > "$TEST_ROOT/signal-drain-probe-wine.pid"

TEST_EVENTS="$EVENTS" TEST_PROBE_ACTIVE=1 SWITCHYARD_TEST_OUTPUT_DRAIN_TIMEOUT=0.1 \
  "$RUNNER" run --plan "$TEST_ROOT/signal-drain-output.json" \
  >/dev/null 2>/dev/null &
signal_drain_runner_pid=$!
printf '%s\n' "$signal_drain_runner_pid" > "$TEST_ROOT/signal-drain-runner.pid"
for _ in {1..100}; do
  if [ -s "$TEST_ROOT/signal-drain-descendant.ready" ] \
    && grep -q 'continuing live log capture' "$SIGNAL_DRAIN_LIVE_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/signal-drain-descendant.ready" ] \
  || ! grep -q 'continuing live log capture' "$SIGNAL_DRAIN_LIVE_LOG" 2>/dev/null; then
  echo "signal-drain fixture did not enter extended output draining" >&2
  exit 1
fi
kill -TERM "$signal_drain_runner_pid"
for _ in {1..100}; do
  if ! kill -0 "$signal_drain_runner_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
if kill -0 "$signal_drain_runner_pid" >/dev/null 2>&1; then
  kill -KILL "$signal_drain_runner_pid" >/dev/null 2>&1 || true
  echo "runner did not leave extended output draining after SIGTERM" >&2
  exit 1
fi
set +e
wait "$signal_drain_runner_pid"
signal_drain_status=$?
set -e
if [ "$signal_drain_status" -ne 143 ]; then
  echo "extended-drain runner returned $signal_drain_status instead of 143 after SIGTERM" >&2
  exit 1
fi
kill -TERM "$(cat "$TEST_ROOT/signal-drain-descendant.pid")" >/dev/null 2>&1 || true
kill -TERM "$signal_drain_probe_wine_pid"
wait "$signal_drain_probe_wine_reaper_pid"
rm -f \
  "$TEST_ROOT/signal-drain-runner.pid" \
  "$TEST_ROOT/signal-drain-descendant.pid" \
  "$TEST_ROOT/signal-drain-probe-wine.pid"

BOUNDED_PREFIX_LIVE_LOG="$TEST_ROOT/live/bounded-prefix.jsonl"
cat > "$TEST_ROOT/bounded-prefix-output.json" <<EOF
{
  "executable": "$BIN_DIR/switchyard-wine",
  "arguments": ["wineboot.exe", "-u", "-r"],
  "environment": {
    "WINEPREFIX": "$PREFIX",
    "TEST_LIVE_DESCENDANT_PID_FILE": "$TEST_ROOT/bounded-prefix-descendant.pid",
    "TEST_LIVE_DESCENDANT_READY": "$TEST_ROOT/bounded-prefix-descendant.ready",
    "TEST_LIVE_DESCENDANT_RELEASE": "$TEST_ROOT/bounded-prefix-descendant.release"
  },
  "workingDirectory": "$PREFIX",
  "logSource": "bounded-prefix-output-test",
  "liveLogPath": "$BOUNDED_PREFIX_LIVE_LOG",
  "keepLoggingWhilePrefixIsActive": false
}
EOF

TEST_EVENTS="$EVENTS" TEST_PROBE_ACTIVE=1 SWITCHYARD_TEST_OUTPUT_DRAIN_TIMEOUT=0.1 \
  "$RUNNER" run --plan "$TEST_ROOT/bounded-prefix-output.json" >/dev/null 2>/dev/null &
bounded_prefix_runner_pid=$!
printf '%s\n' "$bounded_prefix_runner_pid" > "$TEST_ROOT/bounded-prefix-runner.pid"
for _ in {1..100}; do
  [ -s "$TEST_ROOT/bounded-prefix-descendant.ready" ] && break
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/bounded-prefix-descendant.ready" ]; then
  echo "bounded prefix output fixture did not start its descendant" >&2
  exit 1
fi
for _ in {1..100}; do
  if ! kill -0 "$bounded_prefix_runner_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
if kill -0 "$bounded_prefix_runner_pid" >/dev/null 2>&1; then
  echo "bounded prefix command followed the active Wine session indefinitely" >&2
  exit 1
fi
wait "$bounded_prefix_runner_pid"
touch "$TEST_ROOT/bounded-prefix-descendant.release"
rm -f "$TEST_ROOT/bounded-prefix-runner.pid"
if ! grep -q 'output drain timed out' "$BOUNDED_PREFIX_LIVE_LOG"; then
  echo "bounded prefix command did not report its intentionally truncated descendant output" >&2
  exit 1
fi

cat > "$TEST_ROOT/high-volume-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec 3< "$TEST_HIGH_VOLUME_ACK"
printf 'waiting\n' > "$TEST_HIGH_VOLUME_WAITING"
while [ ! -e "$TEST_HIGH_VOLUME_START" ]; do
  sleep 0.05
done
line_number=0
while [ "$line_number" -lt 12000 ]; do
  printf 'high-volume-output-%05d warning payload\n' "$line_number"
  IFS= read -r _ <&3
  line_number=$((line_number + 1))
done
printf 'high-volume-output-finished\n'
IFS= read -r _ <&3
printf 'ready\n' > "$TEST_HIGH_VOLUME_READY"
while [ ! -e "$TEST_HIGH_VOLUME_RELEASE" ]; do
  sleep 0.05
done
EOF
chmod +x "$TEST_ROOT/high-volume-output.sh"
HIGH_VOLUME_DEBUG_LOG="$TEST_ROOT/logs/high-volume.log"
cat > "$TEST_ROOT/high-volume-output.json" <<EOF
{
  "executable": "$TEST_ROOT/high-volume-output.sh",
  "arguments": [],
  "environment": {
    "TEST_HIGH_VOLUME_ACK": "$TEST_ROOT/high-volume-runner.ack",
    "TEST_HIGH_VOLUME_READY": "$TEST_ROOT/high-volume-output.ready",
    "TEST_HIGH_VOLUME_RELEASE": "$TEST_ROOT/high-volume-output.release",
    "TEST_HIGH_VOLUME_START": "$TEST_ROOT/high-volume-output.start",
    "TEST_HIGH_VOLUME_WAITING": "$TEST_ROOT/high-volume-output.waiting"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "high-volume-output-test",
  "debugLogPath": "$HIGH_VOLUME_DEBUG_LOG"
}
EOF

runner_footprint_kb() {
  local runner_pid="$1"
  local footprint_output
  local footprint_kb
  if ! footprint_output="$(footprint -p "$runner_pid" 2>&1)"; then
    echo "runner memory usage could not be inspected" >&2
    printf '%s\n' "$footprint_output" >&2
    return 1
  fi
  footprint_kb="$(
    printf '%s\n' "$footprint_output" \
      | awk '$4 == "Footprint:" {
          if ($6 == "MB") print int($5 * 1024)
          else if ($6 == "KB") print int($5)
          exit
        }'
  )"
  if [ -z "$footprint_kb" ]; then
    echo "runner memory usage could not be inspected" >&2
    printf '%s\n' "$footprint_output" >&2
    return 1
  fi
  printf '%s\n' "$footprint_kb"
}

mkfifo "$TEST_ROOT/high-volume-runner.out"
mkfifo "$TEST_ROOT/high-volume-runner.ack"
while IFS= read -r _; do
  printf 'continue\n' >&3
done <"$TEST_ROOT/high-volume-runner.out" 3>"$TEST_ROOT/high-volume-runner.ack" &
high_volume_drainer_pid=$!
printf '%s\n' "$high_volume_drainer_pid" > "$TEST_ROOT/high-volume-drainer.pid"
"$RUNNER" run --plan "$TEST_ROOT/high-volume-output.json" \
  >"$TEST_ROOT/high-volume-runner.out" 2>"$TEST_ROOT/high-volume-runner.err" &
high_volume_runner_pid=$!
printf '%s\n' "$high_volume_runner_pid" > "$TEST_ROOT/high-volume-runner.pid"
for _ in {1..200}; do
  [ -s "$TEST_ROOT/high-volume-output.waiting" ] && break
  if ! kill -0 "$high_volume_runner_pid" >/dev/null 2>&1; then
    echo "high-volume output runner exited before the baseline memory check" >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/high-volume-output.waiting" ]; then
  echo "high-volume output fixture did not reach its start gate" >&2
  exit 1
fi
high_volume_baseline_kb="$(runner_footprint_kb "$high_volume_runner_pid")"
touch "$TEST_ROOT/high-volume-output.start"
for _ in {1..600}; do
  if [ -s "$TEST_ROOT/high-volume-output.ready" ] \
    && grep -q 'high-volume-output-finished' "$HIGH_VOLUME_DEBUG_LOG"; then
    break
  fi
  if ! kill -0 "$high_volume_runner_pid" >/dev/null 2>&1; then
    set +e
    wait "$high_volume_runner_pid"
    high_volume_runner_status=$?
    set -e
    echo "high-volume output runner exited with status $high_volume_runner_status before the memory check" >&2
    tail -n 20 "$TEST_ROOT/high-volume-runner.err" >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$TEST_ROOT/high-volume-output.ready" ] \
  || ! grep -q 'high-volume-output-finished' "$HIGH_VOLUME_DEBUG_LOG"; then
  echo "high-volume output fixture did not finish streaming logs" >&2
  exit 1
fi
high_volume_footprint_kb="$(runner_footprint_kb "$high_volume_runner_pid")"
high_volume_growth_kb=$((high_volume_footprint_kb - high_volume_baseline_kb))
if [ "$high_volume_growth_kb" -gt 65536 ]; then
  echo "runner retained ${high_volume_growth_kb}KB while streaming high-volume output" >&2
  exit 1
fi
touch "$TEST_ROOT/high-volume-output.release"
wait "$high_volume_runner_pid"
wait "$high_volume_drainer_pid"
rm -f "$TEST_ROOT/high-volume-runner.pid"
rm -f "$TEST_ROOT/high-volume-drainer.pid"

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
for index in {1..10}; do
  printf '%d.000:0010:warn:d3d_perf:pending signal warning\n' "$index" >&2
done
printf '%s\n' "$$" > "$TEST_SIGNAL_PID_FILE"
while :; do
  sleep 1
done
EOF
chmod +x "$TEST_ROOT/signal-child.sh"
SIGNAL_LIVE_LOG="$TEST_ROOT/live/signal.jsonl"
cat > "$TEST_ROOT/signal.json" <<EOF
{
  "executable": "$TEST_ROOT/signal-child.sh",
  "arguments": [],
  "environment": {
    "TEST_SIGNAL_MARKER": "$TEST_ROOT/signal-child.terminated",
    "TEST_SIGNAL_PID_FILE": "$TEST_ROOT/signal-child.pid"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "signal-test",
  "liveLogPath": "$SIGNAL_LIVE_LOG",
  "forwardCapturedOutput": false
}
EOF

: > "$LIVE_ACTIVITY_LOCK"
chmod 600 "$LIVE_ACTIVITY_LOCK"
SWITCHYARD_TEST_SIGNAL_EXIT_TIMEOUT=0.1 \
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
for _ in {1..50}; do
  if [ "$(grep -c 'pending signal warning' "$SIGNAL_LIVE_LOG" 2>/dev/null || true)" -eq 10 ]; then
    break
  fi
  sleep 0.05
done
if [ "$(grep -c 'pending signal warning' "$SIGNAL_LIVE_LOG" 2>/dev/null || true)" -ne 10 ]; then
  echo "inactive runner did not durably batch logs before termination" >&2
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
if [ "$(grep -c 'pending signal warning' "$SIGNAL_LIVE_LOG")" -ne 10 ]; then
  echo "inactive runner lost durably batched logs during SIGTERM shutdown" >&2
  exit 1
fi
if grep -q '"occurrenceCount":' "$SIGNAL_LIVE_LOG"; then
  echo "inactive runner filtered logs during SIGTERM shutdown" >&2
  exit 1
fi
rm -f "$LIVE_ACTIVITY_LOCK"

echo "runner_prefix_session tests passed"
