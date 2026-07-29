# Container Grid Design QA

## Comparison Target

- Source visual truth: `/var/folders/pz/7mc4qx917vj4lny57kwm4pnh0000gn/T/codex-clipboard-69207f8e-ccc4-46d2-9124-e049d3178e2e.png`
- Rendered implementation: `/tmp/switchyard-container-grid-final.png`
- Full-view comparison: `/tmp/switchyard-container-grid-comparison.png`
- Focused card-region evidence: `/tmp/switchyard-container-grid-detail.png`
- Running-card action evidence: `/tmp/switchyard-container-grid-context-menu.png`

## Viewport and Normalization

- Source raster: 2038 × 2622 px. The source is a tall native macOS window capture.
- Implementation raster: 969 × 768 px from the native-app Computer Use capture.
- Native SwiftUI has no CSS viewport or browser device scale factor; CSS size and `deviceScaleFactor` are not applicable.
- For the full-view comparison, the source's top 2038 × 1615 px content region was resized to 969 × 768 px, and the implementation remained 969 × 768 px. This aligns the visible navigation and primary content region while acknowledging that the supplied source window is taller.
- The requested list-to-grid redesign is an intentional layout change, so fidelity was judged against the existing shell, dark appearance, typography, controls, and information hierarchy rather than preserving the source list rows.

## State

- Korean localization and dark appearance.
- Seven real containers are visible.
- Steam is running and shows a live color preview.
- The other six containers are idle and use grayscale preview treatment.
- Card metadata includes status, last-run time, and measured storage size.

## Findings

- No actionable P0, P1, or P2 visual differences remain.
- The grid preserves the source application's sidebar, toolbar, native type, dark materials, compact status color, and subdued secondary text.
- The running thumbnail uses its original color while idle previews and fallbacks are visually desaturated.
- Card titles, executable descriptions, last-run times, and sizes remain readable and consistently aligned.
- The stop action is exposed only for running containers. The running-card context action and destructive confirmation copy were exercised successfully.

## Required Fidelity Surfaces

- Fonts and typography: native system fonts, optical weights, truncation, and hierarchy are consistent with the source shell.
- Spacing and layout rhythm: adaptive tracks, 18-point gaps, 20-point content padding, 14-point card radii, and the 16:9 preview area form a consistent grid.
- Colors and tokens: existing materials and semantic accent, green running, secondary, and destructive red colors are reused.
- Image quality and assets: the Steam preview is a real captured Wine window, fit without cropping; SF Symbols provide native status and action icons; idle imagery is grayscale.
- Copy and content: visible Korean copy is brief and task-focused; the existing safety warning remains visible before stopping a session.

## Primary Interactions Tested

- Open a container card and return to the grid.
- Inspect the running-card Stop action.
- Verify the running card exposes a separate localized Stop accessibility action even while the visual hover control is hidden.
- Present and complete the existing destructive stop confirmation for the QA-started Epic session.
- Allow repeated background refreshes for ten seconds and verify that idle probes remain idle while Steam stays running.
- Native-app console checking is not applicable; build, shell integration, and Swift test results are recorded in the task handoff.

The Computer Use pointer synthesizer did not retain a SwiftUI `onHover` state long enough for a clean screenshot. The hover-only visual is therefore a residual P3 automation gap, not a design mismatch: the same stop button and confirmation flow were verified through the running card's context action, and the hover reveal condition is implemented on the card.

## Comparison History

1. Initial runtime pass found that transient Wine configuration windows could be persisted as previews and that inactive fallback artwork remained blue.
   - Fix: excluded Wine infrastructure windows from preview selection and applied grayscale treatment to the complete inactive preview.
   - Post-fix evidence: `/tmp/switchyard-container-grid-final.png` and `/tmp/switchyard-container-grid-detail.png`.
2. The next pass found false running states because the read-only prefix probe could start an idle `wineserver`.
   - Fix: check the host process table before invoking `wineserver -w`, with a shell regression test asserting that an inactive probe launches nothing.
   - Post-fix evidence: `/tmp/switchyard-container-grid-final.png`; after repeated polling, only the pre-existing Steam Wine session remained.
3. The required code review found four issues: a second probe path could still wake an idle session, an infrastructure window could consume the single preview capture slot, orphaned processes looked healthy, and the hover-only stop control was hidden from assistive access.
   - Fix: centralized the host-process precheck in every prefix probe, added an app-window recapture fallback, introduced the warning-colored Cleanup needed state, and kept the stop action in the accessibility tree with keyboard-focus reveal.
   - Post-fix verification: the runner integration test and all 222 Swift tests pass; the final accessibility tree exposes a separate Korean “중지” button for Steam.
4. Final comparison found no remaining P0, P1, or P2 issues.

## Implementation Checklist

- [x] Adaptive container grid
- [x] Persistent last-window preview
- [x] Grayscale idle treatment
- [x] Running state, last-run time, and storage size
- [x] Running-only stop affordance and safety confirmation
- [x] Stable read-only session polling
- [x] Full-view and focused visual comparison

final result: passed
