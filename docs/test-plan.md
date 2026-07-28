# Test Plan

## Unit Tests

- Runtime detection with missing GPTK.
- Runtime detection with marker files.
- Missing or mismatched Switchyard Wine source identity prevents launch readiness.
- Managed runtime selection prefers the clean runtime built from the pinned source revision.
- Official runtime release discovery filters stable `switchyard-wine` releases and rejects untrusted manifests.
- Managed runtime deletion removes only direct, non-symlink cache entries with Switchyard runtime manifests.
- Container runtime provenance never overrides the active app-wide runtime.
- Legacy runtime identity fields migrate into last-used provenance.
- New, unknown, and previously used prefixes request the correct active-runtime preparation.
- Generic container command plan generation.
- Missing container executable failure.
- Container manifest JSON round trip.
- Legacy `bottles`, `bottleID`, and `launchers` data migrates into container manifests.

## Integration Tests

- Fake GPTK import.
- Create container.
- Generate install and run command plans.
- Runner helper accepts serialized command plans and emits logs and exit code.
- Pinned `switchyard-wine` source synchronization is serialized and hands off to source-owned verification and build tooling.

## App Verification

Run:

```sh
swift test
Tests/Shell/ensure_switchyard_wine_test.sh
Tests/Shell/runner_prefix_session_test.sh
SWITCHYARD_SKIP_RUNTIME_ENSURE=1 ./script/build_and_run.sh --verify
```

For a full local runtime verification, run:

```sh
./script/build_and_run.sh --verify
```

The verification script must build the app and runner, stage `dist/Switchyard.app`, verify its code signature, launch it, confirm the `Switchyard` process exists, and close the verified instance. It should use an available Apple Development identity so privacy grants survive rebuilds, or report its ad-hoc fallback.
