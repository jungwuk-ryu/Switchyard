# Test Plan

## Unit Tests

- Runtime detection with missing GPTK.
- Runtime detection with marker files.
- Missing patch series prevents launch readiness.
- Steam, Epic Games Launcher, and GOG Galaxy command plan generation.
- Missing launcher executable failure.
- Container manifest JSON round trip.

## Integration Tests

- Fake GPTK import.
- Create launcher container.
- Generate install and run command plans.
- Runner helper accepts serialized command plans and emits logs and exit code.
- Runtime A container remains pinned after runtime B appears.
- Failed migration preserves rollback metadata.

## App Verification

Run:

```sh
swift test
./script/build_and_run.sh --verify
```

The verification script must build the app, stage `dist/Switchyard.app`, launch it, and confirm the `Switchyard` process exists.
