# Privacy And Logs

Switchyard collects local diagnostic logs to help users understand failed launches.

## Rules

- Logs remain local by default.
- Export requires explicit user action.
- Diagnostic bundles should redact obvious secrets, tokens, and private account identifiers before sharing.
- Full absolute paths may reveal usernames. UI should warn before exporting bundles.
- Launcher logs may contain account-specific state. Do not upload automatically.

## V1 Diagnostic Bundle

The initial bundle includes:

- runtime status
- diagnostic checks
- recent app log lines

Future bundles may include runner stdout/stderr, Wine version metadata, patchset metadata, and bottle manifests.
