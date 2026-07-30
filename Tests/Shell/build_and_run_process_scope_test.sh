#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/script/build_and_run.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-build-run-process.XXXXXX")"
OWNED_EXECUTABLE="$TEST_ROOT/owned/Switchyard"
OTHER_EXECUTABLE="$TEST_ROOT/other/Switchyard"

WATCHDOG_PID=""
WATCHDOG_START_IDENTITY=""
WATCHDOG_ARGUMENT=""
PREEXISTING_PID=""
PREEXISTING_START_IDENTITY=""
PREEXISTING_ARGUMENT=""
OTHER_PID=""
OTHER_START_IDENTITY=""
OTHER_ARGUMENT=""
OWNED_PID=""
OWNED_START_IDENTITY=""
OWNED_ARGUMENT=""
OLD_DELAYED_PID=""
OLD_DELAYED_START_IDENTITY=""
OLD_DELAYED_ARGUMENT=""
DELAYED_PID=""
DELAYED_START_IDENTITY=""
DELAYED_ARGUMENT=""

# shellcheck source=script/build_and_run.sh
source "$SCRIPT"

wait_for_start_identity() {
  local pid="$1"
  local attempts="${2:-40}"
  local start_identity=""

  while [ "$attempts" -gt 0 ]; do
    start_identity="$(process_start_identity "$pid")"
    if [ -n "$start_identity" ]; then
      /usr/bin/printf '%s\n' "$start_identity"
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.05
  done
  return 1
}

stop_watchdog() {
  if [ -z "$WATCHDOG_PID" ] || [ -z "$WATCHDOG_START_IDENTITY" ]; then
    return
  fi
  terminate_tagged_process \
    "$WATCHDOG_PID" \
    "$WATCHDOG_START_IDENTITY" \
    "/usr/bin/perl" \
    "$WATCHDOG_ARGUMENT" \
    2 \
    20 \
    || true
  WATCHDOG_PID=""
  WATCHDOG_START_IDENTITY=""
  WATCHDOG_ARGUMENT=""
}

cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM

  if [ -n "$OWNED_PID" ] && [ -n "$OWNED_START_IDENTITY" ]; then
    terminate_tagged_process \
      "$OWNED_PID" \
      "$OWNED_START_IDENTITY" \
      "$OWNED_EXECUTABLE" \
      "$OWNED_ARGUMENT" \
      2 \
      20 \
      || true
  fi
  if [ -n "$PREEXISTING_PID" ] && [ -n "$PREEXISTING_START_IDENTITY" ]; then
    terminate_tagged_process \
      "$PREEXISTING_PID" \
      "$PREEXISTING_START_IDENTITY" \
      "$OWNED_EXECUTABLE" \
      "$PREEXISTING_ARGUMENT" \
      2 \
      20 \
      || true
  fi
  if [ -n "$OTHER_PID" ] && [ -n "$OTHER_START_IDENTITY" ]; then
    terminate_tagged_process \
      "$OTHER_PID" \
      "$OTHER_START_IDENTITY" \
      "$OTHER_EXECUTABLE" \
      "$OTHER_ARGUMENT" \
      2 \
      20 \
      || true
  fi
  if [ -n "$DELAYED_PID" ] && [ -n "$DELAYED_START_IDENTITY" ]; then
    terminate_tagged_process \
      "$DELAYED_PID" \
      "$DELAYED_START_IDENTITY" \
      "$OWNED_EXECUTABLE" \
      "$DELAYED_ARGUMENT" \
      2 \
      20 \
      || true
  fi
  if [ -n "$OLD_DELAYED_PID" ] && [ -n "$OLD_DELAYED_START_IDENTITY" ]; then
    terminate_tagged_process \
      "$OLD_DELAYED_PID" \
      "$OLD_DELAYED_START_IDENTITY" \
      "$OWNED_EXECUTABLE" \
      "$OLD_DELAYED_ARGUMENT" \
      2 \
      20 \
      || true
  fi
  stop_watchdog

  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/switchyard-build-run-process.*)
      /bin/rm -rf -- "$TEST_ROOT"
      ;;
    *)
      echo "refusing to remove unexpected test path: $TEST_ROOT" >&2
      exit_status=1
      ;;
  esac
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

WATCHDOG_ARGUMENT="--switchyard-test-watchdog=$$"
/usr/bin/perl \
  -e 'sleep $ARGV[0]; kill "TERM", $ARGV[1]' \
  15 \
  "$$" \
  "$WATCHDOG_ARGUMENT" &
WATCHDOG_PID=$!
WATCHDOG_START_IDENTITY="$(wait_for_start_identity "$WATCHDOG_PID")"

help_output="$(
  SWITCHYARD_BUILD_CONFIGURATION=invalid \
    "$SCRIPT" --help 2>&1
)"
case "$help_output" in
  *"usage:"*) ;;
  *)
    echo "help did not return usage before configuration validation" >&2
    exit 1
    ;;
esac

set +e
invalid_output="$(
  SWITCHYARD_BUILD_CONFIGURATION=invalid \
    "$SCRIPT" invalid-mode 2>&1
)"
invalid_status=$?
set -e
if [ "$invalid_status" -ne 2 ]; then
  echo "invalid mode exited with status $invalid_status instead of 2" >&2
  exit 1
fi
case "$invalid_output" in
  *"SWITCHYARD_BUILD_CONFIGURATION"*)
    echo "invalid mode reached configuration validation" >&2
    exit 1
    ;;
  *"usage:"*) ;;
  *)
    echo "invalid mode did not report usage" >&2
    exit 1
    ;;
esac

if /usr/bin/grep -Eq '(^|[^[:alnum:]_])(pkill|pgrep)([^[:alnum:]_]|$)' "$SCRIPT"; then
  echo "build_and_run.sh still contains a global name-based process operation" >&2
  exit 1
fi
# shellcheck disable=SC2016
if ! /usr/bin/grep -Fq -- '--package-path "$ROOT_DIR"' "$SCRIPT"; then
  echo "SwiftPM commands are not pinned to the repository package path" >&2
  exit 1
fi

/bin/mkdir -p "$TEST_ROOT/owned" "$TEST_ROOT/other"
/bin/cp /usr/bin/perl "$OWNED_EXECUTABLE"
/bin/cp /usr/bin/perl "$OTHER_EXECUTABLE"

OLD_DELAYED_ARGUMENT="--switchyard-launch-token=old-window-$$"
/usr/bin/perl \
  -e 'select undef, undef, undef, 0.8; exec {$ARGV[0]} $ARGV[0], "-e", "sleep 30", "--", $ARGV[1]' \
  "$OWNED_EXECUTABLE" \
  "$OLD_DELAYED_ARGUMENT" &
OLD_DELAYED_PID=$!
OLD_DELAYED_START_IDENTITY="$(wait_for_start_identity "$OLD_DELAYED_PID")"
TRACKED_APP_PID=""
TRACKED_APP_START_IDENTITY=""
TRACKED_APP_EXECUTABLE="$OWNED_EXECUTABLE"
TRACKED_APP_LAUNCH_ARGUMENT="$OLD_DELAYED_ARGUMENT"
CLEANUP_TRACKED_APP_ON_EXIT=1
LAUNCH_OBSERVATION_ATTEMPTS=4
LAUNCH_OBSERVATION_DELAY=0.1
cleanup_tracked_app
old_window_record="$(
  wait_for_tagged_process_record \
    "$OWNED_EXECUTABLE" \
    "$OLD_DELAYED_ARGUMENT" \
    20 \
    0.05
)"
old_window_pid="${old_window_record%%$'\t'*}"
old_window_start_identity="${old_window_record#*$'\t'}"
if [ "$old_window_pid" != "$OLD_DELAYED_PID" ] \
  || [ "$old_window_start_identity" != "$OLD_DELAYED_START_IDENTITY" ]; then
  echo "old 0.4 second cleanup control did not leave the delayed fake app running" >&2
  exit 1
fi
terminate_tagged_process \
  "$OLD_DELAYED_PID" \
  "$OLD_DELAYED_START_IDENTITY" \
  "$OWNED_EXECUTABLE" \
  "$OLD_DELAYED_ARGUMENT" \
  2 \
  20
OLD_DELAYED_PID=""
OLD_DELAYED_START_IDENTITY=""

DELAYED_ARGUMENT="--switchyard-launch-token=current-window-$$"
/usr/bin/perl \
  -e 'select undef, undef, undef, 0.8; exec {$ARGV[0]} $ARGV[0], "-e", "sleep 30", "--", $ARGV[1]' \
  "$OWNED_EXECUTABLE" \
  "$DELAYED_ARGUMENT" &
DELAYED_PID=$!
DELAYED_START_IDENTITY="$(wait_for_start_identity "$DELAYED_PID")"
TRACKED_APP_PID=""
TRACKED_APP_START_IDENTITY=""
TRACKED_APP_EXECUTABLE="$OWNED_EXECUTABLE"
TRACKED_APP_LAUNCH_ARGUMENT="$DELAYED_ARGUMENT"
CLEANUP_TRACKED_APP_ON_EXIT=1
LAUNCH_OBSERVATION_ATTEMPTS=20
LAUNCH_OBSERVATION_DELAY=0.5
cleanup_tracked_app
if [ -n "$(process_start_identity "$DELAYED_PID")" ]; then
  echo "current cleanup missed an app that appeared after the old 0.4 second window" >&2
  exit 1
fi
if [ -n "$(tagged_process_records "$OWNED_EXECUTABLE" "$DELAYED_ARGUMENT")" ]; then
  echo "current delayed launch cleanup left a tagged fake app process behind" >&2
  exit 1
fi
DELAYED_PID=""
DELAYED_START_IDENTITY=""
CLEANUP_TRACKED_APP_ON_EXIT=0

PREEXISTING_ARGUMENT="--switchyard-launch-token=preexisting-$$"
"$OWNED_EXECUTABLE" -e 'sleep 30' -- "$PREEXISTING_ARGUMENT" &
PREEXISTING_PID=$!
PREEXISTING_START_IDENTITY="$(wait_for_start_identity "$PREEXISTING_PID")"

OTHER_ARGUMENT="--switchyard-launch-token=other-$$"
"$OTHER_EXECUTABLE" -e 'sleep 30' -- "$OTHER_ARGUMENT" &
OTHER_PID=$!
OTHER_START_IDENTITY="$(wait_for_start_identity "$OTHER_PID")"

OWNED_ARGUMENT="--switchyard-launch-token=owned-$$"
# shellcheck disable=SC2016
"$OWNED_EXECUTABLE" -e '$SIG{TERM} = "IGNORE"; sleep 30' -- "$OWNED_ARGUMENT" &
OWNED_PID=$!
OWNED_START_IDENTITY="$(wait_for_start_identity "$OWNED_PID")"

record="$(
  wait_for_tagged_process_record \
    "$OWNED_EXECUTABLE" \
    "$OWNED_ARGUMENT" \
    40 \
    0.05
)"
record_pid="${record%%$'\t'*}"
record_start_identity="${record#*$'\t'}"
if [ "$record_pid" != "$OWNED_PID" ] \
  || [ "$record_start_identity" != "$OWNED_START_IDENTITY" ]; then
  echo "launch tracking selected the wrong process identity" >&2
  exit 1
fi

terminate_tagged_process \
  "$OWNED_PID" \
  "$OWNED_START_IDENTITY" \
  "$OWNED_EXECUTABLE" \
  "$OWNED_ARGUMENT" \
  2 \
  20
OWNED_PID=""
OWNED_START_IDENTITY=""

if ! process_matches_launch \
  "$PREEXISTING_PID" \
  "$PREEXISTING_START_IDENTITY" \
  "$OWNED_EXECUTABLE" \
  "$PREEXISTING_ARGUMENT"; then
  echo "termination affected the pre-existing process at the same executable path" >&2
  exit 1
fi
if ! process_matches_launch \
  "$OTHER_PID" \
  "$OTHER_START_IDENTITY" \
  "$OTHER_EXECUTABLE" \
  "$OTHER_ARGUMENT"; then
  echo "termination affected the same-named process from another path" >&2
  exit 1
fi

terminate_tagged_process \
  "$PREEXISTING_PID" \
  "$PREEXISTING_START_IDENTITY" \
  "$OWNED_EXECUTABLE" \
  "$PREEXISTING_ARGUMENT" \
  2 \
  20
PREEXISTING_PID=""
PREEXISTING_START_IDENTITY=""
terminate_tagged_process \
  "$OTHER_PID" \
  "$OTHER_START_IDENTITY" \
  "$OTHER_EXECUTABLE" \
  "$OTHER_ARGUMENT" \
  2 \
  20
OTHER_PID=""
OTHER_START_IDENTITY=""

stop_watchdog
echo "build_and_run process scope tests passed"
