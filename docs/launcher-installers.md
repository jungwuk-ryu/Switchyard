# Official Game Launcher Installers

Switchyard exposes a small, reviewed catalog of vendor-hosted Windows game
launcher installers in each container's **Applications** page. The feature is
designed for people who would otherwise land on a macOS `.dmg` download or
have to discover a hidden Windows download link.

## User flow

1. Open a container and choose **Applications**.
2. Review the detected state for Steam, Battle.net, Epic Games Launcher, and
   Rockstar Games Launcher.
3. Choose **Download & Install** for a launcher that is not installed.
4. Switchyard downloads from the catalog's fixed vendor endpoint, validates
   every redirect, checks the installer format and size, records a SHA-256
   receipt, and stores the installer in its private cache.
5. Switchyard opens the installer through the external runner in the selected
   container.
6. The app scans that container until the launcher's installed executable is
   detected. If the container has no default application yet, the detected
   launcher becomes its default.
7. The card changes to **Installed** and offers **Launch**.

Only one launcher installation flow can be active in a container at a time.
Because the verified installer cache is shared, the same launcher is also
serialized across containers; different launchers in other containers remain
independent. A download can be cancelled before the Windows installer opens.

## Reviewed catalog

The stable source URLs select the latest Windows installer. Versioned CDN URLs
may change, so redirects are accepted only when they match the reviewed host,
path, filename, and query rules.

| Launcher | Stable source URL | Accepted installer | Installed executable |
| --- | --- | --- | --- |
| Steam | `https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe` | PE/EXE from Valve's Steam CDN path | `Steam/steam.exe` |
| Battle.net | `https://downloader.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live` | PE/EXE under `downloader.battle.net/download/installer/win/…/Battle.net-Setup.exe` | `Battle.net/Battle.net Launcher.exe` or `Battle.net/Battle.net.exe` |
| Epic Games Launcher | `https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi` | MSI under Epic's reviewed Akamai Windows installer path | `Epic Games/Launcher/…/EpicGamesLauncher.exe` |
| Rockstar Games Launcher | `https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe` | PE/EXE from Rockstar's public installer path | `Rockstar Games/Launcher/Launcher.exe` |

Vendor download pages used to review the catalog:

- [Steam](https://store.steampowered.com/about/)
- [Battle.net](https://download.battle.net/en-us/desktop)
- [Epic Games Launcher](https://www.epicgames.com/help/c-202300000001639/a202300000012839?lang=en-US)
- [Rockstar Games Launcher](https://support.rockstargames.com/articles/4extB4aITvMKdDEZzsFAwE/rockstar-games-launcher-download)

## Trust and licensing boundaries

- Switchyard does not bundle or redistribute any launcher.
- Every request uses HTTPS. URL user info, nonstandard ports, fragments,
  unreviewed query items, hosts, paths, and filenames are rejected.
- Redirect validation happens before following each redirect and again on the
  final response URL.
- Downloads are streamed with a launcher-specific maximum size.
- EXE files must have a PE `MZ` header; MSI files must have the OLE compound
  document header.
- The cache directory is mode `0700`; installers and SHA-256 receipts are mode
  `0600`. A cached file is reused only after its source URL, final URL, size,
  type, and digest are revalidated.
- Each publisher's installer owns its license presentation, account sign-in,
  update behavior, and game downloads. The external Wine runner remains the
  only process execution boundary.
- Apple Game Porting Toolkit components are not involved in this catalog and
  remain subject to the separate GPTK component controls.

## Failure behavior

- An unreviewed redirect, malformed response, oversized payload, wrong file
  signature, or changed cache entry stops before execution.
- A failed download or launch leaves the container intact and offers a retry.
- If the installer exits without a recognized executable, the card explains
  that detection failed and retries in the same container rather than creating
  another one.
- The publisher's official download page remains available from every card as
  a fallback and as provenance.

## Adding or updating a launcher

1. Start from a publisher-owned download page and identify its stable Windows
   endpoint.
2. Record every redirect from a fresh request. Add only exact vendor/CDN hosts
   and the narrowest viable path and filename rule.
3. Set a conservative maximum size and the correct EXE/MSI format.
4. Install into a disposable validation container and record the primary
   executable's path components.
5. Add catalog tests for the source URL, allowed redirect, rejected lookalike
   host/path/query, installer header, and installed executable detection.
6. Re-run `swift test` and `./script/build_and_run.sh --verify`.
