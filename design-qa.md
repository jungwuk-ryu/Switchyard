# Container Dashboard Design QA

## Visual truth and implementation evidence

- Source visual: `/Users/jungwuk/.codex/generated_images/019f66f9-57d8-7fe1-955a-06ebf51af89b/exec-f90b60a7-8d69-408c-87c6-4d7f069b6c10.png`
- Implementation capture: `/tmp/switchyard-dashboard-final.png`
- Full same-input comparison: `/tmp/switchyard-design-qa-comparison.png`
- Focused comparison: `/tmp/switchyard-design-qa-focused.png`
- Narrow-width implementation capture: `/tmp/switchyard-dashboard-narrow.png`
- Transition-width implementation capture: `/tmp/switchyard-dashboard-transition.png`
- Source viewport: 2045 × 769 pixels.
- Implementation viewport: 1969 × 732 logical points, captured at 3938 × 1464 pixels.
- Narrow-width check: approximately 1120 × 748 logical points, captured at 2240 × 1496 pixels.
- State: dark appearance, `Steam2` container, dashboard tab selected, real wineserver state, and real default program selected. Both active-process and idle-session states were exercised; the final capture records the active state with live process data.

## Required fidelity surfaces

| Surface | Result | Evidence |
| --- | --- | --- |
| Layout and hierarchy | Passed | Header, left-clustered tabs, selected-program hero, installed-program shelf, recent-files panel, and session panel match the source order and two-column desktop grid. |
| Spacing and density | Passed | The 18–20 point page inset, 16 point card gaps, compact rows, panel alignment, and vertical rhythm preserve the source's dashboard density without clipping. |
| Typography | Passed | Native macOS system typography preserves the source hierarchy: large container title, semibold section headings, callout metadata, and secondary labels. Long executable paths truncate instead of colliding. |
| Colors and surfaces | Passed | Native dark materials, subtle panel borders, blue selection strokes, and semantic green runtime states match the visual intent and retain system contrast behavior. |
| Image and icon fidelity | Passed | Installed program artwork is resolved from embedded Windows PE icon resources first, then real container assets. Battle.net, Steam, Internet Explorer, Chrome, and WordPad render recognizable application artwork in the exercised container. The native Wine file icon remains only when no usable program-specific resource is available. SF Symbols cover native actions and statuses consistently. |
| Copy and content | Passed | Static labels are concise and product-facing. Dynamic content comes from the real container, installed-program catalog, filesystem, runtime diagnostics, and external runner session APIs. |
| States and interactions | Passed | Dashboard, Applications, Files, Activity, and Settings tabs are wired. Files tab navigation and `C:` → `Program Files` browsing were exercised; Finder reveal is container-bound; live session refresh and process updates were observed. Empty, loading, unavailable, and inactive states are implemented. |
| Responsiveness | Passed | At 1120- and 1340-point window widths the hero, program shelf, file browser, and session panel stack cleanly with no overlap or clipped controls. The wide viewport retains the reference's two-column grid. |
| Accessibility | Passed | Interactive elements use native `Button`, `Menu`, labels, help text, focus behavior, and semantic selected traits. Colors are not the sole status cue, and no custom animation conflicts with reduced motion. |
| Implementation shortcuts | Passed | No handcrafted SVG, CSS art, emoji, placeholder boxes, fake metrics, or invented product imagery are used. CPU and memory columns from the concept are intentionally omitted because the runner does not expose trustworthy values. |

## Comparison history

### First implementation pass

- P2 layout: tabs and dashboard panels used too much horizontal spread, and the lower panels did not share a clean top edge.
- P2 responsiveness: the wide-only composition produced horizontal scrolling at narrower window sizes.
- P2 icons: the default application initially used a generic executable icon, and the first Steam icon candidate was a low-quality auxiliary asset.
- P2 content: the compact file panel initially opened at the install root, which made it less useful than the source's selected-app context.
- P3 density: process rows were taller than the source and displaced the all-processes action.

### Fixes applied

- Anchored tabs to the leading edge and normalized panel padding and minimum heights.
- Added a responsive 1400-point breakpoint that stacks each dashboard pair vertically before either card becomes cramped.
- Added bounded, container-safe icon discovery and scoring so real Chrome and Steam artwork wins over auxiliary assets.
- Opened Recent Files at the selected executable's parent directory and added navigable breadcrumbs.
- Tightened process rows and kept the all-processes action visible in the compact session panel.

### Review hardening

- Added per-container refresh tokens so a slower, older wineserver query cannot overwrite a newer session snapshot.
- Reset icon state and honor task cancellation before applying asynchronously resolved program artwork.
- Made the program shelf's Launch context action execute the selected program.
- Limited the visible shelf item count at two-column transition widths to prevent horizontal overflow.
- Tagged runner logs with stable container IDs so Activity cannot mix events from similarly named containers.

### Post-fix comparison

- Full and focused combined comparisons show no open P0, P1, or P2 differences.
- Remaining P3 variance is intentional: the implementation renders the user's real applications and processes rather than the concept's sample Steam/EA/Ubisoft/GOG data. Executables that genuinely contain Wine artwork or no usable icon resource may still use Wine-derived artwork instead of an invented brand asset.

## Concurrent-launch and recent-program iteration

- Iteration source visual truth: `/tmp/switchyard-dashboard-before-recent.png`
- Iteration implementation screenshot: `/tmp/switchyard-dashboard-final.png`
- Applications implementation screenshot: `/tmp/switchyard-applications-final.png`
- Post-review concurrent-launch log capture: `/tmp/switchyard-applications-post-review.png`
- Full same-input comparison: `/tmp/switchyard-dashboard-comparison.png`
- Focused same-input comparison: `/tmp/switchyard-programs-focus-comparison.png`
- Viewport: 1969 × 732 logical points, captured at 3938 × 1464 pixels.
- State: dark appearance, `Steam2` container, active wineserver, live process list, dashboard and Applications tabs, real installed programs, and persisted recent-launch history.
- Source-state note: the source and implementation use the same container and viewport, but dynamic default-app, filesystem, process, and timestamp values differ. The comparison therefore evaluates the established dashboard visual system and the intentional recent-program changes rather than pixel equality of runtime data.

### Interaction and visual evidence

- Launched WordPad from Installed Programs while the container wineserver and Battle.net processes were already active. The existing Windows session stayed active, WordPad appeared as a running process, and WordPad moved to the front of Recently Launched.
- Relaunched the app and confirmed recent history persisted, the dashboard default launch remained available during the active session, and Recent / All switching preserved the established shelf geometry.
- The full comparison preserves the existing header, hero, two-column grid, spacing, native typography, dark material tokens, and session-panel density.
- The focused comparison shows the intentional shelf change: generic Wine fallbacks were replaced where embedded application icons were available, timestamps fit without collision, and the Recent / All control remains aligned with View all.
- The Applications capture was inspected at full size because the launch buttons, embedded icons, selected state, and timestamp labels are too small to judge reliably in the full dashboard comparison.

### Iteration findings and fixes

- First pass P2 copy/layout: active-session cards used `Launch Alongside`, which truncated at the adaptive 260-point card width in `/tmp/switchyard-applications-concurrent-launch.png`.
- Fix: retained the explicit active-session banner and helper copy, while shortening each card action to `Launch`.
- Post-fix evidence: `/tmp/switchyard-applications-final.png` shows complete button labels across every visible card with no collision, clipping, or loss of concurrent-launch meaning.
- Post-fix review found no remaining P0, P1, or P2 issue across typography, spacing, colors, image quality, copy, state affordances, responsiveness, or accessibility.

### Code-review hardening

- Active-prefix launches now skip direct Open Font Pack registry rewrites. The post-review log capture records the skip immediately before the successful WordPad launch.
- First-prefix startup and explicit restarts keep the launch gate active until wineserver is observable or the runner exits. Additional launches into an already active prefix remain available.
- Embedded PE resource collection, final ICO reconstruction, decoded pixel dimensions, and in-memory cache size now have aggregate bounds. Invalid embedded data falls through to the existing sidecar artwork search.
- Automated package coverage verifies malformed PE bounds, ICO reconstruction, recent-launch reordering, empty-path handling, and actual history truncation. AppStore still owns a concrete process client, so reverse completion and stop-all transitions are covered by the real-prefix interaction pass rather than an injected runner unit test; this is a documented test-architecture gap, not an open product behavior failure.

## Final result

final result: passed
