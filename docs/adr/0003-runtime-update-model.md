# ADR 0003: Runtime Update Model

## Status

Accepted for v1 scaffold.

## Decision

Runtime updates must not mutate working containers in place.

Switchyard creates candidate runtimes, then offers per-container migration. Existing containers keep their pinned runtime until the user migrates them. Failed migration must leave recovery metadata and preserve rollback.

## Consequences

- Users can keep a known-working container setup.
- Compatibility regressions are isolated to migrated containers.
- Test coverage must include runtime A to runtime B migration and rollback.
