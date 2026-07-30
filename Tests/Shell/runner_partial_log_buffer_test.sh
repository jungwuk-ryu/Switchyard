#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWIFT_BUILD_JOBS="${SWIFT_BUILD_JOBS:-$(($(sysctl -n hw.ncpu) - 1))}"
if [ "$SWIFT_BUILD_JOBS" -lt 1 ]; then
  SWIFT_BUILD_JOBS=1
fi

if [ -n "${SWITCHYARD_RUNNER:-}" ]; then
  RUNNER="$SWITCHYARD_RUNNER"
else
  (cd "$ROOT_DIR" && swift build --product switchyard-runner --jobs "$SWIFT_BUILD_JOBS" >/dev/null)
  BIN_PATH="$(cd "$ROOT_DIR" && swift build --show-bin-path)"
  RUNNER="$BIN_PATH/switchyard-runner"
fi

if [ ! -x "$RUNNER" ]; then
  echo "switchyard-runner is not executable: $RUNNER" >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d)"
RUNNER_PID=""

process_is_running() {
  local process_id="$1"
  local process_state
  process_state="$(ps -p "$process_id" -o stat= 2>/dev/null | tr -d '[:space:]')"
  [ -n "$process_state" ] && [ "${process_state#Z}" = "$process_state" ]
}

stop_and_wait() {
  local process_id="$1"
  if process_is_running "$process_id"; then
    kill -TERM "$process_id" >/dev/null 2>&1 || true
    for _ in {1..40}; do
      if ! process_is_running "$process_id"; then
        break
      fi
      sleep 0.05
    done
  fi
  if process_is_running "$process_id"; then
    kill -KILL "$process_id" >/dev/null 2>&1 || true
  fi
  wait "$process_id" >/dev/null 2>&1 || true
}

cleanup() {
  if [ -n "$RUNNER_PID" ]; then
    stop_and_wait "$RUNNER_PID"
  fi
  if [ -s "$TEST_ROOT/child.pid" ]; then
    fixture_child_pid="$(cat "$TEST_ROOT/child.pid")"
    if process_is_running "$fixture_child_pid"; then
      kill -TERM "$fixture_child_pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cat > "$TEST_ROOT/partial-output.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$$" > "$TEST_CHILD_PID_FILE"
printf 'exactcap\r\n'
printf 'splitcap\r'
sleep 0.05
printf '\n'
printf 'abcdefgh'
sleep 0.05
/usr/bin/perl -e 'print "x" x 262144'
printf 'discarded-suffix\r\nnormal\r\n'
printf '12345678'
sleep 0.05
printf 'finish-discarded-suffix'
EOF
chmod +x "$TEST_ROOT/partial-output.sh"

DEBUG_LOG="$TEST_ROOT/logs/partial.log"
cat > "$TEST_ROOT/plan.json" <<EOF
{
  "executable": "$TEST_ROOT/partial-output.sh",
  "arguments": [],
  "environment": {
    "TEST_CHILD_PID_FILE": "$TEST_ROOT/child.pid"
  },
  "workingDirectory": "$TEST_ROOT",
  "logSource": "partial-log-test",
  "debugLogPath": "$DEBUG_LOG",
  "forwardCapturedOutput": false
}
EOF

SWITCHYARD_TEST_PARTIAL_LOG_MAX_BYTES=8 \
  "$RUNNER" run --plan "$TEST_ROOT/plan.json" \
  >"$TEST_ROOT/runner.stdout" 2>"$TEST_ROOT/runner.stderr" &
RUNNER_PID=$!

for _ in {1..200}; do
  if ! process_is_running "$RUNNER_PID"; then
    break
  fi
  sleep 0.05
done

if process_is_running "$RUNNER_PID"; then
  echo "runner partial-log fixture exceeded its 10 second timeout" >&2
  stop_and_wait "$RUNNER_PID"
  RUNNER_PID=""
  exit 1
fi

if wait "$RUNNER_PID"; then
  runner_status=0
else
  runner_status=$?
fi
RUNNER_PID=""
if [ "$runner_status" -ne 0 ]; then
  echo "runner partial-log fixture exited with status $runner_status" >&2
  cat "$TEST_ROOT/runner.stderr" >&2
  exit 1
fi

if [ ! -s "$TEST_ROOT/child.pid" ]; then
  echo "runner partial-log fixture did not record its child process" >&2
  exit 1
fi
fixture_child_pid="$(cat "$TEST_ROOT/child.pid")"
if process_is_running "$fixture_child_pid"; then
  echo "runner left the partial-log fixture child running" >&2
  exit 1
fi

marker=' … [truncated after 8 bytes; remainder discarded until newline]'
if ! grep -Fq '[partial-log-test] [info] exactcap' "$DEBUG_LOG"; then
  echo "runner counted a CRLF delimiter against an exact-cap line" >&2
  exit 1
fi
if ! grep -Fq '[partial-log-test] [info] splitcap' "$DEBUG_LOG"; then
  echo "runner counted a split CRLF delimiter against an exact-cap line" >&2
  exit 1
fi
if ! grep -Fq "[partial-log-test] [info] abcdefgh$marker" "$DEBUG_LOG"; then
  echo "runner did not retain and mark the byte-capped first prefix" >&2
  exit 1
fi
if ! grep -Fq "[partial-log-test] [info] 12345678$marker" "$DEBUG_LOG"; then
  echo "runner did not mark the unterminated line before process exit" >&2
  exit 1
fi
if [ "$(grep -Fc 'remainder discarded until newline' "$DEBUG_LOG")" -ne 2 ]; then
  echo "runner emitted an unexpected number of truncation records" >&2
  grep -F 'remainder discarded until newline' "$DEBUG_LOG" >&2 || true
  exit 1
fi
if grep -Fq 'discarded-suffix' "$DEBUG_LOG"; then
  echo "runner emitted a discarded oversized-line suffix" >&2
  exit 1
fi
if ! grep -Fq '[partial-log-test] [info] normal' "$DEBUG_LOG"; then
  echo "runner did not recover after the oversized CRLF record" >&2
  exit 1
fi

echo "runner partial log buffer tests passed"
