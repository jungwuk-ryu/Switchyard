#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER_PATH="${SWITCHYARD_RUNNER_PATH:-$ROOT_DIR/.build/debug/switchyard-runner}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-process-identity.XXXXXX")"
PREFIX_PATH="$TEST_ROOT/Selected.container"
OTHER_PREFIX_PATH="$TEST_ROOT/Other.container"
SELECTED_PID=""
EMPTY_PREFIX_PID=""
CONFLICT_PID=""
SENTINEL_PID=""
WATCHDOG_PID=""
TEST_TIMED_OUT=0

stop_and_wait() {
  process_id="$1"
  if [ -z "$process_id" ]; then
    return
  fi
  if kill -0 "$process_id" >/dev/null 2>&1; then
    kill -TERM "$process_id" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$process_id" >/dev/null 2>&1; then
        break
      fi
      sleep 0.025
    done
  fi
  if kill -0 "$process_id" >/dev/null 2>&1; then
    kill -KILL "$process_id" >/dev/null 2>&1 || true
  fi
  wait "$process_id" >/dev/null 2>&1 || true
}

cleanup() {
  trap - EXIT ALRM
  if [ -n "$WATCHDOG_PID" ]; then
    kill -TERM "$WATCHDOG_PID" >/dev/null 2>&1 || true
    wait "$WATCHDOG_PID" >/dev/null 2>&1 || true
    WATCHDOG_PID=""
  fi
  stop_and_wait "$SELECTED_PID"
  stop_and_wait "$EMPTY_PREFIX_PID"
  stop_and_wait "$CONFLICT_PID"
  stop_and_wait "$SENTINEL_PID"
  rm -rf "$TEST_ROOT"
}

timed_out() {
  TEST_TIMED_OUT=1
  echo "runner process identity test exceeded its 30-second deadline" >&2
  exit 124
}

trap cleanup EXIT
trap timed_out ALRM
(
  sleep 30
  kill -ALRM "$$"
) &
WATCHDOG_PID="$!"

mkdir -p "$PREFIX_PATH" "$OTHER_PREFIX_PATH" "$TEST_ROOT/host" "$TEST_ROOT/guest"
cc -Os \
  "$ROOT_DIR/Tests/Shell/Fixtures/prefix_wine_process.c" \
  -o "$TEST_ROOT/host/wine"

cat >"$TEST_ROOT/host/wineserver" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SWITCHYARD_TEST_WINESERVER_EVENTS"
if [ "${1:-}" = "-k" ]; then
  exit 1
fi
SCRIPT
chmod +x "$TEST_ROOT/host/wineserver"

env -u WINEPREFIX \
  "$TEST_ROOT/host/wine" \
  "$PREFIX_PATH" \
  "$TEST_ROOT/selected.ready" \
  ignore-term &
SELECTED_PID="$!"
WINEPREFIX="" \
  "$TEST_ROOT/host/wine" \
  "$PREFIX_PATH" \
  "$TEST_ROOT/empty-prefix.ready" \
  default &
EMPTY_PREFIX_PID="$!"
WINEPREFIX="$OTHER_PREFIX_PATH" \
  "$TEST_ROOT/host/wine" \
  "$PREFIX_PATH" \
  "$TEST_ROOT/conflict.ready" \
  default &
CONFLICT_PID="$!"
WINEPREFIX="$OTHER_PREFIX_PATH" \
  "$TEST_ROOT/host/wine" \
  "$OTHER_PREFIX_PATH" \
  "$TEST_ROOT/sentinel.ready" \
  default &
SENTINEL_PID="$!"

for _ in $(seq 1 100); do
  if [ -s "$TEST_ROOT/selected.ready" ] \
    && [ -s "$TEST_ROOT/empty-prefix.ready" ] \
    && [ -s "$TEST_ROOT/conflict.ready" ] \
    && [ -s "$TEST_ROOT/sentinel.ready" ]; then
    break
  fi
  sleep 0.025
done
test -s "$TEST_ROOT/selected.ready"
test -s "$TEST_ROOT/empty-prefix.ready"
test -s "$TEST_ROOT/conflict.ready"
test -s "$TEST_ROOT/sentinel.ready"

host_processes="$(
  "$RUNNER_PATH" list-host-processes \
    --wine "$TEST_ROOT/host/wine" \
    --prefix "$PREFIX_PATH"
)"
expected_host_processes="$(
  printf '%s\n%s\n' "$SELECTED_PID" "$EMPTY_PREFIX_PID" \
    | sort -n \
    | paste -sd, -
)"
test "$host_processes" = "[$expected_host_processes]"

for table_status in failed incomplete; do
  set +e
  SWITCHYARD_TEST_PROCESS_TABLE_STATUS="$table_status" \
    "$RUNNER_PATH" list-host-processes \
      --wine "$TEST_ROOT/host/wine" \
      --prefix "$PREFIX_PATH" \
      >"$TEST_ROOT/$table_status.out" \
      2>"$TEST_ROOT/$table_status.err"
  command_status="$?"
  set -e
  test "$command_status" -ne 0
done

: >"$TEST_ROOT/wineserver.events"
set +e
SWITCHYARD_TEST_PROCESS_TABLE_STATUS=incomplete \
SWITCHYARD_TEST_WINESERVER_EVENTS="$TEST_ROOT/wineserver.events" \
  "$RUNNER_PATH" stop-prefix \
    --wine "$TEST_ROOT/host/wine" \
    --prefix "$PREFIX_PATH" \
    >"$TEST_ROOT/incomplete-stop.out" \
    2>"$TEST_ROOT/incomplete-stop.err"
incomplete_stop_status="$?"
set -e
test "$incomplete_stop_status" -ne 0
test ! -s "$TEST_ROOT/wineserver.events"
kill -0 "$SELECTED_PID"
kill -0 "$EMPTY_PREFIX_PID"
kill -0 "$CONFLICT_PID"
kill -0 "$SENTINEL_PID"

SWITCHYARD_TEST_PREFIX_PROCESS_TIMEOUT=0.1 \
SWITCHYARD_TEST_WINESERVER_EVENTS="$TEST_ROOT/wineserver.events" \
  "$RUNNER_PATH" stop-prefix \
    --wine "$TEST_ROOT/host/wine" \
    --prefix "$PREFIX_PATH"
set +e
wait "$SELECTED_PID" >/dev/null 2>&1
selected_status="$?"
set -e
SELECTED_PID=""
test "$selected_status" -eq 137
set +e
wait "$EMPTY_PREFIX_PID" >/dev/null 2>&1
empty_prefix_status="$?"
set -e
EMPTY_PREFIX_PID=""
test "$empty_prefix_status" -eq 143
kill -0 "$CONFLICT_PID"
kill -0 "$SENTINEL_PID"

cat >"$TEST_ROOT/guest/wine" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "wmic" ] \
  && [ "${4:-}" = "CreationDate,ExecutablePath,ProcessId" ]; then
  if [ "${SWITCHYARD_TEST_CREATION_UNSUPPORTED:-0}" = "1" ]; then
    exit 1
  fi
  if [ "${SWITCHYARD_TEST_STRONG_OMITS_TARGET:-0}" = "1" ]; then
    printf '%s\n' \
      'CreationDate  ExecutablePath  ProcessId' \
      '20260731060001.000000+540  C:\Program Files (x86)\Steam\steam.exe  144'
    exit 0
  fi
  count=0
  if [ -s "$SWITCHYARD_TEST_QUERY_COUNT" ]; then
    count="$(cat "$SWITCHYARD_TEST_QUERY_COUNT")"
  fi
  count="$((count + 1))"
  printf '%s\n' "$count" >"$SWITCHYARD_TEST_QUERY_COUNT"
  creation_date='20260731060002.000000+540'
  if [ "${SWITCHYARD_TEST_REUSE_GUEST_PID:-0}" = "1" ] && [ "$count" -gt 1 ]; then
    creation_date='20260731060003.000000+540'
  fi
  printf '%s\n' \
    'CreationDate  ExecutablePath  ProcessId' \
    "$creation_date  C:\\Games\\Heartopia\\xdt.exe  232"
  exit 0
fi
if [ "${1:-}" = "wmic" ] \
  && [ "${4:-}" = "ExecutablePath,ProcessId" ]; then
  printf '%s\n' \
    'ExecutablePath  ProcessId' \
    'C:\Games\Heartopia\xdt.exe  232'
  exit 0
fi
if [ "${1:-}" = "taskkill" ]; then
  printf '%s\n' "$*" >>"$SWITCHYARD_TEST_TASKKILL_EVENTS"
  exit 0
fi
exit 2
SCRIPT
chmod +x "$TEST_ROOT/guest/wine"

: >"$TEST_ROOT/query.count"
: >"$TEST_ROOT/taskkill.events"
set +e
SWITCHYARD_TEST_QUERY_COUNT="$TEST_ROOT/query.count" \
SWITCHYARD_TEST_TASKKILL_EVENTS="$TEST_ROOT/taskkill.events" \
SWITCHYARD_TEST_REUSE_GUEST_PID=1 \
  "$RUNNER_PATH" terminate-process \
    --wine "$TEST_ROOT/guest/wine" \
    --prefix "$PREFIX_PATH" \
    --pid 232 \
    >"$TEST_ROOT/reused-guest.out" \
    2>"$TEST_ROOT/reused-guest.err"
reused_guest_status="$?"
set -e
test "$reused_guest_status" -ne 0
test ! -s "$TEST_ROOT/taskkill.events"

: >"$TEST_ROOT/query.count"
set +e
SWITCHYARD_TEST_QUERY_COUNT="$TEST_ROOT/query.count" \
SWITCHYARD_TEST_TASKKILL_EVENTS="$TEST_ROOT/taskkill.events" \
SWITCHYARD_TEST_STRONG_OMITS_TARGET=1 \
  "$RUNNER_PATH" terminate-process \
    --wine "$TEST_ROOT/guest/wine" \
    --prefix "$PREFIX_PATH" \
    --pid 232 \
    >"$TEST_ROOT/missing-strong-target.out" \
    2>"$TEST_ROOT/missing-strong-target.err"
missing_strong_target_status="$?"
set -e
test "$missing_strong_target_status" -ne 0
test ! -s "$TEST_ROOT/taskkill.events"

: >"$TEST_ROOT/query.count"
SWITCHYARD_TEST_QUERY_COUNT="$TEST_ROOT/query.count" \
SWITCHYARD_TEST_TASKKILL_EVENTS="$TEST_ROOT/taskkill.events" \
  "$RUNNER_PATH" terminate-process \
    --wine "$TEST_ROOT/guest/wine" \
    --prefix "$PREFIX_PATH" \
    --pid 232
test "$(cat "$TEST_ROOT/taskkill.events")" = "taskkill /PID 232 /F"

: >"$TEST_ROOT/taskkill.events"
SWITCHYARD_TEST_QUERY_COUNT="$TEST_ROOT/query.count" \
SWITCHYARD_TEST_TASKKILL_EVENTS="$TEST_ROOT/taskkill.events" \
SWITCHYARD_TEST_CREATION_UNSUPPORTED=1 \
  "$RUNNER_PATH" terminate-process \
    --wine "$TEST_ROOT/guest/wine" \
    --prefix "$PREFIX_PATH" \
    --pid 232
test "$(cat "$TEST_ROOT/taskkill.events")" = "taskkill /PID 232 /F"

stop_and_wait "$CONFLICT_PID"
CONFLICT_PID=""
stop_and_wait "$SENTINEL_PID"
SENTINEL_PID=""

kill -TERM "$WATCHDOG_PID" >/dev/null 2>&1 || true
wait "$WATCHDOG_PID" >/dev/null 2>&1 || true
WATCHDOG_PID=""
test "$TEST_TIMED_OUT" -eq 0
