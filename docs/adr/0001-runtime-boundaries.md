# ADR 0001: Runtime Boundaries

## Status

Accepted for v1 scaffold.

## Decision

Switchyard keeps the SwiftUI app, runner, Wine runtime, and user-provided GPTK installation as separate boundaries.

- The SwiftUI app owns UI, preferences, diagnostics, and high-level job state.
- `runtime/runner` owns process execution, explicit argv/env construction, stdout/stderr streaming, and termination status.
- Wine source and build tooling live in the separate public `switchyard-wine` repository. This app pins a source commit and validates installed runtime manifests against it.
- Wine is launched as an external runtime process and is never linked into the app.
- GPTK is never committed or bundled. The app stores only a user-selected path and local fingerprint.

## Consequences

- LGPL obligations are easier to reason about because the app does not link directly against Wine.
- Runner behavior can be tested with command plans without opening SwiftUI.
- Wine source history, LGPL provenance, and runtime releases can evolve independently from the app.
- Distribution of prebuilt runtimes that include or depend on redistributed GPTK components remains blocked pending legal review of Apple's GPTK license terms; the open-source app and Wine source repositories do not include those components.
