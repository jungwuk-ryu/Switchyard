# Licensing and Redistribution

Switchyard keeps the app, patched Wine runtime, user-provided Apple software, and downloaded open-source assets on explicit license and process boundaries.

## Switchyard App and Runner

The Swift app, portable packages, runner, scripts, and original documentation in this repository are licensed under the [MIT License](../LICENSE).

This license does not relicense Wine, Apple Game Porting Toolkit components, fonts, or any Windows application used with Switchyard.

## Wine

Switchyard uses the public [`switchyard-wine`](https://github.com/jungwuk-ryu/switchyard-wine) downstream repository. Wine and Switchyard's Wine modifications are licensed under the GNU Lesser General Public License, version 2.1 or later.

The macOS app does not link against Wine. It launches a replaceable Wine runtime through the external `switchyard-runner` process boundary.

Required practices:

- Pin an immutable `switchyard-wine` source commit in `config/switchyard-wine.env`.
- Preserve Wine license and copyright notices.
- Keep every distributed binary traceable to its complete corresponding source and build instructions.
- Preserve the user's ability to rebuild or replace the Wine runtime independently from the app.
- Do not ship an opaque Wine binary as an app resource.
- Keep Wine source changes, provenance, and runtime build tooling in `switchyard-wine`, not in this repository.

Switchyard currently builds user-local runtimes. Publishing prebuilt runtimes remains blocked until source publication, dependency notices, signing, notarization, and LGPL replacement requirements are verified together.

## Apple Game Porting Toolkit

Switchyard does not bundle or download Apple Game Porting Toolkit components.

The app may import a user-selected Apple disk image or directory into a user-local cache, validate known marker files, and retain a local fingerprint for container compatibility. That cache is the user's local copy and is not a Switchyard-distributed artifact.

Do not commit, publish, or add GPTK files to app bundles or release archives. The license presented with the user's GPTK installation is the source of truth for that local use. This policy is an engineering boundary, not legal advice.

The runtime builder may preserve Wine-built fallback graphics modules before overlaying a user-selected GPTK redistributable directory. Those fallback files remain Wine build artifacts and must not contain Apple binaries.

## Wine Runtime Dependencies

The `switchyard-wine` builder downloads or discovers runtime dependencies only in user-local caches and records their identities in `switchyard-runtime.json`.

- Preserve notices and source obligations for FreeType, fontconfig, libpng, gettext, libunistring, GnuTLS, the Vulkan loader and headers, MoltenVK, and their dependency closures before distributing a runtime containing them.
- Verify pinned digests before staging dependencies.
- Keep runtime-local libraries replaceable and separate from user-provided GPTK.
- Never commit staged bottles, libraries, or files copied from another local Wine distribution.

Refer to the source-owned provenance and build documentation in `switchyard-wine` for the exact dependency set.

## Open Font Pack

Switchyard downloads verified Noto fonts directly from the official `notofonts` repositories into a user-local cache and may install them into user-created Wine containers. The fonts are licensed under the SIL Open Font License 1.1.

- Do not copy, bundle, or synthesize Microsoft fonts such as Segoe UI, Arial, Malgun Gothic, Yu Gothic, Microsoft YaHei, or Microsoft JhengHei.
- Verify every downloaded font against the digest recorded in `OpenFontPackCatalog`.
- Preserve source and license references in `SWITCHYARD-FONT-PACK-NOTICES.txt` inside each modified container.
- Include the complete upstream license and copyright notices before distributing any font binary as part of a release artifact.

## Compatibility Limits

Switchyard must not implement DRM or anti-cheat bypasses. Unsupported DRM- or anti-cheat-dependent software is a compatibility limitation, not a target for circumvention.
