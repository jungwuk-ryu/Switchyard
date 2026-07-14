#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CONFIG="$ROOT_DIR/config/switchyard-wine.env"
SOURCE_CACHE_ROOT="${SWITCHYARD_WINE_SOURCE_CACHE_ROOT:-$HOME/Library/Caches/Switchyard/Sources}"
SOURCE_DIR="${SWITCHYARD_WINE_SOURCE_DIR:-$SOURCE_CACHE_ROOT/switchyard-wine}"
LOCK_FILE="${SWITCHYARD_RUNTIME_CACHE_ROOT:-$HOME/.switchyard/runtimes}/.ensure-current-runtime.lock"
temporary_source_dir=""

cleanup() {
  if [ -n "$temporary_source_dir" ]; then
    rm -rf "$temporary_source_dir"
  fi
}
trap cleanup EXIT

config_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$SOURCE_CONFIG" | tail -n 1
}

if [ ! -f "$SOURCE_CONFIG" ]; then
  echo "missing Switchyard Wine source configuration at $SOURCE_CONFIG" >&2
  exit 1
fi

repository="${SWITCHYARD_WINE_REPOSITORY:-$(config_value SWITCHYARD_WINE_REPOSITORY)}"
revision="${SWITCHYARD_WINE_REVISION:-$(config_value SWITCHYARD_WINE_REVISION)}"
history_depth="${SWITCHYARD_WINE_HISTORY_DEPTH:-$(config_value SWITCHYARD_WINE_HISTORY_DEPTH)}"

if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Switchyard Wine revision must be a full 40-character commit ID, got: $revision" >&2
  exit 1
fi
if [[ ! "$history_depth" =~ ^[0-9]+$ ]] || [ "$history_depth" -lt 128 ]; then
  echo "Switchyard Wine history depth must be an integer of at least 128, got: $history_depth" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOCK_FILE")"
if [ "${1:-}" != "--with-lock" ]; then
  echo "Synchronizing Switchyard Wine source revision ${revision:0:12}..."
  exec /usr/bin/lockf -k "$LOCK_FILE" "$0" --with-lock
fi

if [ -e "$SOURCE_DIR" ] && [ ! -d "$SOURCE_DIR/.git" ]; then
  echo "Switchyard Wine source cache exists but is not a Git checkout: $SOURCE_DIR" >&2
  exit 1
fi

if [ ! -d "$SOURCE_DIR/.git" ]; then
  mkdir -p "$(dirname "$SOURCE_DIR")"
  temporary_source_dir="${SOURCE_DIR}.tmp.$$"
  rm -rf "$temporary_source_dir"
  git init "$temporary_source_dir" >/dev/null
  git -C "$temporary_source_dir" remote add origin "$repository"
  git -C "$temporary_source_dir" fetch --depth "$history_depth" origin "$revision"
  git -C "$temporary_source_dir" checkout --detach FETCH_HEAD
  mv "$temporary_source_dir" "$SOURCE_DIR"
  temporary_source_dir=""
fi

configured_remote="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || true)"
if [ "$configured_remote" != "$repository" ]; then
  echo "Switchyard Wine cache uses unexpected origin $configured_remote; expected $repository" >&2
  exit 1
fi
if [ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=normal)" ]; then
  echo "Switchyard Wine source checkout has local changes at $SOURCE_DIR; refusing to overwrite them" >&2
  exit 1
fi
if ! git -C "$SOURCE_DIR" cat-file -e "${revision}^{commit}" 2>/dev/null; then
  git -C "$SOURCE_DIR" fetch --depth "$history_depth" origin "$revision"
fi
if [ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$revision" ]; then
  git -C "$SOURCE_DIR" checkout --detach "$revision"
fi

"$SOURCE_DIR/switchyard/verify_source.sh"
export SWITCHYARD_WINE_SOURCE_REPOSITORY="$repository"
exec "$SOURCE_DIR/switchyard/build_runtime.sh" --ensure
