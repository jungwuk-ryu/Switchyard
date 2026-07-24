# Development

## Prerequisites

- Apple Silicon Mac with macOS 14 or later
- Xcode Command Line Tools with Swift 6
- Git
- Rosetta 2 and the prerequisites documented by [`switchyard-wine`](https://github.com/jungwuk-ryu/switchyard-wine) for a full local runtime build

A user-selected local Apple Game Porting Toolkit installation is required for full D3DMetal readiness while the reviewed component channel remains release-disabled. It is not required for package tests or an app-shell verification build.

## Fast Validation

Leave one CPU core free for local Swift builds:

```sh
jobs=$(( $(sysctl -n hw.ncpu) - 1 ))
if [ "$jobs" -lt 1 ]; then jobs=1; fi
swift test --jobs "$jobs"
Tests/Shell/ensure_switchyard_wine_test.sh
Tests/Shell/bundle_gptk_component_policy_test.sh
SWIFT_BUILD_JOBS="$jobs" Tests/Shell/runner_prefix_session_test.sh
SWITCHYARD_SKIP_RUNTIME_ENSURE=1 SWIFT_BUILD_JOBS="$jobs" ./script/build_and_run.sh --verify
```

The last command assembles an ad-hoc signed `dist/Switchyard.app`, launches it, verifies that the process starts, and closes the verified instance. It does not synchronize or build Wine.

The published-runtime integration test is opt-in because it downloads the complete release archive. It can only run after all `SWITCHYARD_WINE_RELEASE_*` attestation values for the pinned revision have been published in `config/switchyard-wine.env`; otherwise the test intentionally returns without downloading anything:

```sh
SWITCHYARD_TEST_RUNTIME_RELEASE_MANIFEST_URL="$(awk -F= '/^SWITCHYARD_WINE_RELEASE_MANIFEST_URL=/{print $2}' config/switchyard-wine.env)" \
SWITCHYARD_TEST_RUNTIME_SOURCE_REVISION="$(awk -F= '/^SWITCHYARD_WINE_REVISION=/{print $2}' config/switchyard-wine.env)" \
SWITCHYARD_TEST_RUNTIME_DEVELOPER_TEAM_ID="$(awk -F= '/^SWITCHYARD_WINE_DEVELOPER_TEAM_ID=/{print $2}' config/switchyard-wine.env)" \
SWITCHYARD_TEST_RUNTIME_ARCHIVE_SHA256="$(awk -F= '/^SWITCHYARD_WINE_RELEASE_ARCHIVE_SHA256=/{print $2}' config/switchyard-wine.env)" \
SWITCHYARD_TEST_RUNTIME_ARCHIVE_SIZE="$(awk -F= '/^SWITCHYARD_WINE_RELEASE_ARCHIVE_SIZE=/{print $2}' config/switchyard-wine.env)" \
SWITCHYARD_TEST_RUNTIME_NOTARIZATION_ID="$(awk -F= '/^SWITCHYARD_WINE_RELEASE_NOTARIZATION_ID=/{print $2}' config/switchyard-wine.env)" \
swift test --filter publishedRuntimeCanBeInstalledWhenProvided
```

## Full Local Run

```sh
./script/build_and_run.sh
```

The entrypoint synchronizes the exact Wine commit in `config/switchyard-wine.env`, verifies the source checkout, ensures its immutable user-local runtime, builds the Swift app and runner, assembles the app bundle, and launches it.

To assemble the app against an already-built local Wine commit before updating the published source pin, pass the same revision used by that runtime and skip synchronization:

```sh
SWITCHYARD_WINE_REVISION="$(git -C ../Switchyard-Wine rev-parse HEAD)" \
SWITCHYARD_SKIP_RUNTIME_ENSURE=1 \
./script/build_and_run.sh --verify
```

When this override differs from `config/switchyard-wine.env`, the development bundle records the local revision for runtime selection and omits the stale published-runtime attestation.

Additional modes are available for debugging and local observation:

```sh
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --verify
```

## Signed Release Packaging

First assemble an optimized release build, then create a Developer ID signed and notarized archive with a Keychain profile configured for `notarytool`:

```sh
SWITCHYARD_SKIP_RUNTIME_ENSURE=1 \
SWITCHYARD_BUILD_CONFIGURATION=release \
./script/build_and_run.sh --verify

./script/release_app.sh \
  --app dist/Switchyard.app \
  --output "$HOME/Library/Caches/Switchyard/ReleaseStaging/app-$(git rev-parse --short=12 HEAD)" \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile switchyard-notary
```

Release assembly fails unless the pinned Wine revision has a complete published-runtime attestation in `config/switchyard-wine.env`. This prevents distributing an app that cannot install its compatible runtime on a new machine.

`config/gptk-component.env` is bundled separately. Its disabled form is valid for release builds. If the channel is enabled, assembly fails unless the signed channel-status URL, immutable release-manifest URL, Ed25519 public key, distributor authority, independent legal approval, non-commercial status, export-control operation, and takedown readiness records are all identified. See [GPTK component channel](gptk-component-channel.md) for the status, manifest, and archive contract. Enabling the file without the private evidence required by the legal review is not an authorized release.

The script signs every nested Mach-O with Hardened Runtime, signs the bundle, submits the ZIP to Apple, staples and validates the accepted ticket, runs Gatekeeper assessment, then recreates the final ZIP and checksum. Credentials remain in the user's Keychain and are never written to the repository.

## Local Data

Generated and user-owned data stays out of Git:

- `.build/` and `dist/`: generated Swift and app-bundle outputs
- `~/Library/Caches/Switchyard/Sources/`: synchronized Wine source cache
- `~/.switchyard/runtimes/`: immutable local Wine runtimes
- `~/Library/Application Support/Switchyard/Runtimes/GPTK/`: imported user-provided or separately downloaded reviewed GPTK copy
- `~/Library/Application Support/Switchyard/Logs/DebugRuns/`: protected per-run debug logs
- the storage folder selected in the app: user-managed containers and manifests

Never add any of these artifacts, GPTK files, Windows applications, container contents, credentials, or raw account logs to a commit.

## Change Checklist

1. Keep changes within the boundaries in [Architecture](architecture.md).
2. Add or update Swift and shell tests for changed behavior.
3. Run the relevant fast-validation commands.
4. Review generated diffs for private paths, logs, binaries, and license-boundary violations.
5. Use a focused Conventional Commit message.
