#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

python3 - "$WORKFLOW" <<'PY'
from pathlib import Path
import re
import sys

workflow_path = Path(sys.argv[1])
workflow = workflow_path.read_text(encoding="utf-8")


def fail(message: str) -> None:
    raise SystemExit(f"release workflow credential-order policy failed: {message}")


def require_once(text: str, needle: str, context: str) -> int:
    count = text.count(needle)
    if count != 1:
        fail(f"{context} must occur exactly once (found {count})")
    return text.index(needle)


jobs_offset = workflow.find("\njobs:\n")
if jobs_offset < 0:
    fail("workflow does not define jobs")
jobs_document = workflow[jobs_offset + 1:]
job_matches = list(re.finditer(r"(?m)^  ([a-zA-Z0-9_-]+):\n", jobs_document))
jobs: dict[str, str] = {}
for index, match in enumerate(job_matches):
    end = (
        job_matches[index + 1].start()
        if index + 1 < len(job_matches)
        else len(jobs_document)
    )
    jobs[match.group(1)] = jobs_document[match.start():end]

if set(jobs) != {"validate", "release"}:
    fail(f"expected only validate and release jobs, found {sorted(jobs)}")

validate = jobs["validate"]
release = jobs["release"]

if re.search(r"\bsecrets(?:\.|\[)", validate):
    fail("validate job must not reference release secrets")
for forbidden in ("${{ github.token }}", "GH_TOKEN:"):
    if forbidden in validate:
        fail(f"validate job must not reference an explicit credential: {forbidden}")
for required in (
    "permissions:\n      contents: read",
    "- name: Validate immutable release input",
    "swift package resolve",
    "swift test --jobs",
    "swift build --product switchyard-runner",
    "Tests/Shell/create_dmg_test.sh",
    "Tests/Shell/generate_appcast_test.sh",
    "Tests/Shell/runner_protocol_callback_test.sh",
    "Tests/Shell/runner_desktop_shortcut_test.sh",
    "Tests/Shell/runner_partial_log_buffer_test.sh",
    "Tests/Shell/release_workflow_credential_order_test.sh",
):
    if required not in validate:
        fail(f"validate job is missing required credential-free validation: {required}")

if not re.search(r"(?m)^    needs: validate$", release):
    fail("release job must depend on the validate job")
if "${{ needs.validate.outputs.commit_sha }}" not in release:
    fail("release job must compare its checkout with the validated commit SHA")

checkout = require_once(release, "- name: Check out release tag", "release checkout")
revalidate = require_once(
    release,
    "- name: Revalidate release tag and commit",
    "release commit revalidation",
)
build = require_once(
    release,
    "- name: Build release app without release credentials",
    "credential-free release build",
)
apple_import = require_once(
    release,
    "- name: Import Developer ID and notarization credentials",
    "Apple credential import",
)
sparkle_validation = require_once(
    release,
    "- name: Validate Sparkle signing credential",
    "Sparkle credential validation",
)
signing = require_once(
    release,
    "- name: Sign and notarize release DMG",
    "release signing",
)

if not checkout < revalidate < build < apple_import < sparkle_validation < signing:
    fail("checkout, commit revalidation, build, and credential steps are out of order")
if 'SWITCHYARD_CODESIGN_IDENTITY: "-"' not in release[build:apple_import]:
    fail("release app validation build must use explicit ad-hoc signing")

first_secret_match = re.search(r"\bsecrets(?:\.|\[)", release)
if first_secret_match is None:
    fail("release job does not reference release secrets")
if first_secret_match.start() < apple_import:
    fail("a release secret is referenced before source revalidation and build complete")

apple_step = release[apple_import:sparkle_validation]
certificate_create = require_once(
    apple_step,
    '''printf '%s' "$CERTIFICATE_BASE64" | base64 --decode > "$certificate_path"''',
    "certificate materialization",
)
certificate_import = require_once(
    apple_step,
    'security import "$certificate_path"',
    "certificate import",
)
certificate_remove = apple_step.find('rm -f "$certificate_path"', certificate_import)
notary_create = require_once(
    apple_step,
    '''printf '%s' "$NOTARY_KEY_BASE64" | base64 --decode > "$notary_key_path"''',
    "notary key materialization",
)
notary_store = require_once(
    apple_step,
    "xcrun notarytool store-credentials",
    "notary credential storage",
)
notary_remove = apple_step.find('rm -f "$notary_key_path"', notary_store)
if certificate_remove < 0 or notary_remove < 0:
    fail("raw Apple credentials must be removed after import or storage")
if not (
    certificate_create
    < certificate_import
    < certificate_remove
    < notary_create
    < notary_store
    < notary_remove
):
    fail("raw Apple credentials are not materialized and removed just in time")

sparkle_step = release[sparkle_validation:signing]
sparkle_create = require_once(
    sparkle_step,
    '''printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$sparkle_private_key"''',
    "Sparkle key materialization",
)
sparkle_import = sparkle_step.find(
    '            -f "$sparkle_private_key" >/dev/null',
    sparkle_create,
)
sparkle_remove = sparkle_step.find('rm -f "$sparkle_private_key"', sparkle_import)
if sparkle_import < 0 or sparkle_remove < 0:
    fail("raw Sparkle credential must be removed immediately after validation")
if not sparkle_create < sparkle_import < sparkle_remove:
    fail("raw Sparkle credential is not materialized and removed just in time")

for required in (
    "trap cleanup_raw_apple_credentials EXIT",
    "trap cleanup_raw_sparkle_credential EXIT",
    "- name: Remove temporary credentials\n        if: always()",
    'security delete-keychain "$KEYCHAIN_PATH"',
    "$RUNNER_TEMP/developer-id-application.p12",
    "$RUNNER_TEMP/AuthKey.p8",
    "$RUNNER_TEMP/sparkle-private-key",
):
    if required not in release:
        fail(f"release cleanup policy is missing: {required}")

print("release workflow credential-order policy passed")
PY
