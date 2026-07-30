#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPCAST_GENERATOR="$ROOT_DIR/script/generate_appcast.sh"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/switchyard-appcast-test.XXXXXX")"
TEST_ROOT="$(cd -P "$TEST_ROOT" && pwd -P)"
ACTIVE_COMMAND_PID=""

exact_child_state() {
  local child_pid="$1"
  /bin/ps -o state= -p "$child_pid" 2>/dev/null |
    /usr/bin/tr -d '[:space:]' |
    /usr/bin/cut -c 1
}

terminate_and_reap_exact_child() {
  local child_pid="$1"
  local state=""
  local grace_tick
  [ -n "$child_pid" ] || return 0

  state="$(exact_child_state "$child_pid")"
  if [ -n "$state" ] && [ "$state" != "Z" ]; then
    /bin/kill -TERM "$child_pid" 2>/dev/null || true
    for ((grace_tick = 0; grace_tick < 10; grace_tick += 1)); do
      state="$(exact_child_state "$child_pid")"
      [ -n "$state" ] && [ "$state" != "Z" ] || break
      /bin/sleep 0.05
    done
  fi

  state="$(exact_child_state "$child_pid")"
  if [ -n "$state" ] && [ "$state" != "Z" ]; then
    /bin/kill -KILL "$child_pid" 2>/dev/null || true
    for ((grace_tick = 0; grace_tick < 20; grace_tick += 1)); do
      state="$(exact_child_state "$child_pid")"
      [ -n "$state" ] && [ "$state" != "Z" ] || break
      /bin/sleep 0.05
    done
  fi

  state="$(exact_child_state "$child_pid")"
  if [ -n "$state" ] && [ "$state" != "Z" ]; then
    echo "timed out reaping exact child PID $child_pid" >&2
    return 1
  fi
  wait "$child_pid" 2>/dev/null || true
}

cleanup() {
  if [ -n "$ACTIVE_COMMAND_PID" ]; then
    terminate_and_reap_exact_child "$ACTIVE_COMMAND_PID" || true
    ACTIVE_COMMAND_PID=""
  fi
  /bin/rm -rf "$TEST_ROOT"
}

handle_signal() {
  local status="$1"
  cleanup
  trap - EXIT
  exit "$status"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

run_with_deadline() {
  local command_status
  local deadline_ticks="${APPCAST_TEST_DEADLINE_TICKS:-200}"
  local elapsed_tick
  local state
  case "$deadline_ticks" in
    ""|*[!0-9]*) deadline_ticks=200 ;;
  esac
  exec 9<&0
  "$@" <&9 &
  ACTIVE_COMMAND_PID=$!
  exec 9<&-

  for ((elapsed_tick = 0; elapsed_tick < deadline_ticks; elapsed_tick += 1)); do
    state="$(exact_child_state "$ACTIVE_COMMAND_PID")"
    if [ -z "$state" ] || [ "$state" = "Z" ]; then
      if wait "$ACTIVE_COMMAND_PID"; then
        command_status=0
      else
        command_status=$?
      fi
      ACTIVE_COMMAND_PID=""
      return "$command_status"
    fi
    /bin/sleep 0.05
  done

  terminate_and_reap_exact_child "$ACTIVE_COMMAND_PID" || true
  ACTIVE_COMMAND_PID=""
  return 124
}

make_fixture() {
  local fixture_root="$1"
  local sparkle_version sparkle_revision artifact_root
  artifact_root="$fixture_root/.build/artifacts/sparkle/Sparkle"
  /bin/mkdir -p \
    "$fixture_root/script" \
    "$artifact_root/bin" \
    "$artifact_root/Sparkle.xcframework" \
    "$fixture_root/output"
  /bin/cp "$APPCAST_GENERATOR" "$fixture_root/script/generate_appcast.sh"
  /bin/cp "$ROOT_DIR/Package.resolved" "$fixture_root/Package.resolved"

  sparkle_version="$(
    /usr/bin/plutil -extract pins.0.state.version raw -o - "$fixture_root/Package.resolved"
  )"
  sparkle_revision="$(
    /usr/bin/plutil -extract pins.0.state.revision raw -o - "$fixture_root/Package.resolved"
  )"

  /bin/cp "$ROOT_DIR/Tests/Shell/Fixtures/fake_generate_appcast.sh" \
    "$artifact_root/bin/generate_appcast"
  /bin/chmod 755 "$artifact_root/bin/generate_appcast"

  /usr/bin/printf '%s\n' \
    '{' \
    '  "object": {' \
    '    "artifacts": [' \
    '      {' \
    '        "kind": {"xcframework": {}},' \
    '        "packageRef": {' \
    '          "identity": "sparkle",' \
    '          "kind": "remoteSourceControl",' \
    '          "location": "https://github.com/sparkle-project/Sparkle",' \
    '          "name": "Sparkle"' \
    '        },' \
    "        \"path\": \"$artifact_root/Sparkle.xcframework\"," \
    '        "source": {' \
    '          "checksum": "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0",' \
    '          "type": "remote",' \
    "          \"url\": \"https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-for-Swift-Package-Manager.zip\"" \
    '        },' \
    '        "targetName": "Sparkle"' \
    '      }' \
    '    ],' \
    '    "dependencies": [' \
    '      {' \
    '        "basedOn": null,' \
    '        "packageRef": {' \
    '          "identity": "sparkle",' \
    '          "kind": "remoteSourceControl",' \
    '          "location": "https://github.com/sparkle-project/Sparkle",' \
    '          "name": "Sparkle"' \
    '        },' \
    '        "state": {' \
    '          "checkoutState": {' \
    "            \"revision\": \"$sparkle_revision\"," \
    "            \"version\": \"$sparkle_version\"" \
    '          },' \
    '          "name": "sourceControlCheckout"' \
    '        },' \
    '        "subpath": "Sparkle"' \
    '      }' \
    '    ],' \
    '    "prebuilts": []' \
    '  },' \
    '  "version": 7' \
    '}' > "$fixture_root/.build/workspace-state.json"
  /usr/bin/printf 'fake dmg\n' > "$fixture_root/Switchyard.dmg"
}

invoke_generator() {
  local fixture_root="$1"
  local output_name="$2"
  local command_status
  shift 2
  FAKE_APPCAST_MARKER="$fixture_root/tool-invoked"
  SPARKLE_ED_PRIVATE_KEY="fixture-private-key"
  export FAKE_APPCAST_MARKER SPARKLE_ED_PRIVATE_KEY
  if run_with_deadline \
    "$fixture_root/script/generate_appcast.sh" \
    --dmg "$fixture_root/Switchyard.dmg" \
    --output "$fixture_root/output/$output_name" \
    --download-url-prefix "https://example.test/releases/v99.0.0/" \
    "$@" <<< 'fixture-private-key'; then
    command_status=0
  else
    command_status=$?
  fi
  unset FAKE_APPCAST_MARKER SPARKLE_ED_PRIVATE_KEY
  return "$command_status"
}

expect_failure() {
  local fixture_root="$1"
  local expected_error="$2"
  shift 2
  if invoke_generator "$fixture_root" rejected.xml "$@" \
    > "$fixture_root/stdout" 2> "$fixture_root/stderr"; then
    echo "expected appcast generation to fail: $expected_error" >&2
    exit 1
  fi
  /usr/bin/grep -Fq "$expected_error" "$fixture_root/stderr"
  [ ! -e "$fixture_root/tool-invoked" ] || {
    echo "rejected appcast tool was executed" >&2
    exit 1
  }
}

SUCCESS_FIXTURE="$TEST_ROOT/success"
make_fixture "$SUCCESS_FIXTURE"
invoke_generator "$SUCCESS_FIXTURE" appcast.xml
[ -f "$SUCCESS_FIXTURE/output/appcast.xml" ]
[ -f "$SUCCESS_FIXTURE/tool-invoked" ]
/usr/bin/xmllint --noout "$SUCCESS_FIXTURE/output/appcast.xml"

AMBIGUOUS_FIXTURE="$TEST_ROOT/ambiguous"
make_fixture "$AMBIGUOUS_FIXTURE"
/bin/mkdir -p "$AMBIGUOUS_FIXTURE/.build/artifacts/aaa/bin"
/bin/cp "$ROOT_DIR/Tests/Shell/Fixtures/fake_generate_appcast.sh" \
  "$AMBIGUOUS_FIXTURE/.build/artifacts/aaa/bin/generate_appcast"
/bin/chmod 755 "$AMBIGUOUS_FIXTURE/.build/artifacts/aaa/bin/generate_appcast"
expect_failure \
  "$AMBIGUOUS_FIXTURE" \
  "Sparkle artifact tree contains an ambiguous generate_appcast tool"

SYMLINK_FIXTURE="$TEST_ROOT/symlink"
make_fixture "$SYMLINK_FIXTURE"
/bin/mv \
  "$SYMLINK_FIXTURE/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  "$SYMLINK_FIXTURE/fake-tool"
/bin/ln -s \
  "$SYMLINK_FIXTURE/fake-tool" \
  "$SYMLINK_FIXTURE/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
expect_failure "$SYMLINK_FIXTURE" "untrusted Sparkle artifact file"

NONREGULAR_FIXTURE="$TEST_ROOT/nonregular"
make_fixture "$NONREGULAR_FIXTURE"
/bin/rm "$NONREGULAR_FIXTURE/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
/bin/mkdir "$NONREGULAR_FIXTURE/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
expect_failure "$NONREGULAR_FIXTURE" "untrusted Sparkle artifact file"

WRITABLE_FIXTURE="$TEST_ROOT/writable"
make_fixture "$WRITABLE_FIXTURE"
/bin/chmod 777 "$WRITABLE_FIXTURE/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
expect_failure "$WRITABLE_FIXTURE" "untrusted Sparkle artifact file"

OVERRIDE_FIXTURE="$TEST_ROOT/override"
make_fixture "$OVERRIDE_FIXTURE"
/bin/cp "$ROOT_DIR/Tests/Shell/Fixtures/fake_generate_appcast.sh" \
  "$OVERRIDE_FIXTURE/attacker-controlled-tool"
/bin/chmod 755 "$OVERRIDE_FIXTURE/attacker-controlled-tool"
expect_failure \
  "$OVERRIDE_FIXTURE" \
  "only the resolved SwiftPM generate_appcast tool is allowed" \
  --tool "$OVERRIDE_FIXTURE/attacker-controlled-tool"

STALE_STATE_FIXTURE="$TEST_ROOT/stale-state"
make_fixture "$STALE_STATE_FIXTURE"
/usr/bin/plutil \
  -replace object.dependencies.0.state.checkoutState.revision \
  -string 0000000000000000000000000000000000000000 \
  "$STALE_STATE_FIXTURE/.build/workspace-state.json"
expect_failure \
  "$STALE_STATE_FIXTURE" \
  "SwiftPM Sparkle dependency does not match Package.resolved"

TERM_IGNORE_PID_FILE="$TEST_ROOT/term-ignore.pid"
FAKE_GENERATE_APPCAST_IGNORE_TERM_AND_HANG=1
FAKE_GENERATE_APPCAST_PID_FILE="$TERM_IGNORE_PID_FILE"
APPCAST_TEST_DEADLINE_TICKS=2
export \
  FAKE_GENERATE_APPCAST_IGNORE_TERM_AND_HANG \
  FAKE_GENERATE_APPCAST_PID_FILE \
  APPCAST_TEST_DEADLINE_TICKS
if run_with_deadline "$ROOT_DIR/Tests/Shell/Fixtures/fake_generate_appcast.sh"; then
  echo "TERM-ignoring fixture unexpectedly completed" >&2
  exit 1
else
  timeout_status=$?
fi
unset \
  FAKE_GENERATE_APPCAST_IGNORE_TERM_AND_HANG \
  FAKE_GENERATE_APPCAST_PID_FILE \
  APPCAST_TEST_DEADLINE_TICKS
[ "$timeout_status" -eq 124 ] || {
  echo "TERM-ignoring fixture did not report a deadline" >&2
  exit 1
}
[ -s "$TERM_IGNORE_PID_FILE" ] || {
  echo "TERM-ignoring fixture did not report its PID" >&2
  exit 1
}
term_ignore_pid="$(/bin/cat "$TERM_IGNORE_PID_FILE")"
if /bin/kill -0 "$term_ignore_pid" 2>/dev/null; then
  echo "TERM-ignoring fixture was not reaped" >&2
  exit 1
fi

echo "generate_appcast.sh test passed"
