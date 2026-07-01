# Switchyard

Switchyard is an open-source-core macOS compatibility manager for running Windows game launchers on Apple Silicon.

The v1 target is intentionally narrow:

- Steam
- Epic Games Launcher
- GOG Galaxy

Switchyard uses a patched Wine runtime and links to a user-provided Apple Game Porting Toolkit installation. It does not bundle GPTK or Apple binaries.

## Current State

This repository contains the initial product, architecture, and runnable macOS app scaffold:

- SwiftUI macOS app shell
- Navigation split layout for Library, Operations, Logs, and Diagnostics
- Runtime detection model for Apple Silicon, macOS, GPTK, and Wine
- Declarative launcher command plans
- External runner CLI boundary for process execution
- Wine patch queue and licensing documentation structure

## Build And Run

```sh
swift test
./script/build_and_run.sh --verify
```

The Codex Run action is wired to:

```sh
./script/build_and_run.sh
```

## Runtime Policy

- Wine is tracked as a pinned submodule at `third_party/wine`.
- Switchyard Wine patches live in `patches/wine`.
- GPTK is imported from a user-selected local path and fingerprinted.
- Bottles pin runtime IDs so runtime updates do not mutate working installs.
