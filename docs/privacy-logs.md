# Privacy and Logs

Switchyard collects local diagnostic logs to help users understand failed launches.

## Rules

- Logs remain local by default.
- Copying logs or a diagnostic bundle requires explicit user confirmation.
- Clipboard output redacts common secret patterns and replaces the current home directory with `~`.
- Redaction is a safety aid, not a guarantee. Users should review copied text before sharing it.
- Full absolute paths may reveal usernames. The UI warns before copying diagnostic data.
- Container run logs may contain account-specific state. Do not upload automatically.
- Browser-login callback URLs and their query or fragment tokens are never written to Switchyard logs.

## Current Diagnostic Bundle

The current bundle includes:

- runtime status
- diagnostic checks
- recent app log lines, including runner stdout and stderr already streamed into the app

Runner and Wine output can contain application-specific or account-specific text. Review copied diagnostic data even after automated redaction. Future bundles may add Wine version metadata, patchset metadata, and container manifests.

Developer logging is opt-in. Per-run files are stored with account-only permissions under `~/Library/Application Support/Switchyard/Logs/DebugRuns` and omit argument values from runner metadata. The default policy keeps files for 14 days and caps storage at 50 files; both limits can be changed in Settings > Logs. Pruning runs when Switchyard starts, when the policy changes, and before a new debug log is created. Stopping `wineserver` does not delete logs.

The Logs screen keeps only the latest 5,000 entries in memory. Clearing that screen does not delete per-run debug files, and deleting stored debug files does not clear the current in-memory view.

Custom URL callbacks are transferred through an account-only request file under `~/Library/Application Support/Switchyard/ProtocolBridge/Requests`. The runner reads and deletes that file before invoking Wine. The full callback URL is not placed on the helper or runner command line.
