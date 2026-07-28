# Session Stage Design QA

## Comparison Target

- Source visual truth: `/var/folders/pz/7mc4qx917vj4lny57kwm4pnh0000gn/T/codex-clipboard-cc397319-5ac9-4788-ad0d-6a1155891f2f.png`
- Implementation screenshot: `artifacts/design-qa/session-stage-active-final.jpg`
- Full-view comparison: `artifacts/design-qa/session-stage-comparison-full.jpg`
- Focused comparison: `artifacts/design-qa/session-stage-comparison-focus.jpg`
- Viewport: native macOS window at 1487 × 1058 points
- Source pixels: 1487 × 1058
- Implementation capture pixels: 1080 × 768, downsampled by the Computer Use capture service from the 1487 × 1058 native window
- Density normalization: the source was downsampled to 1080 × 768 before comparison; the native window frame and source therefore share the same aspect ratio and logical viewport
- CSS size / device scale factor: not applicable to this native SwiftUI app
- State: dark appearance, active Windows session, Start Menu open, installed apps visible, process stack visible, bottom dock visible
- Data note: the source shows a Rockstar container while the implementation evidence uses installed Steam-container data. Product data and live window imagery are intentionally dynamic; the interaction state and layout are matched.

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

## Required Fidelity Surfaces

- Fonts and typography: both designs use the native macOS system family. Heading, label, and utility text weights preserve the source hierarchy; dock labels use bounded two-line truncation.
- Spacing and layout rhythm: header, hero card, secondary cards, process stack, Start Menu, and dock retain the source grouping at the same logical viewport. Start Menu and dock remain inside the window bounds.
- Colors and visual tokens: dark navy backdrop, translucent charcoal surfaces, blue focus glow, green running state, and destructive red hover map to the source palette with sufficient contrast.
- Image quality and asset fidelity: extracted executable icons are preferred. When extraction fails, the implementation uses semantic SF Symbols rather than fake logos or copied artwork. Live Wine windows use ScreenCaptureKit images when available.
- Copy and content: labels are concise and task-focused. Twenty-seven session-stage strings were added across all nine translated locales; Korean uses terms such as “시작 메뉴,” “앱 추가,” “작업 보기,” and “Windows 세션 종료.”
- Icons: controls use a consistent SF Symbols family. Start Menu uses the requested 3 × 3 grid and session stop uses the requested power symbol.
- Accessibility and motion: semantic buttons and labels are present, the destructive action requires confirmation, idle stop is disabled, keyboard search supports Command-K, and transitions respect Reduce Motion.

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
- Fix: added 27 strings to the localization catalog, regenerated all nine translated `Localizable.strings` files, and validated the complete catalog.
- Post-fix verification: `./script/validate_localizations.py` passes for 787 strings across 10 supported locales.
- Residual capture gap: the post-localization Computer Use recapture was unavailable because the macOS accessibility service timed out. The visual layout evidence predates only the string-table update; the rebuilt app and generated catalogs validate the shipped localized values.

### Iteration 5 — session edge states

- Earlier finding [P2]: an active session without a visible captured window could look idle and clicking its fallback card could relaunch the configured app. Submitting an empty command search could also launch the first installed app.
- Fix: active fallback cards now show the running/live-preview-unavailable state and open Activity; empty or whitespace-only search submissions do nothing. Start Menu shortcuts use the normal JobEngine/runner path so container environment, GPTK, display, font, logging, and protocol state are preserved.
- Capture note: these fixes change only fallback status copy/color and interaction behavior. The recorded geometry and visual composition remain unchanged; the final rebuilt app passed package, runner, localization, and launch verification.

## Implementation Checklist

- [x] Match the reference viewport and dark stage composition.
- [x] Keep Start Menu inside the window and populate it from real Windows shortcuts.
- [x] Provide dock launch actions, Task View, search, app install/run, and Windows Desktop fallback.
- [x] Use the power symbol for ending the Windows session, with confirmation and disabled idle state.
- [x] Prefer real executable and live-window imagery, with polished semantic fallbacks.
- [x] Respect Reduce Motion and keep repeated monitoring/capture work bounded.
- [x] Localize new interface copy and validate generated localization files.

final result: passed
