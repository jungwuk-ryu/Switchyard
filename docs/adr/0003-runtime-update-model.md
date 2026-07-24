# ADR 0003: Runtime Update Model

## Status

Accepted.

## Decision

Switchyard has exactly one active Wine runtime for all containers. Every install, launch, prefix-management, callback, and shortcut operation uses it. Containers do not select or pin runtime versions.

The signed app pins one exact official runtime as its recommended default for automatic setup. Runtime settings also discover stable releases published by the official `switchyard-wine` GitHub repository. A release is eligible only when its manifest and archive remain in that repository's release channel, its manifest names the Developer ID team trusted by the app, and installation verifies the exact archive size and digest, complete extracted content digest, runtime provenance, supported architectures, and Developer ID signatures. Local Wine paths are a development-build escape hatch, not the normal user flow.

Runtime archives remain immutable and content-addressed. Downloading a release does not activate it. Selecting an installed official release is an app-wide change and is blocked while any container is running, launching, preparing, stopping, or changing storage. On the next launch of an idle container, Switchyard runs `wineboot -u` when the container is new, has unknown runtime history, or was last used with another runtime. That preparation is automatic and does not create a per-container migration choice.

Each container records the runtime provenance that most recently touched it. The record exists only for diagnostics and automatic prefix preparation; it never overrides the active app-wide runtime.

The selected GPTK path is also app-wide. Launches snapshot the active Wine runtime, GPTK path, and GPTK fingerprint together, and no global compatibility component may change while a container is running or transitioning. GPTK is injected through external library paths and does not by itself trigger Wine prefix preparation.

Selecting an older installed official release is a whole-app rollback. Per-container rollback is not part of the product model, and prefix mutations mean rollback cannot be presented as lossless.

## Consequences

- Users can download, select, and remove official Wine releases in one place without managing versions for individual games.
- Compatibility work converges in the current `switchyard-wine` runtime instead of accumulating per-container runtime exceptions.
- A runtime regression can affect multiple containers, so runtime releases require broad compatibility validation and a prompt central fix.
- Multiple immutable runtime artifacts may coexist on disk, but only the active app-wide runtime executes workloads.
- The active runtime cannot be removed. Inactive managed runtimes can be deleted and downloaded again later.
- Test coverage must verify release-channel filtering, managed-cache deletion boundaries, legacy provenance migration, global runtime selection, and automatic prefix preparation after an active-runtime change.
