#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
(cd "$ROOT_DIR" && swift build >/dev/null)
BIN_PATH="$(cd "$ROOT_DIR" && swift build --show-bin-path)"
RUNNER="$BIN_PATH/switchyard-runner"
TEST_ROOT="$(mktemp -d)"
BIN_DIR="$TEST_ROOT/runtime/bin"
PREFIX="$TEST_ROOT/Test.container"
EVENTS="$TEST_ROOT/events.log"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR" "$PREFIX"
cat > "$BIN_DIR/wineserver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'wineserver %s prefix=%s\n' "$*" "$WINEPREFIX" >> "$TEST_EVENTS"
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
EOF
chmod +x "$BIN_DIR/wineserver" "$BIN_DIR/switchyard-wine"

TEST_EVENTS="$EVENTS" TEST_PROBE_ACTIVE=1 "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"
if TEST_EVENTS="$EVENTS" "$RUNNER" probe-prefix --wine "$BIN_DIR/switchyard-wine" --prefix "$PREFIX"; then
  echo "probe should report an inactive prefix with status 1" >&2
  exit 1
elif [ "$?" -ne 1 ]; then
  echo "inactive prefix probe returned an unexpected status" >&2
  exit 1
fi
if TEST_EVENTS="$EVENTS" "$RUNNER" probe-prefix --wine "$TEST_ROOT/custom-wine" --prefix "$PREFIX"; then
  echo "probe should report an unsupported Wine layout" >&2
  exit 1
elif [ "$?" -ne 2 ]; then
  echo "unsupported Wine layout probe returned an unexpected status" >&2
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
perl -0pe 's/,\n  "terminateExistingPrefixSession": true//' "$TEST_ROOT/replace.json" > "$TEST_ROOT/reuse.json"
TEST_EVENTS="$EVENTS" "$RUNNER" run --plan "$TEST_ROOT/reuse.json" >/dev/null
if [ "$(sed -n '1p' "$EVENTS")" != "wine C:\\Program Files\\Steam\\steam.exe prefix=$PREFIX" ]; then
  echo "legacy command plans should launch without terminating the prefix session" >&2
  exit 1
fi

echo "runner_prefix_session tests passed"
