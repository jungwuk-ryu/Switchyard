# Development

## Prerequisites

- Apple Silicon Mac with macOS 14 or later
- Xcode Command Line Tools with Swift 6
- Git
- Rosetta 2 and the prerequisites documented by [`switchyard-wine`](https://github.com/jungwuk-ryu/switchyard-wine) for a full local runtime build

A user-selected local Apple Game Porting Toolkit installation is required for full D3DMetal readiness. It is not required for package tests or an app-shell verification build.

## Fast Validation

Leave one CPU core free for local Swift builds:

```sh
jobs=$(( $(sysctl -n hw.ncpu) - 1 ))
if [ "$jobs" -lt 1 ]; then jobs=1; fi
swift test --jobs "$jobs"
Tests/Shell/ensure_switchyard_wine_test.sh
SWIFT_BUILD_JOBS="$jobs" Tests/Shell/runner_prefix_session_test.sh
SWITCHYARD_SKIP_RUNTIME_ENSURE=1 SWIFT_BUILD_JOBS="$jobs" ./script/build_and_run.sh --verify
```

The last command assembles an ad-hoc signed `dist/Switchyard.app`, launches it, verifies that the process starts, and closes the verified instance. It does not synchronize or build Wine.

## Full Local Run

```sh
./script/build_and_run.sh
```

The entrypoint synchronizes the exact Wine commit in `config/switchyard-wine.env`, verifies the source checkout, ensures its immutable user-local runtime, builds the Swift app and runner, assembles the app bundle, and launches it.

Additional modes are available for debugging and local observation:

```sh
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
./script/build_and_run.sh --verify
```

## Local Data

Generated and user-owned data stays out of Git:

- `.build/` and `dist/`: generated Swift and app-bundle outputs
- `~/Library/Caches/Switchyard/Sources/`: synchronized Wine source cache
- `~/.switchyard/runtimes/`: immutable local Wine runtimes
- `~/Library/Application Support/Switchyard/Runtimes/GPTK/`: imported user-provided GPTK copy
- `~/Library/Application Support/Switchyard/Logs/DebugRuns/`: protected per-run debug logs
- the storage folder selected in the app: user-managed containers and manifests

Never add any of these artifacts, GPTK files, Windows applications, container contents, credentials, or raw account logs to a commit.

## Change Checklist

1. Keep changes within the boundaries in [Architecture](architecture.md).
2. Add or update Swift and shell tests for changed behavior.
3. Run the relevant fast-validation commands.
4. Review generated diffs for private paths, logs, binaries, and license-boundary violations.
5. Use a focused Conventional Commit message.
