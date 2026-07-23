# ADR 0003: Runtime Update Model

## Status

Accepted.

## Decision

Switchyard has exactly one active Wine runtime for all containers. The app's signed compatibility policy selects and verifies that runtime, and every install, launch, prefix-management, callback, and shortcut operation uses it. Containers do not select or pin runtime versions.

Runtime archives remain immutable and content-addressed. Installing or manually selecting an approved update is an app-wide selection change and is blocked while any container is running, launching, preparing, stopping, or changing storage. On the next launch of an idle container, Switchyard runs `wineboot -u` when the container is new, has unknown runtime history, or was last used with another runtime. That preparation is automatic and does not create a per-container migration choice.

Each container records the runtime provenance that most recently touched it. The record exists only for diagnostics and automatic prefix preparation; it never overrides the active app-wide runtime.

If an emergency rollback is required, it is a whole-app recovery operation paired with a Switchyard version whose compatibility policy approves that runtime. Per-container rollback is not part of the product model, and prefix mutations mean rollback cannot be presented as lossless.

## Consequences

- Users do not need to discover, compare, or manage Wine versions for individual games.
- Compatibility work converges in the current `switchyard-wine` runtime instead of accumulating per-container runtime exceptions.
- A runtime regression can affect multiple containers, so runtime releases require broad compatibility validation and a prompt central fix.
- Multiple immutable runtime artifacts may coexist on disk, but only the active app-wide runtime executes workloads.
- Test coverage must verify legacy provenance migration, global runtime selection, and automatic prefix preparation after an active-runtime change.
