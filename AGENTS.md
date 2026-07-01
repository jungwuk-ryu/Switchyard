# Switchyard Agent Rules

Switchyard is an open-source-core macOS compatibility manager for running Windows game launchers on Apple Silicon. The project uses a patched Wine runtime and user-provided Apple Game Porting Toolkit components. Keep the licensing and runtime boundaries explicit.

## Non-trivial Work Gate

For every non-trivial change:

1. Run the relevant build or test command.
2. Ask exactly one sub-agent for a code review before committing.
3. Address or explicitly document review findings.
4. Commit with a Conventional Commit message.

If sub-agents are unavailable, do not silently skip the gate. Record the blocker in the final work summary and avoid committing unless the user explicitly directs otherwise.

## Commit Policy

Use Conventional Commits:

- `feat: ...`
- `fix: ...`
- `docs: ...`
- `test: ...`
- `refactor: ...`
- `build: ...`
- `chore: ...`

Keep commits focused. Do not mix Wine patch changes, app UI changes, and documentation rewrites unless the change is intentionally atomic.

## Build And Verification

Use the project-local entrypoint:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --debug
```

For macOS app changes, run `./script/build_and_run.sh --verify` or explain why it could not run.

For package-level logic changes, run `swift test`.

## Runtime And Licensing Boundaries

- Do not link the SwiftUI app directly against Wine.
- Run Wine through the external runner boundary.
- Do not add Apple GPTK binaries under `third_party/` or commit them anywhere.
- GPTK must be user-selected, locally fingerprinted, and treated as user-provided software.
- Wine source lives in `third_party/wine` as a pinned submodule.
- Switchyard patches live in `patches/wine` as an ordered patch queue.
- Any `patches/wine` change must update patch provenance, rationale, upstream status, and build/test notes.
- LGPL obligations for Wine changes must stay documented in `docs/licensing.md`.

## Architecture Rules

- `app/Switchyard`: SwiftUI shell, scenes, views, app state, and platform glue.
- `app/Packages/AppCore`: pure models and portable value types.
- `app/Packages/JobEngine`: install/run/repair/log state machines.
- `app/Packages/LauncherAdapters`: declarative Steam/Epic/GOG command plans.
- `app/Packages/RuntimeCatalog`: Wine/GPTK detection and compatibility rules.
- `app/Packages/Persistence`: portable bottle manifests and indexing/cache code.
- `runtime/runner`: process execution, environment construction, log streaming, cancellation.
- `runtime/build`: reproducible Wine build and artifact manifest scripts.

Keep shell execution out of SwiftUI views. Keep launcher quirks out of the runner. Keep UI state out of portable packages.
