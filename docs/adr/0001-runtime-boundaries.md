# ADR 0001: Runtime Boundaries

## Status

Accepted for v1 scaffold. Amended 2026-07-22 for the GPTK 3 legal release gate.

## Decision

Switchyard keeps the SwiftUI app, runner, Wine runtime, and Apple-licensed GPTK installation as separate boundaries.

- The SwiftUI app owns UI, preferences, diagnostics, and high-level job state.
- `runtime/runner` owns process execution, explicit argv/env construction, stdout/stderr streaming, and termination status.
- Wine source and build tooling live in the separate public `switchyard-wine` repository. This app pins a source commit and validates installed runtime manifests against it.
- Wine is launched as an external runtime process and is never linked into the app.
- GPTK is never committed or bundled. The app may import either a user-selected Apple download or an exact component archive admitted by the version-specific legal release gate. The resulting local copy is fingerprinted and remains separate from Wine.

## Consequences

- LGPL obligations are easier to reason about because the app does not link directly against Wine.
- Runner behavior can be tested with command plans without opening SwiftUI.
- Wine source history, LGPL provenance, and runtime releases can evolve independently from the app.
- Prebuilt Wine runtimes containing GPTK and combined app/GPTK releases remain blocked.
- A separate, free GPTK 3 component channel may be implemented under the [GPTK 3 redistribution review](../legal/gptk-3-redistribution-review.md). Its component artifact must be built from the exact reviewed Apple image and remain disabled until every release control and independent legal sign-off passes. The Apple-provided DMGs are never transferred.
- New GPTK versions, commercial distribution, service hosting, and general consumer-play positioning require a new review or written Apple permission.
