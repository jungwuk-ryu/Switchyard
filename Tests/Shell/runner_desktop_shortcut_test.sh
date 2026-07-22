#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER_PATH="${SWITCHYARD_RUNNER_PATH:-$ROOT_DIR/.build/debug/switchyard-runner}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/switchyard-desktop-shortcut.XXXXXX")"
PREFIX_PATH="$TEST_ROOT/Test.container"
DESKTOP_PATH="$PREFIX_PATH/drive_c/users/steamuser/Desktop"
FAKE_WINE="$TEST_ROOT/wine"
REQUEST_PATH="$TEST_ROOT/request.json"
ARGUMENTS_PATH="$TEST_ROOT/arguments.txt"
ENVIRONMENT_PATH="$TEST_ROOT/environment.txt"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$DESKTOP_PATH"
printf 'synthetic shortcut\n' >"$DESKTOP_PATH/Heartopia.lnk"
cat >"$FAKE_WINE" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '[invocation]' "$@" >>"$SWITCHYARD_TEST_ARGUMENTS_PATH"
printf '%s\n' \
  "$WINEPREFIX" \
  "$SWITCHYARD_DESKTOP_SHORTCUTS_FILE" \
  "$SWITCHYARD_PRIVATE_DESKTOP" >>"$SWITCHYARD_TEST_ENVIRONMENT_PATH"
SCRIPT
chmod +x "$FAKE_WINE"

cat >"$REQUEST_PATH" <<JSON
{
  "shortcutID": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "prefixPath": "$PREFIX_PATH",
  "winePath": "$FAKE_WINE",
  "windowsShortcutPath": "C:\\\\users\\\\steamuser\\\\Desktop\\\\Heartopia.lnk"
}
JSON
chmod 600 "$REQUEST_PATH"

SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-shortcut --request "$REQUEST_PATH"

test ! -e "$REQUEST_PATH"
diff -u \
  <(printf '%s\n' \
    '[invocation]' \
    'start' 'C:\users\steamuser\Desktop\Heartopia.lnk') \
  "$ARGUMENTS_PATH"
diff -u \
  <(printf '%s\n' \
    "$PREFIX_PATH" \
    'C:\windows\temp\switchyard-desktop-shortcuts-v1.txt' \
    '1') \
  "$ENVIRONMENT_PATH"

cat >"$REQUEST_PATH" <<JSON
{
  "shortcutID": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "prefixPath": "$PREFIX_PATH",
  "winePath": "$FAKE_WINE",
  "windowsShortcutPath": "C:\\\\users\\\\steamuser\\\\Desktop\\\\..\\\\Outside.lnk"
}
JSON
chmod 600 "$REQUEST_PATH"
if SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
  SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-shortcut --request "$REQUEST_PATH" >/dev/null 2>&1; then
  echo "runner accepted a desktop shortcut path containing traversal" >&2
  exit 1
fi
test ! -e "$REQUEST_PATH"

rm "$DESKTOP_PATH/Heartopia.lnk"
printf 'external shortcut\n' >"$TEST_ROOT/Outside.lnk"
ln -s "$TEST_ROOT/Outside.lnk" "$DESKTOP_PATH/Heartopia.lnk"
cat >"$REQUEST_PATH" <<JSON
{
  "shortcutID": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "prefixPath": "$PREFIX_PATH",
  "winePath": "$FAKE_WINE",
  "windowsShortcutPath": "C:\\\\users\\\\steamuser\\\\Desktop\\\\Heartopia.lnk"
}
JSON
chmod 600 "$REQUEST_PATH"
if SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
  SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" open-shortcut --request "$REQUEST_PATH" >/dev/null 2>&1; then
  echo "runner accepted a symbolic-link desktop shortcut" >&2
  exit 1
fi
test ! -e "$REQUEST_PATH"

rm -rf "$DESKTOP_PATH"
ln -s "$HOME/Desktop" "$DESKTOP_PATH"
PLAN_PATH="$TEST_ROOT/plan.json"
cat >"$PLAN_PATH" <<JSON
{
  "executable": "$FAKE_WINE",
  "arguments": ["C:\\\\Game.exe"],
  "environment": {
    "WINEPREFIX": "$PREFIX_PATH",
    "SWITCHYARD_DESKTOP_SHORTCUTS_FILE": "C:\\\\windows\\\\temp\\\\switchyard-desktop-shortcuts-v1.txt",
    "SWITCHYARD_PRIVATE_DESKTOP": "1"
  },
  "workingDirectory": "$PREFIX_PATH",
  "logSource": "desktop-shortcut-test"
}
JSON

: >"$ARGUMENTS_PATH"
: >"$ENVIRONMENT_PATH"
SWITCHYARD_TEST_ARGUMENTS_PATH="$ARGUMENTS_PATH" \
SWITCHYARD_TEST_ENVIRONMENT_PATH="$ENVIRONMENT_PATH" \
  "$RUNNER_PATH" run --plan "$PLAN_PATH" >/dev/null

test -d "$DESKTOP_PATH"
test ! -L "$DESKTOP_PATH"
test -d "$HOME/Desktop"
test "$(rg -c -x 'winemenubuilder.exe' "$ARGUMENTS_PATH")" = "1"
test "$(rg -c -x -- '-m' "$ARGUMENTS_PATH")" = "1"
test "$(rg -c -F -x 'C:\Game.exe' "$ARGUMENTS_PATH")" = "1"

printf 'runner desktop shortcut test passed\n'
