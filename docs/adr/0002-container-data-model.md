# ADR 0002: Container Data Model

## Status

Accepted for v1 scaffold.

## Decision

Each container has a portable manifest that pins runtime identity:

- `wineBuildID`
- `patchsetID`
- `gptkFingerprint`
- launcher type/version
- environment overrides
- schema version

The manifest is the portable source of truth. SQLite may be added as an index/cache, but it must be rebuildable from manifests.

## Consequences

- Containers can be moved or inspected outside the app.
- Runtime migrations can be explicit and reversible.
- Corrupted indexes must not destroy container state.
