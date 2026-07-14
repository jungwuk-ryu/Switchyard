## Summary

Describe the user-visible or architectural outcome and why the change belongs in this repository.

## Validation

- [ ] `swift test`
- [ ] `Tests/Shell/ensure_switchyard_wine_test.sh` when runtime synchronization changes
- [ ] `Tests/Shell/runner_prefix_session_test.sh` when runner behavior changes
- [ ] `SWITCHYARD_SKIP_RUNTIME_ENSURE=1 ./script/build_and_run.sh --verify` for app changes

## Boundary and privacy checks

- [ ] No GPTK, Apple, Windows application, proprietary font, container, runtime, log, credential, or generated build file is included.
- [ ] Wine source changes are in `switchyard-wine`; this repository only updates an immutable source pin when appropriate.
- [ ] New logging avoids argument values and other likely secrets, or documents why they are required.
- [ ] Documentation and tests reflect the final behavior.
