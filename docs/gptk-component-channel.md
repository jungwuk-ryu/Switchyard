# GPTK 3 Component Channel

Switchyard implements a separately hosted, non-commercial GPTK 3 component channel behind a release-disabled policy. This document describes the engineering contract only; it does not authorize publishing Apple software. Every control and independent approval in the [GPTK 3 redistribution review](legal/gptk-3-redistribution-review.md) must be complete before `SWITCHYARD_GPTK_CHANNEL_ENABLED` can be set to `1`.

## Release Boundary

- The app, Wine runtime, repository, container templates, and combined release archives contain no GPTK files.
- The host publishes only the complete unmodified `D3DMetal.framework` and/or an unmodified `/redist` subset admitted by the reviewed license, plus the exact accompanying license and required notices.
- The Apple-provided outer and evaluation disk images are never published.
- The official Apple download/import flow remains available.
- GPTK 4 and every source identity other than the reviewed GPTK 3.0 artifacts are rejected in code.

`config/gptk-component.env` contains only the channel gate, immutable manifest location, Ed25519 public key, and identifiers for private approval and operational records. Credentials, legal records, Apple account details, and GPTK data do not belong in the repository or app bundle.

## Signed Manifest

The host places these immutable files in one release directory:

- `gptk-component-release.json`
- `gptk-component-release.json.sig`, containing either the raw 64-byte Ed25519 signature or its Base64 encoding
- `License.rtf`, the exact reviewed license shown before the archive download
- the archive named by the manifest

The signature covers the exact JSON bytes. Do not reformat the manifest after signing. The schema is:

```json
{
  "schemaVersion": 1,
  "status": "enabled",
  "componentID": "switchyard-gptk-3-framework",
  "gptkVersion": "3.0",
  "reviewDate": "2026-07-22",
  "sourceOuterImageSha256": "ac8f6eeb2b9e5244d4c8eeb5b69b5cec099b560b143a7e5ef413945fc48b0f8f",
  "sourceEvaluationImageSha256": "d49395fb07e536804d1da0858590e53f6aa6fab12512e18fd80a74c87f9f063c",
  "archive": "switchyard-gptk-3-framework.zip",
  "archiveSha256": "<64 lowercase hexadecimal characters>",
  "archiveSize": 0,
  "contentTreeSha256": "<64 lowercase hexadecimal characters>",
  "permittedPaths": [
    "redist",
    "License.rtf",
    "Acknowledgements.rtf"
  ],
  "appleSigningRequirement": "anchor apple generic and identifier \"com.apple.D3DMetal\"",
  "frameworkBundleIdentifier": "com.apple.D3DMetal",
  "frameworkCDHash": "bc0127bf883aff9aa2e483d3cebdfec6470fab3f15918e3b9aabf61cc14e53c9",
  "license": {
    "identifier": "EA18380",
    "path": "License.rtf",
    "url": "https://approved-host.example/releases/immutable-id/License.rtf",
    "sha256": "5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8"
  },
  "acknowledgements": {
    "path": "Acknowledgements.rtf",
    "sha256": "6f3aa835f6d0d06f89997d0a346a209e39a8105521fd939e096c5b24dc0cb0a6"
  },
  "frameworkNotice": {
    "path": "redist/lib/external/D3DMetal.framework/Versions/A/Resources/LICENSE",
    "sha256": "553d0035773ddd1590045f8fdc3a4c6ead31e36336721aeca8421e88ed1c9f80"
  }
}
```

`archiveSize` must be the exact nonzero byte count. The license URL must share the manifest's immutable release directory.
`frameworkCDHash` is the complete 32-byte SHA-256 value from the framework's
`cdhashes-full` signing information, not the traditional 20-byte truncated
CDHash.

The policy also pins `gptk-component-channel.json` and its detached `.sig`. This small mutable status document provides the remote takedown control while the release manifest stays immutable:

```json
{
  "schemaVersion": 1,
  "status": "enabled",
  "releaseManifestSha256": "<SHA-256 of the exact immutable manifest bytes>"
}
```

Switchyard verifies the status document before showing the license and again immediately before downloading the archive. Publishing a signed status with `"status": "disabled"` stops new consent and download attempts. Changing `releaseManifestSha256` invalidates consent prepared for the previous manifest.

## Archive and Tree Digest

The ZIP has exactly one top-level directory named by `componentID`; `__MACOSX` and all other peer roots are rejected. Every extracted entry must be equal to or below one of `permittedPaths`; the installer accepts only `redist`, `License.rtf`, and `Acknowledgements.rtf` as permitted roots and requires the reviewed framework at `redist/lib/external/D3DMetal.framework`. Symlink targets and case-normalized path collisions are checked from ZIP metadata before extraction.

The content-tree digest is SHA-256 over UTF-8 lines sorted by relative path byte order:

```text
file ./relative/path <lowercase-file-sha256>
link ./relative/link <relative-link-target>
```

Directories are omitted. Absolute links, escaping relative links, special filesystem entries, missing notices, unknown roots, modified Mach-O code, and mismatched framework identity all fail installation.

## Consent and Local Record

Switchyard downloads and verifies the signed manifest and exact `License.rtf` before requesting the component archive. The user must acknowledge that:

- the component is Apple-licensed software outside Switchyard's MIT license and is provided without Switchyard or Apple warranty;
- it will run only on supported Apple-branded hardware for developing, testing, or evaluating video games;
- it will be used only with material the user owns or is authorized or legally permitted to use.

The app records the component ID, GPTK version, manifest digest, license ID and digest, acknowledgement flags, and timestamp in local preferences. It does not accept Apple's agreement on the user's behalf or upload that record.
