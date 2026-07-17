# ADR 0003: Runtime Update Model

## Status

Partially implemented in the developer preview.

## Decision

Runtime updates must not mutate working containers in place.

Switchyard will create candidate runtimes, then offer per-container migration. Existing containers will keep their recorded runtime until the user migrates them. Failed migration must leave recovery metadata and preserve rollback.

The current preview can download the release manifest pinned by the app, verify and atomically install that signed runtime, and record runtime identity in each container manifest. It still launches with the globally selected compatible runtime. It must not claim per-container pin enforcement until runtime lookup and migration are implemented and tested.

## Consequences

For the remaining per-container migration work:

- Users can keep a known-working container setup.
- Compatibility regressions are isolated to migrated containers.
- Test coverage must include runtime A to runtime B migration and rollback.
