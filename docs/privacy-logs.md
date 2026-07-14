# Privacy and Logs

Switchyard collects local diagnostic logs to help users understand failed launches.

## Rules

- Logs remain local by default.
- Copying logs or a diagnostic bundle requires explicit user confirmation.
- Clipboard output redacts common secret patterns and replaces the current home directory with `~`.
- Redaction is a safety aid, not a guarantee. Users should review copied text before sharing it.
- Full absolute paths may reveal usernames. The UI warns before copying diagnostic data.
- Container run logs may contain account-specific state. Do not upload automatically.

## Current Diagnostic Bundle

The current bundle includes:

- runtime status
- diagnostic checks
- recent app log lines, including runner stdout and stderr already streamed into the app

Runner and Wine output can contain application-specific or account-specific text. Review copied diagnostic data even after automated redaction. Future bundles may add Wine version metadata, patchset metadata, and container manifests.

Developer logging is opt-in. Per-run files are stored with account-only permissions under `~/Library/Application Support/Switchyard/Logs/DebugRuns`, omit argument values from runner metadata, and are pruned by age and count.
