# ADR 0002: Container Data Model

## Status

Accepted, amended by ADR 0003.

## Decision

Each container has a portable manifest that records:

- last-used runtime provenance (`runtimeID`, `patchsetID`, source revision, GPTK fingerprint, and usage time)
- executable path
- last run status
- environment overrides
- schema version

Runtime provenance is diagnostic history. It does not select or pin a runtime for the container. Schema 1-4 `wineBuildID`, `patchsetID`, and `gptkFingerprint` values migrate into the schema 5 last-runtime record when read.

The manifest is the portable source of truth. SQLite may be added as an index/cache, but it must be rebuildable from manifests.

## Consequences

- Containers can be moved or inspected outside the app.
- Diagnostics can identify the runtime that most recently touched a container without changing launch selection.
- Runtime selection remains an app-wide concern under ADR 0003.
- Corrupted indexes must not destroy container state.
