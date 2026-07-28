# Session Stage Design QA

## Comparison Target

- Source visual truth: `/var/folders/pz/7mc4qx917vj4lny57kwm4pnh0000gn/T/codex-clipboard-cc397319-5ac9-4788-ad0d-6a1155891f2f.png`
- Implementation screenshot: `artifacts/design-qa/session-stage-no-process-stack.png`
- Full-view comparison: `artifacts/design-qa/session-stage-comparison-full.jpg`
- Focused comparison: `artifacts/design-qa/session-stage-comparison-focus.jpg`
- Post-review comparison: `artifacts/design-qa/session-stage-no-process-stack-comparison.jpg`
- User-feedback source: `artifacts/design-audit/01-session-stage-current.png`
- Post-feedback implementation: `artifacts/design-qa/session-stage-window-navigation-final.png`
- Post-feedback Task View: `artifacts/design-qa/session-stage-task-view-final.png`
- Post-feedback comparison: `artifacts/design-qa/session-stage-feedback-comparison.jpg`
- Reference-fidelity viewport: native macOS window at 1487 × 1058 points
- Source pixels: 1487 × 1058
- Initial implementation capture pixels: 1080 × 768, downsampled by the Computer Use capture service from the 1487 × 1058 native window
- Post-review capture pixels: 1492 × 768 after restoring the app from its zoomed window state
- User-feedback source pixels: 3534 × 2518; post-feedback implementation pixels: 1247 × 768
- Density normalization: the earlier exact-viewport comparison remains the geometry baseline. The post-review pair places the source and current state side by side to isolate the user-directed process-stack removal.
- Feedback normalization: the before/after pair is aspect-fitted into equal 1080 × 768 panels. The current Computer Use display could not reproduce the taller feedback-source viewport, so the comparison is used for hierarchy and state clarity rather than pixel-distance claims.
- CSS size / device scale factor: not applicable to this native SwiftUI app
- State: dark appearance, active Windows session, Start Menu closed, installed apps visible, secondary windows visible, bottom dock visible
- Data note: the source shows a Rockstar container while the implementation evidence uses installed Steam-container data. Product data and live window imagery are intentionally dynamic; the interaction state and layout are matched.
- Product-direction note: the source's process stack is intentionally omitted after user review. Task View remains the single process/window overview so the stage does not duplicate navigation or compete with the focused app.

## Findings

- No actionable P0, P1, or P2 findings remain.
- [P3] Live window imagery differs from the static Rockstar artwork in the source.
  - Location: main and secondary window cards.
  - Evidence: the source contains Rockstar launcher and installer imagery; the QA session had no capturable foreground Wine image and therefore shows the production fallback cards.
  - Impact: the composition is representative, but this capture cannot prove pixel fidelity for arbitrary third-party Windows windows.
  - Disposition: expected runtime-dependent content. Production uses ScreenCaptureKit snapshots when permission and a live Wine window are available; it does not ship or imitate the source artwork.
- [P3] The source keeps the session-stop control red while the implementation uses a neutral power button until hover.
  - Location: bottom-right session capsule.
  - Evidence: visible in the focused comparison.
  - Impact: minor visual deviation.
  - Disposition: intentional. Neutral-at-rest and red-on-hover reduces accidental destructive emphasis while retaining the requested power metaphor.
- [P3] The source includes a layered process stack beside the hero window.
  - Location: right edge of the main window.
  - Evidence: the stack is present in the source and absent from `session-stage-no-process-stack.png`.
  - Impact: intentional visual deviation that creates more breathing room around the focused app.
  - Disposition: accepted product change. The bottom-dock Task View already exposes the same running-window overview.

## Required Fidelity Surfaces

- Fonts and typography: both designs use the native macOS system family. Heading, label, and utility text weights preserve the source hierarchy; dock labels use bounded two-line truncation.
- Spacing and layout rhythm: header, hero card, secondary cards, Start Menu, and dock retain the source grouping at the same logical viewport. Removing the redundant process stack gives the hero and secondary cards a clearer visual hierarchy. Start Menu and dock remain inside the window bounds.
- Colors and visual tokens: dark navy backdrop, translucent charcoal surfaces, blue focus glow, green running state, and destructive red hover map to the source palette with sufficient contrast.
- Image quality and asset fidelity: extracted executable icons are preferred. When extraction fails, the implementation uses semantic SF Symbols rather than fake logos or copied artwork. Live Wine windows use ScreenCaptureKit images when available.
- Copy and content: labels are concise and task-focused. Twenty-eight session-stage strings are translated across all nine translated locales; Korean includes “시작 메뉴,” “앱 추가,” “작업 보기,” “더 보기,” the Screen Recording prompt, and “Windows 세션 종료.”
- Icons: controls use a consistent SF Symbols family. Start Menu uses the requested 3 × 3 grid, the session stop uses the requested power symbol, and running dock apps use a stronger green ring, badge, and text state.
- Accessibility and motion: semantic buttons and labels are present, the window counter and summary capsule expose real buttons, the destructive action requires confirmation, idle stop is disabled, keyboard search supports Command-K, and transitions respect Reduce Motion.

## Comparison History

### Iteration 1 — viewport and interaction state

- Earlier finding [P2]: the first native capture was 1792 × 734, making the stage too shallow relative to the 1487 × 1058 source, and the Start Menu state was not visible.
- Fix: normalized the native window to 1487 × 1058 and captured the Start Menu-open state.
- Earlier evidence: `artifacts/design-qa/session-stage-full.jpg`
- Post-fix evidence: `artifacts/design-qa/session-stage-comparison-full.jpg`

### Iteration 2 — Start Menu overflow

- Earlier finding [P2]: the system popover could extend beyond the left edge of the app window at the reference viewport.
- Fix: replaced the Start Menu popover with an animated, in-window bottom-leading panel, added outside-click dismissal, and preserved keyboard focus and real shortcut actions.
- Post-fix evidence: `artifacts/design-qa/session-stage-start-menu.jpg`

### Iteration 3 — icon and dock polish

- Earlier finding [P2]: unresolved executable icons degraded into blank generic file tiles, and a horizontal scroll indicator appeared beneath the dock.
- Fix: kept extracted executable icons when available, added semantic colored SF Symbol fallbacks, and explicitly disabled dock and Start Menu scroll indicators.
- Post-fix evidence: `artifacts/design-qa/session-stage-active-final.jpg` and `artifacts/design-qa/session-stage-comparison-focus.jpg`

### Iteration 4 — localized interface copy

- Earlier finding [P2]: new session-stage controls fell back to English in a Korean app session.
- Fix: added 28 strings to the localization catalog, regenerated all nine translated `Localizable.strings` files, and validated the complete catalog.
- Post-fix verification: `./script/validate_localizations.py` passes for 788 strings across 10 supported locales.
- Residual capture gap: the post-localization Computer Use recapture was unavailable because the macOS accessibility service timed out. The visual layout evidence predates only the string-table update; the rebuilt app and generated catalogs validate the shipped localized values.

### Iteration 5 — session edge states

- Earlier finding [P2]: an active session without a visible captured window could look idle and clicking its fallback card could relaunch the configured app. Submitting an empty command search could also launch the first installed app.
- Fix: active fallback cards now show the running/live-preview-unavailable state and open Activity; empty or whitespace-only search submissions do nothing. Start Menu shortcuts use the normal JobEngine/runner path so container environment, GPTK, display, font, logging, and protocol state are preserved.
- Capture note: these fixes change only fallback status copy/color and interaction behavior. The recorded geometry and visual composition remain unchanged; the final rebuilt app passed package, runner, localization, and launch verification.

### Iteration 6 — redundant process stack

- Earlier finding [P2]: the layered process stack repeated Task View's role, consumed space beside the hero window, and drew attention away from the active app.
- Fix: removed the stack and retained Task View as the single running-window overview.
- Post-fix evidence: `artifacts/design-qa/session-stage-no-process-stack.png` and `artifacts/design-qa/session-stage-no-process-stack-comparison.jpg`
- Result: the hero and secondary windows read as one calmer workspace without removing any process-management capability.

### Iteration 7 — window model and control clarity

- Earlier finding [P2]: the More control did not share the New App control's shape or label treatment.
  - Fix: both are now 39-point labeled capsules using the same button style; “More” is translated across all supported locales.
- Earlier finding [P1]: the stage mixed detected windows with installed-app fallbacks, did not identify why one window was centered, and surfaced only two secondary cards.
  - Fix: the stage now renders detected running windows only. A selector states the running-window count and selected position, supports previous/next cycling through every captured window, and opens the full list from All.
- Earlier finding [P1]: the session-summary chevron looked actionable but had no action.
  - Fix: the entire summary is now a button that opens the same Task View as the dock control, rotates its chevron while open, and exposes a distinct accessibility identifier.
- Earlier finding [P2]: a 6-point green dot did not make running dock apps obvious.
  - Fix: running apps now receive a green icon ring, corner badge, and localized Running label.
- Performance safeguard: every detected window keeps its lightweight metadata and remains listed, while live image capture stays bounded to the first six windows plus the selected window. Existing window IDs retain their display order across refreshes so the selected position does not jump when focus changes.
- Interaction evidence: Next changed the selected counter from 1 / 4 to 2 / 4; the summary button opened Task View with all four windows and a separate Processes section; selecting the fourth row closed the popover and changed the counter to 4 / 4.
- Review resolution: removed the metadata cap behind All, added a stable-order regression test, prevented duplicate VoiceOver status announcements, and removed the repeated Task View window-count heading.
- Post-fix evidence: `artifacts/design-qa/session-stage-window-navigation-final.png`, `artifacts/design-qa/session-stage-task-view-final.png`, and `artifacts/design-qa/session-stage-feedback-comparison.jpg`

## Implementation Checklist

- [x] Match the reference viewport and dark stage composition.
- [x] Keep Start Menu inside the window and populate it from real Windows shortcuts.
- [x] Provide dock launch actions, Task View, search, app install/run, and Windows Desktop fallback.
- [x] Keep process/window overview consolidated in Task View without a duplicate stage stack.
- [x] Show only detected running windows in the stage and make every captured window reachable.
- [x] Make the window count, selected position, previous/next controls, and full-list entry explicit.
- [x] Make the session summary and chevron open Task View.
- [x] Make running app state visible without relying on a tiny dot.
- [x] Use the power symbol for ending the Windows session, with confirmation and disabled idle state.
- [x] Prefer real executable and live-window imagery, with polished semantic fallbacks.
- [x] Respect Reduce Motion and keep repeated monitoring/capture work bounded.
- [x] Localize new interface copy and validate generated localization files.

final result: passed
