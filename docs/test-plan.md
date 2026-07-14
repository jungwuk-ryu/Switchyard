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
- Runtime A container remains pinned after runtime B appears.
- Failed migration preserves rollback metadata.
- Pinned `switchyard-wine` source synchronization is serialized and hands off to source-owned verification and build tooling.

## App Verification

Run:

```sh
swift test
./script/build_and_run.sh --verify
```

The verification script must build the app, stage `dist/Switchyard.app`, launch it, and confirm the `Switchyard` process exists.
