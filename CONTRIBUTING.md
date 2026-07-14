# Contributing to Switchyard

Switchyard is an early developer preview. Focused bug reports, compatibility evidence, tests, and small implementation improvements are welcome.

## Before You Start

- Use [GitHub Security Advisories](SECURITY.md) for vulnerabilities, not a public issue.
- Keep Wine source changes in [`switchyard-wine`](https://github.com/jungwuk-ryu/switchyard-wine).
- Do not submit Apple Game Porting Toolkit files, proprietary Windows files or fonts, credentials, container data, or unredacted logs.
- Search existing issues before opening a new report.

## Development Setup

You need an Apple Silicon Mac running macOS 14 or later and Xcode Command Line Tools with Swift 6. The fast validation path does not download or build Wine:

```sh
swift test
Tests/Shell/ensure_switchyard_wine_test.sh
Tests/Shell/runner_prefix_session_test.sh
SWITCHYARD_SKIP_RUNTIME_ENSURE=1 ./script/build_and_run.sh --verify
```

See [Development](docs/development.md) for full-runtime setup and generated-data locations.

## Change Boundaries

- Keep shell execution out of SwiftUI views.
- Keep application-specific compatibility behavior out of the generic runner.
- Keep UI state out of the portable packages under `app/Packages`.
- Preserve the external Wine process boundary and immutable source pin.
- Treat GPTK as user-provided local software; never add it to source or release artifacts.

Add or update tests for behavior changes. Use Conventional Commit subjects such as `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `build:`, or `chore:`.

By submitting a contribution, you agree that it may be distributed under the repository's [MIT License](LICENSE). Wine contributions remain under the licensing terms documented by `switchyard-wine`.
