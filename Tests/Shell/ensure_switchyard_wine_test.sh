#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
SOURCE_REPOSITORY="$TEST_ROOT/source-repository"
SOURCE_CHECKOUT="$TEST_ROOT/source-checkout"
RUNTIME_ROOT="$TEST_ROOT/runtimes"
BUILD_MARKER="$TEST_ROOT/build-called"
VERIFY_MARKER="$TEST_ROOT/verify-called"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$SOURCE_REPOSITORY/switchyard" "$RUNTIME_ROOT"
git -C "$SOURCE_REPOSITORY" init -b main >/dev/null

cat > "$SOURCE_REPOSITORY/switchyard/verify_source.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "$TEST_VERIFY_MARKER"
EOF

cat > "$SOURCE_REPOSITORY/switchyard/build_runtime.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != "--ensure" ]; then
  echo "source handoff did not request full runtime identity validation" >&2
  exit 2
fi
if [ "$WINE_INSTALL_PREFIX" != "$TEST_CUSTOM_PREFIX" ]; then
  echo "source handoff did not preserve WINE_INSTALL_PREFIX" >&2
  exit 3
fi
if [ "$SWITCHYARD_WINE_SOURCE_REPOSITORY" != "$TEST_SOURCE_REPOSITORY" ]; then
  echo "source handoff did not preserve the configured repository identity" >&2
  exit 4
fi
if [ ! -f "$TEST_BUILD_MARKER" ]; then
  sleep 1
  : > "$TEST_BUILD_MARKER"
  printf '1\n' > "$TEST_BUILD_COUNT"
fi
EOF

chmod +x "$SOURCE_REPOSITORY/switchyard/verify_source.sh" "$SOURCE_REPOSITORY/switchyard/build_runtime.sh"
git -C "$SOURCE_REPOSITORY" add switchyard
git -C "$SOURCE_REPOSITORY" -c user.name=Switchyard -c user.email=test@switchyard.local commit -m "test: add fake runtime source" >/dev/null
SOURCE_REVISION="$(git -C "$SOURCE_REPOSITORY" rev-parse HEAD)"

TEST_BUILD_COUNT="$TEST_ROOT/build-count"
TEST_CUSTOM_PREFIX="$TEST_ROOT/custom-prefix"
export TEST_BUILD_MARKER="$BUILD_MARKER" TEST_BUILD_COUNT TEST_CUSTOM_PREFIX TEST_VERIFY_MARKER="$VERIFY_MARKER"
export TEST_SOURCE_REPOSITORY="$SOURCE_REPOSITORY"
export WINE_INSTALL_PREFIX="$TEST_CUSTOM_PREFIX"
export SWITCHYARD_RUNTIME_CACHE_ROOT="$RUNTIME_ROOT"
export SWITCHYARD_WINE_SOURCE_DIR="$SOURCE_CHECKOUT"
export SWITCHYARD_WINE_REPOSITORY="$SOURCE_REPOSITORY"
export SWITCHYARD_WINE_REVISION="$SOURCE_REVISION"
export SWITCHYARD_WINE_HISTORY_DEPTH=128

"$ROOT_DIR/script/ensure_wine_runtime.sh" >/dev/null &
first_pid=$!
"$ROOT_DIR/script/ensure_wine_runtime.sh" >/dev/null &
second_pid=$!
wait "$first_pid" "$second_pid"

if [ "$(git -C "$SOURCE_CHECKOUT" rev-parse HEAD)" != "$SOURCE_REVISION" ]; then
  echo "source checkout did not resolve the pinned revision" >&2
  exit 1
fi
if [ ! -f "$VERIFY_MARKER" ]; then
  echo "source verification was not run" >&2
  exit 1
fi
if [ "$(sed -n '1p' "$TEST_BUILD_COUNT" 2>/dev/null || true)" != "1" ]; then
  echo "source synchronization did not serialize concurrent runtime builds" >&2
  exit 1
fi

echo "ensure_wine_runtime tests passed"
