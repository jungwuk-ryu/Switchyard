# ADR 0001: Runtime Boundaries

## Status

Accepted for v1 scaffold.

## Decision

Switchyard keeps the SwiftUI app, runner, Wine runtime, and user-provided GPTK installation as separate boundaries.

- The SwiftUI app owns UI, preferences, diagnostics, and high-level job state.
- `runtime/runner` owns process execution, explicit argv/env construction, stdout/stderr streaming, and termination status.
- Wine is launched as an external runtime process.
- GPTK is never committed or bundled. The app stores only a user-selected path and local fingerprint.

## Consequences

- LGPL obligations are easier to reason about because the app does not link directly against Wine.
- Runner behavior can be tested with command plans without opening SwiftUI.
- Public distribution remains blocked on legal review of Apple GPTK license terms.
