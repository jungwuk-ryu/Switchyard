# Test Plan

## Unit Tests

- Runtime detection with missing GPTK.
- Runtime detection with marker files.
- Missing or mismatched Switchyard Wine source identity prevents launch readiness.
- Managed runtime selection prefers the clean runtime built from the pinned source revision.
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

## Planned Runtime Migration Tests

- Runtime A container remains pinned after runtime B appears.
- Failed migration preserves rollback metadata.

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

The verification script must build the app and runner, stage an ad-hoc signed `dist/Switchyard.app`, launch it, confirm the `Switchyard` process exists, and close the verified instance.
