# Licensing and Redistribution

Switchyard keeps the app, patched Wine runtime, separately licensed Apple software, and downloaded open-source assets on explicit license and process boundaries.

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

Switchyard supports both user-local development builds and separately published Wine-only runtime archives. Published archives must be traceable to an immutable source commit in `switchyard-wine`, carry dependency notices and corresponding-source metadata, preserve replacement and rebuild instructions, use Developer ID signatures, and pass Apple notarization. The signed app exactly pins its recommended runtime for automatic setup. Its runtime manager may also install stable releases discovered only from the official `switchyard-wine` GitHub channel when they match the app's trusted Developer ID team; each release manifest pins the archive digest and size, and the installer verifies the extracted runtime before placing it at an immutable content-addressed path.

## Apple Game Porting Toolkit

Switchyard never bundles Game Porting Toolkit components. The checked-in release policy keeps the separate GPTK 3 component channel disabled, so current builds open Apple's official download page, detect a completed user download, and import an explicitly selected local copy.

The app may import a user-selected or explicitly requested local Apple disk image into a user-local cache, validate known marker files, reject escaping links, require Apple signatures on every imported Mach-O, and retain a local fingerprint for last-use diagnostics and provenance. Apple remains responsible for account sign-in, license presentation, and the download itself. The cache is the user's local copy and is not a Switchyard-distributed artifact.

The source tree implements a separate GPTK 3 component installer solely for non-commercial distribution of the complete unmodified Framework and/or unmodified components from `/redist`. Before any component bytes are requested, the app verifies a signed immutable manifest, retrieves and displays the exact reviewed Apple license, and records the user's acknowledgements locally. It then checks the archive digest and size, allowed paths, full file-tree digest, required notices, Apple code signatures, bundle identity, and reviewed framework CDHash before installing to the user-local GPTK cache.

The channel is not part of the app or Wine release and remains release-disabled in [`config/gptk-component.env`](../config/gptk-component.env). It may be enabled only after every distributor-authority, provenance, notice, signature, user-flow, export, termination, and non-commercial control in the [GPTK 3 redistribution review](legal/gptk-3-redistribution-review.md) is enforced and its independent legal sign-off is recorded. Missing approval or operational record identifiers keep the channel unavailable. The signed channel-status document can also disable new downloads immediately. GPTK 4 and every other unreviewed version remain blocked.

Do not commit or add GPTK files to app bundles, Wine runtimes, container templates, or combined release archives. Do not publish or transfer an Apple-provided GPTK DMG. A separately hosted component artifact may be published only for an exact version approved by the legal release gate. The accompanying license is the source of truth, Apple Software remains outside the MIT and LGPL grants, and the official user-download route must remain available.

The runtime builder may preserve Wine-built fallback graphics modules before overlaying a user-selected GPTK redistributable directory. Those fallback files remain Wine build artifacts and must not contain Apple binaries.

App launches can reference the selected user-local GPTK `redist/lib` tree through Wine and dyld search-path environment variables. This external reference does not place GPTK files in the Wine runtime, app bundle, or container.

## Wine Runtime Dependencies

The `switchyard-wine` builder downloads or discovers runtime dependencies only in user-local caches and records their identities in `switchyard-runtime.json`.

- Preserve notices and source obligations for FreeType, fontconfig, libpng, gettext, libunistring, GnuTLS, the Vulkan loader and headers, MoltenVK, and their dependency closures before distributing a runtime containing them.
- Verify pinned digests before staging dependencies.
- Keep runtime-local libraries replaceable and separate from user-provided or version-reviewed GPTK.
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
