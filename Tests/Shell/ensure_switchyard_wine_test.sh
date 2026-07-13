#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PATCH_ROOT="$TEST_ROOT/patches"
RUNTIME_ROOT="$TEST_ROOT/runtimes"
BUILD_MARKER="$TEST_ROOT/build-called"
FAKE_BUILD="$TEST_ROOT/fake-build.sh"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$PATCH_ROOT" "$RUNTIME_ROOT"
cat > "$PATCH_ROOT/series" <<'EOF'
current.patch
EOF
cat > "$PATCH_ROOT/current.patch" <<'EOF'
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
Subject: [PATCH] test: first note

Local test note A.
---
diff --git a/file b/file
--- a/file
+++ b/file
@@ -1 +1 @@
-old
+new
EOF

first_digest="$("$ROOT_DIR/runtime/build/patch_queue_digest.sh" "$PATCH_ROOT/series")"
perl -0pi -e 's/first note/revised note/; s/Local test note A/Local test note B/' "$PATCH_ROOT/current.patch"
second_digest="$("$ROOT_DIR/runtime/build/patch_queue_digest.sh" "$PATCH_ROOT/series")"
if [ "$first_digest" != "$second_digest" ]; then
  echo "patch queue digest changed after a mail-header-only edit" >&2
  exit 1
fi

printf 'current.patch' > "$PATCH_ROOT/series"
no_final_lf_digest="$("$ROOT_DIR/runtime/build/patch_queue_digest.sh" "$PATCH_ROOT/series")"
perl -0pi -e 's/\+new/\+newer/' "$PATCH_ROOT/current.patch"
changed_last_patch_digest="$("$ROOT_DIR/runtime/build/patch_queue_digest.sh" "$PATCH_ROOT/series")"
if [ "$no_final_lf_digest" = "$changed_last_patch_digest" ]; then
  echo "patch queue digest ignored the final patch without a trailing newline" >&2
  exit 1
fi

cat > "$FAKE_BUILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != "--ensure" ]; then
  echo "ensure wrapper did not request full runtime identity validation" >&2
  exit 2
fi
if [ "$WINE_INSTALL_PREFIX" != "$TEST_CUSTOM_PREFIX" ]; then
  echo "ensure wrapper did not preserve WINE_INSTALL_PREFIX" >&2
  exit 3
fi
if [ ! -f "$TEST_BUILD_MARKER" ]; then
  sleep 1
  : > "$TEST_BUILD_MARKER"
  printf '1\n' > "$TEST_BUILD_COUNT"
fi
EOF
chmod +x "$FAKE_BUILD"

TEST_BUILD_COUNT="$TEST_ROOT/build-count"
TEST_CUSTOM_PREFIX="$TEST_ROOT/custom-prefix"
export TEST_BUILD_MARKER="$BUILD_MARKER" TEST_BUILD_COUNT TEST_CUSTOM_PREFIX
export WINE_INSTALL_PREFIX="$TEST_CUSTOM_PREFIX"
export SWITCHYARD_RUNTIME_CACHE_ROOT="$RUNTIME_ROOT"
export SWITCHYARD_WINE_BUILD_SCRIPT="$FAKE_BUILD"
"$ROOT_DIR/runtime/build/ensure_switchyard_wine.sh" >/dev/null &
first_pid=$!
"$ROOT_DIR/runtime/build/ensure_switchyard_wine.sh" >/dev/null &
second_pid=$!
wait "$first_pid" "$second_pid"
if [ "$(sed -n '1p' "$TEST_BUILD_COUNT" 2>/dev/null || true)" != "1" ]; then
  echo "ensure wrapper did not serialize concurrent runtime builds" >&2
  exit 1
fi

echo "ensure_switchyard_wine tests passed"
