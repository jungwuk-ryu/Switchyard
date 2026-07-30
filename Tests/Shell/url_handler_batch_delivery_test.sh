#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HANDLER_PATH="${SWITCHYARD_URL_HANDLER_PATH:-$ROOT_DIR/.build/debug/switchyard-url-handler}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-url-handler-batch.XXXXXX")"
BRIDGE_ROOT="$TEST_ROOT/ProtocolBridge"
PREFIX_PATH="$TEST_ROOT/Test.container"
FAKE_WINE="$TEST_ROOT/fake-wine"
FAKE_RUNNER="$TEST_ROOT/fake-runner"
EVENTS_PATH="$TEST_ROOT/events.json"
DELIVERY_LOG="$TEST_ROOT/deliveries.log"
RUNNER_PID_PATH="$TEST_ROOT/fake-runner.pid"
SECOND_EVENT_MARKER="$TEST_ROOT/second-event.marker"
STDERR_PATH="$TEST_ROOT/handler.stderr"
HANDLER_PID=""

wait_for_exit() {
  local pid="$1"
  local attempts="${2:-100}"
  for _ in $(seq 1 "$attempts"); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

cleanup() {
  if [ -n "$HANDLER_PID" ]; then
    if kill -0 "$HANDLER_PID" >/dev/null 2>&1; then
      kill -TERM "$HANDLER_PID" >/dev/null 2>&1 || true
      if ! wait_for_exit "$HANDLER_PID" 40; then
        kill -KILL "$HANDLER_PID" >/dev/null 2>&1 || true
      fi
    fi
    wait "$HANDLER_PID" >/dev/null 2>&1 || true
  fi

  if [ -f "$RUNNER_PID_PATH" ]; then
    runner_pid="$(tr -cd '0-9' <"$RUNNER_PID_PATH")"
    runner_command="$(ps -p "$runner_pid" -o command= 2>/dev/null || true)"
    if [ -n "$runner_pid" ] \
      && [[ "$runner_command" == *"$FAKE_RUNNER"* ]] \
      && kill -0 "$runner_pid" >/dev/null 2>&1; then
      kill -TERM "$runner_pid" >/dev/null 2>&1 || true
      if ! wait_for_exit "$runner_pid" 40; then
        kill -KILL "$runner_pid" >/dev/null 2>&1 || true
        wait_for_exit "$runner_pid" 40 || true
      fi
    fi
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$BRIDGE_ROOT" "$PREFIX_PATH"

cat >"$FAKE_WINE" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "$FAKE_WINE"

cat >"$FAKE_RUNNER" <<'RUBY'
#!/usr/bin/ruby
require "json"

pid_path = ENV.fetch("SWITCHYARD_TEST_FAKE_RUNNER_PID_PATH")
delivery_log = ENV.fetch("SWITCHYARD_TEST_DELIVERY_LOG")
File.write(pid_path, "#{Process.pid}\n", mode: "w", perm: 0o600)

begin
  unless ARGV.length == 3 && ARGV[0] == "open-url" && ARGV[1] == "--request"
    warn "unexpected fake runner arguments: #{ARGV.inspect}"
    exit 64
  end

  raw_url = JSON.parse(File.binread(ARGV[2])).fetch("rawURL")
  File.open(delivery_log, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
    file.puts(raw_url)
  end

  # Keep the first callback active while the harness injects its second event.
  if raw_url.include?("sequence=1")
    marker_path = ENV.fetch("SWITCHYARD_TEST_SECOND_EVENT_MARKER")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
    until File.file?(marker_path)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        warn "the second URL event did not run while the first delivery was active"
        exit 70
      end
      sleep 0.005
    end
  end
  exit 23 if raw_url.include?("sequence=2")
  sleep 10 if raw_url.include?("sequence=timeout")
ensure
  if File.file?(pid_path) && File.read(pid_path).strip == Process.pid.to_s
    File.delete(pid_path)
  end
end
RUBY
chmod +x "$FAKE_RUNNER"

cat >"$BRIDGE_ROOT/routes-v1.json" <<JSON
{
  "version": 1,
  "routes": [
    {
      "scheme": "xdt",
      "containerID": "5C2026B5-8AC2-4C27-8340-A44D0AFE96F2",
      "prefixPath": "$PREFIX_PATH",
      "winePath": "$FAKE_WINE",
      "runnerPath": "$FAKE_RUNNER",
      "lastActivatedAt": 1
    }
  ]
}
JSON

cat >"$EVENTS_PATH" <<JSON
[
  {
    "delayMilliseconds": 0,
    "urls": [
      "xdt://callback?sequence=1",
      "xdt://callback?sequence=2"
    ]
  },
  {
    "delayMilliseconds": 20,
    "markerPath": "$SECOND_EVENT_MARKER",
    "urls": [
      "xdt://callback?sequence=3",
      "xdt://callback?sequence=4"
    ]
  }
]
JSON

SWITCHYARD_TEST_BRIDGE_ROOT="$BRIDGE_ROOT" \
SWITCHYARD_TEST_DELIVERY_LOG="$DELIVERY_LOG" \
SWITCHYARD_TEST_FAKE_RUNNER_PID_PATH="$RUNNER_PID_PATH" \
SWITCHYARD_TEST_SECOND_EVENT_MARKER="$SECOND_EVENT_MARKER" \
  "$HANDLER_PATH" --test-deliver-url-events "$EVENTS_PATH" \
  2>"$STDERR_PATH" &
HANDLER_PID="$!"

if ! wait_for_exit "$HANDLER_PID" 200; then
  echo "URL handler batch delivery exceeded its 10-second test deadline" >&2
  exit 1
fi

set +e
wait "$HANDLER_PID"
handler_status="$?"
set -e
HANDLER_PID=""
test "$handler_status" -eq 0

diff -u \
  <(printf '%s\n' \
    'xdt://callback?sequence=1' \
    'xdt://callback?sequence=2' \
    'xdt://callback?sequence=3' \
    'xdt://callback?sequence=4') \
  "$DELIVERY_LOG"

grep -Fq "status 23" "$STDERR_PATH"
if grep -Fq "status 70" "$STDERR_PATH"; then
  echo "URL handler blocked the main loop during callback delivery" >&2
  exit 1
fi
test -d "$BRIDGE_ROOT/Requests"
test -z "$(find "$BRIDGE_ROOT/Requests" -mindepth 1 -maxdepth 1 -print -quit)"
test ! -e "$RUNNER_PID_PATH"

cat >"$EVENTS_PATH" <<'JSON'
[
  {
    "delayMilliseconds": 0,
    "urls": [
      "xdt://callback?sequence=timeout"
    ]
  }
]
JSON
: >"$STDERR_PATH"

SWITCHYARD_TEST_BRIDGE_ROOT="$BRIDGE_ROOT" \
SWITCHYARD_TEST_DELIVERY_LOG="$DELIVERY_LOG" \
SWITCHYARD_TEST_FAKE_RUNNER_PID_PATH="$RUNNER_PID_PATH" \
SWITCHYARD_TEST_SECOND_EVENT_MARKER="$SECOND_EVENT_MARKER" \
SWITCHYARD_TEST_HANDLER_RUNNER_TIMEOUT=0.10 \
  "$HANDLER_PATH" --test-deliver-url-events "$EVENTS_PATH" \
  2>"$STDERR_PATH" &
HANDLER_PID="$!"

if ! wait_for_exit "$HANDLER_PID" 100; then
  echo "URL handler did not stop its timed-out fake runner" >&2
  exit 1
fi

set +e
wait "$HANDLER_PID"
handler_status="$?"
set -e
HANDLER_PID=""
test "$handler_status" -eq 0
grep -Fq "did not finish" "$STDERR_PATH"
test -z "$(find "$BRIDGE_ROOT/Requests" -mindepth 1 -maxdepth 1 -print -quit)"
test ! -e "$RUNNER_PID_PATH"
