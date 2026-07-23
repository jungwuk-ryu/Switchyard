# Switchyard Agent Rules

Switchyard is an open-source-core macOS compatibility manager for running Windows game launchers on Apple Silicon. The project uses a patched Wine runtime and separately licensed Apple Game Porting Toolkit components. Keep the licensing and runtime boundaries explicit.

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

Keep commits focused. Do not mix external Wine source changes, app UI changes, and documentation rewrites unless the change is intentionally atomic.

## Release Notes

Write GitHub release bodies as concise, reader-facing changelogs:

- Describe only the features, fixes, and behavior changes introduced since the previous release.
- Prefer a single `## What's Changed` section with clear bullets. Add subsections only when a release has enough distinct changes to justify them.
- Base every claim on the tag-to-tag diff, and end with a `Full Changelog` comparison link when a previous tag exists.
- Do not repeat the release title or add generic preview prose.
- Omit routine download instructions, system requirements, signing, notarization, stapling, Gatekeeper, checksum, notarization ID, and standing licensing or runtime-boundary boilerplate.
- Mention distribution, security, compatibility, licensing, or runtime details only when that item changed in the release or requires a new user action. Keep the separately licensed GPTK and external Wine runtime boundaries accurate whenever they are relevant to a listed change.

## Build And Verification

Leave one CPU core free for local builds unless the user explicitly asks for maximum parallelism. For scripts that expose job counts, use `max(1, hw.ncpu - 1)` as the default.

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

## Workspace Cleanup

After finishing a task, clean up generated files that are safe to remove so Switchyard data directories do not accumulate old test artifacts. Prefer deleting stale build/test outputs, validation prefixes, obsolete local Wine runtimes, logs, downloads, and caches when they are not referenced by current app state and no running process is using them.

Do not remove user-managed containers, installed games, user-selected GPTK components, active runtimes, or any data whose ownership is unclear. If cleanup would be risky or materially change user state, leave it in place and mention the remaining cleanup opportunity in the final summary.

## Runtime And Licensing Boundaries

- Do not link the SwiftUI app directly against Wine.
- Run Wine through the external runner boundary.
- Do not add Apple GPTK binaries under `third_party/` or commit them anywhere.
- GPTK may come from a user-selected Apple download or a separate version-reviewed component channel, but it must always be locally fingerprinted and treated as separately licensed Apple software.
- A GPTK component channel must satisfy every control in `docs/legal/gptk-3-redistribution-review.md`; unreviewed versions and commercial distribution stay disabled.
- Never add GPTK to the app bundle, Wine runtime, container template, source repository, or combined release archive.
- Wine source, compatibility commits, provenance, and runtime build tooling live in the separate public `switchyard-wine` repository.
- This repository pins an immutable source commit in `config/switchyard-wine.env` and synchronizes it through `script/ensure_wine_runtime.sh`.
- Wine source changes must be developed and reviewed in `switchyard-wine`; do not recreate a local patch queue or Wine submodule here.
- LGPL obligations for Wine changes must stay documented in `docs/licensing.md`.

## Architecture Rules

- `app/Switchyard`: SwiftUI shell, scenes, views, app state, and platform glue.
- `app/Packages/AppCore`: pure models and portable value types.
- `app/Packages/JobEngine`: generic container install/run/repair/log state machines.
- `app/Packages/RuntimeCatalog`: Wine/GPTK detection and compatibility rules.
- `app/Packages/Persistence`: portable container manifests and indexing/cache code.
- `runtime/runner`: process execution, environment construction, log streaming, cancellation.
- `script/ensure_wine_runtime.sh`: pinned external Wine source synchronization and runtime build handoff.

Keep shell execution out of SwiftUI views. Keep executable-specific quirks out of the runner. Keep UI state out of portable packages.
