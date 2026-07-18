# Architecture

Switchyard separates UI, portable planning logic, process execution, and third-party runtime code so each boundary can be tested and licensed independently.

```mermaid
flowchart LR
    UI["SwiftUI app"] --> Packages["Portable Swift packages"]
    UI --> Runner["switchyard-runner"]
    Packages --> Plan["CommandPlan"]
    Plan --> Runner
    Pin["Immutable Wine source pin"] --> Catalog["RuntimeCatalog"]
    Catalog --> UI
    GPTK["User-provided GPTK"] --> Catalog
    Runner --> Wine["Replaceable Wine runtime"]
    Wine --> Container["User-managed container"]
    Container --> Manifest["Registered URL scheme manifest"]
    Manifest --> Bridge["Dynamic macOS URL handler"]
    Bridge --> Runner
```

## Components

### App Shell

`app/Switchyard` owns scenes, views, platform dialogs, preferences, and orchestration state. Views call `AppStore`; they do not execute shell commands directly.

### Core Packages

- `AppCore`: portable models, command plans, and path/environment policies
- `JobEngine`: generic install and run planning plus font preparation
- `Persistence`: portable container manifests and rebuildable indexes
- `RuntimeCatalog`: macOS host checks, GPTK disk-image inspection, Wine discovery, source-pin validation, and font compatibility rules

These packages do not own SwiftUI state. `RuntimeCatalog` may invoke narrow macOS host tools such as `hdiutil`; it does not launch Wine or Windows workloads.

### Runner

`runtime/runner` is the only boundary that executes Wine and Windows workloads. It accepts a serialized `CommandPlan`, constructs an explicit process environment, streams output, handles cancellation, and returns the child status. Application-specific compatibility behavior belongs in the runtime source, not in the runner.

The runner also accepts protected URL callback request files from the bundled `switchyard-url-handler` helper. It validates the requested scheme and prefix, deletes the request file before launch, and delivers the unchanged URL through `wine start` in that prefix. Callback URLs never appear in runner command-line arguments or Switchyard logs.

### Browser Login Callback Bridge

Wine exports the custom protocols registered in each prefix to a small versioned manifest. The runner starts one Wine-side registry monitor per active prefix, so direct changes under the user or machine `Software\Classes` keys refresh the manifest even when an application does not send a shell association notification. The app watches those manifests and generates one lightweight LaunchServices proxy bundle per scheme. No launcher or game scheme is hardcoded. Standard host schemes such as `http`, `https`, and `file` are rejected, and Switchyard does not replace a handler already owned by another native app.

When Safari or another macOS browser opens a callback, the proxy selects the most recently activated container that registered the scheme and hands a protected one-shot request to `switchyard-runner`. The runner synchronizes that scheme's per-user registration into Wine's class root before calling `wine start`, compensating for Wine's incomplete `HKCU\Software\Classes` merge. This keeps macOS registration and app lifecycle policy in the app repository while the Windows registry enumeration remains in the Wine runtime repository.

Some launchers do not register their callback scheme at all. For that case, the selected container offers an explicit recovery action: the user copies Safari's rejected callback URL, and Switchyard inspects the container's running Windows processes. It rejects Wine infrastructure and helper processes, proceeds automatically for a single application target, and asks the user to choose when several remain. Executables on any canonical Wine DOS drive mapping are eligible. The first callback is sent directly to the selected executable; only after Wine accepts it is the learned scheme-to-executable association stored per container, registered under the Wine user's protocol classes, and reused by the macOS proxy for later callbacks. Existing Wine protocol commands are never overwritten. The callback itself still travels only through a mode-0600 one-shot request file; its URL and sign-in token are neither persisted in the learned association nor included in Switchyard's logs or its helper command lines.

### Runtime Source

Wine source, compatibility commits, provenance, and runtime build tooling live in [`switchyard-wine`](https://github.com/jungwuk-ryu/switchyard-wine). `config/switchyard-wine.env` pins an exact source commit. `script/ensure_wine_runtime.sh` synchronizes that commit into a user cache, verifies its source metadata, and hands off to the source-owned builder.

The app presents the pinned source revision's immutable Git timestamp as a UTC calendar build number in `YYYYMMDD.HHmm` form so users can compare compatible runtime versions at a glance. `config/switchyard-wine.env` records that timestamp beside the revision, and source synchronization verifies the pair before building. Local source overrides omit the pinned timestamp rather than inheriting stale version metadata. This display value does not replace provenance: runtime IDs, immutable source revisions, and content fingerprints remain the authoritative compatibility and execution identities.

GPTK remains user-provided local software. The app stores only a selected path, imported user-local copy, and compatibility fingerprint. It is never part of this repository or a Switchyard release artifact.

## Data Model

Each container has a portable JSON manifest. The manifest is the source of truth and records the Wine build, source identity, GPTK fingerprint, executable, environment overrides, schema version, and last-run status. Any future database must be a rebuildable index rather than the sole copy of container state.

The current preview launches through the globally selected compatible runtime. Enforcing the recorded per-container runtime, creating migration candidates, and preserving rollback metadata are planned work described by ADR 0003; they are not implemented yet.

## Decisions

- [ADR 0001: Runtime boundaries](adr/0001-runtime-boundaries.md)
- [ADR 0002: Container data model](adr/0002-container-data-model.md)
- [ADR 0003: Runtime update model](adr/0003-runtime-update-model.md)
