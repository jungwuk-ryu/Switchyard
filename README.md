# Switchyard

Switchyard is an open-source-core macOS compatibility manager for running Windows executables in user-managed Wine containers on Apple Silicon.

The first compatibility workloads are:

- Steam
- Epic Games Launcher
- GOG Galaxy

These are validation targets, not fixed container types. Users should be able to create Wine-style containers freely and choose the executable they want to run.

Switchyard uses a patched Wine runtime and can integrate components from a user-selected local Apple Game Porting Toolkit installation. It does not bundle GPTK or Apple binaries.

## Current State

This repository contains the initial product, architecture, and runnable macOS app scaffold:

- SwiftUI macOS app shell
- Navigation split layout for Containers, Operations, Logs, and Diagnostics
- Runtime detection model for Apple Silicon, macOS, GPTK, and Wine
- User-local Open Font Pack setup for Wine container font fallback
- Generic container command plans
- External runner CLI boundary for process execution
- Pinned external Switchyard Wine source and runtime-manifest validation

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

- Wine source and compatibility commits live in the public [`switchyard-wine`](https://github.com/jungwuk-ryu/switchyard-wine) repository.
- `config/switchyard-wine.env` pins the exact source revision used by this app.
- Local development synchronizes that revision into a user cache and builds an immutable runtime outside the app repository.
- GPTK is imported from a user-selected local path and fingerprinted.
- Open Noto fonts are downloaded to a user-local cache and installed into containers; Switchyard does not bundle Microsoft Windows fonts.
- Containers pin runtime IDs so runtime updates do not mutate working installs.
