import AppCore
import Foundation
import Testing

@Test func runtimeStatusCanLaunchOnlyWhenRequiredComponentsAreReady() {
    let ready = RuntimeStatus(architecture: .ok, macOS: .ok, rosetta: .ok, gptk: .ok, wine: .ok, wineSource: .ok)
    #expect(ready.canLaunch)

    let missingRosetta = RuntimeStatus(architecture: .ok, macOS: .ok, rosetta: .missing, gptk: .ok, wine: .ok, wineSource: .ok)
    #expect(!missingRosetta.canLaunch)

    let missingGPTK = RuntimeStatus(architecture: .ok, macOS: .ok, rosetta: .ok, gptk: .missing, wine: .ok, wineSource: .ok)
    #expect(!missingGPTK.canLaunch)

    let missingWineSource = RuntimeStatus(architecture: .ok, macOS: .ok, rosetta: .ok, gptk: .ok, wine: .ok, wineSource: .missing)
    #expect(!missingWineSource.canLaunch)
}

@Test func runtimeStatusMigratesTheLegacyPatchsetStatusKey() throws {
    let legacyData = try #require(
        """
        {
          "architecture": "ok",
          "macOS": "ok",
          "rosetta": "ok",
          "gptk": "ok",
          "wine": "ok",
          "patchset": "warning",
          "summary": "Legacy diagnostic"
        }
        """.data(using: .utf8)
    )

    let status = try JSONDecoder().decode(RuntimeStatus.self, from: legacyData)
    #expect(status.wineSource == .warning)

    let encoded = try JSONEncoder().encode(status)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["wineSource"] as? String == "warning")
    #expect(object["patchset"] == nil)
}

@Test func runtimeBuildNumberUsesSortableUTCRevisionTime() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let buildTime = try #require(
        calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 18,
                hour: 6,
                minute: 45
            )
        )
    )
    let runtime = RuntimeBuild(
        id: "runtime-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123",
        versionDate: buildTime
    )

    #expect(runtime.buildNumber == "20260718.0645")
    #expect(
        RuntimeBuild(
            id: "external",
            winePath: "/opt/wine/bin/wine",
            patchsetID: "external",
            sourceRevision: ""
        ).buildNumber == nil
    )
}

@Test func guidedSetupPolicyPresentsOnlyTheNextRequiredAction() {
    #expect(GuidedSetupPolicy.nextRequirement(for: RuntimeStatus()) == .checking)
    #expect(
        GuidedSetupPolicy.nextRequirement(
            for: RuntimeStatus(architecture: .unsupported, macOS: .ok)
        ) == .unsupportedMac
    )
    #expect(
        GuidedSetupPolicy.nextRequirement(
            for: RuntimeStatus(architecture: .ok, macOS: .ok, rosetta: .missing)
        ) == .rosetta
    )
    #expect(
        GuidedSetupPolicy.nextRequirement(
            for: RuntimeStatus(
                architecture: .ok,
                macOS: .ok,
                rosetta: .ok,
                gptk: .missing,
                wine: .missing,
                wineSource: .missing
            )
        ) == .runtime
    )
    #expect(
        GuidedSetupPolicy.nextRequirement(
            for: RuntimeStatus(
                architecture: .ok,
                macOS: .ok,
                rosetta: .ok,
                gptk: .missing,
                wine: .ok,
                wineSource: .ok
            )
        ) == .toolkit
    )

    let ready = RuntimeStatus(
        architecture: .ok,
        macOS: .ok,
        rosetta: .ok,
        gptk: .ok,
        wine: .ok,
        wineSource: .ok
    )
    #expect(GuidedSetupPolicy.nextRequirement(for: ready) == .ready)
    #expect(GuidedSetupPolicy.canComplete(with: ready))
}

@Test func legacyRuntimeStatusDecodesRosettaAsUnknown() throws {
    let data = Data(
        #"{"architecture":"ok","macOS":"ok","gptk":"ok","wine":"ok","patchset":"ok","summary":"Legacy"}"#.utf8
    )

    let status = try JSONDecoder().decode(RuntimeStatus.self, from: data)

    #expect(status.rosetta == .unknown)
    #expect(!status.canLaunch)
}

@Test func starterApplicationAcceptsOnlyExpectedInstallersAndTrustedURLs() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let older = root.appendingPathComponent("SteamSetup.exe")
    let newer = root.appendingPathComponent("SteamSetup (2).exe")
    let browserVariant = root.appendingPathComponent("SteamSetup-3.exe")
    let partial = root.appendingPathComponent("SteamSetup.exe.crdownload")
    try Data([0x4d, 0x5a, 0x00]).write(to: older)
    try Data([0x4d, 0x5a, 0x01]).write(to: newer)
    try Data([0x4d, 0x5a, 0x02]).write(to: partial)
    try Data([0x4d, 0x5a, 0x03]).write(to: browserVariant)
    let starter = StarterApplicationCatalog.steam
    #expect(starter.trustsDownloadURL(starter.downloadURL))
    #expect(
        starter.trustsDownloadURL(
            URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
        )
    )
    #expect(
        !starter.trustsDownloadURL(
            URL(string: "http://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!
        )
    )
    #expect(
        !starter.trustsDownloadURL(
            URL(string: "https://cdn.fastly.steamstatic.com.example.com/client/installer/SteamSetup.exe")!
        )
    )
    #expect(
        !starter.trustsDownloadURL(
            URL(string: "https://cdn.fastly.steamstatic.com/anything/SteamSetup.exe")!
        )
    )
    #expect(
        !starter.trustsDownloadURL(
            URL(string: "https://cdn.fastly.steamstatic.com:8443/client/installer/SteamSetup.exe")!
        )
    )
    #expect(starter.recognizesInstaller(at: older))
    #expect(starter.hasWindowsExecutableHeader(at: newer))
    #expect(starter.recognizesInstaller(at: browserVariant))
    #expect(!starter.recognizesInstaller(at: partial))
}

@Test func containerRecordsLastRuntimeUsageWithoutSelectingIt() throws {
    let usedAt = Date(timeIntervalSince1970: 1_753_075_800)
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )
    var container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        starterApplicationID: "steam"
    )

    #expect(container.lastRuntime == nil)
    container.recordRuntimeUsage(
        runtime,
        gptkFingerprint: "gptk-a",
        at: usedAt
    )

    let record = try #require(container.lastRuntime)
    #expect(record.runtimeID == "wine-a")
    #expect(record.patchsetID == "patch-a")
    #expect(record.sourceRevision == "abc123")
    #expect(record.gptkFingerprint == "gptk-a")
    #expect(record.usedAt == usedAt)
    #expect(container.starterApplicationID == "steam")
    #expect(container.schemaVersion == 5)
}

@Test func containerRequestsPreparationForTheActiveRuntimeWhenNeeded() {
    let activeRuntime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )
    let nextRuntime = RuntimeBuild(
        id: "wine-b",
        winePath: "/opt/wine-next/bin/wine",
        patchsetID: "patch-b",
        sourceRevision: "def456"
    )
    let rebuiltRuntime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine-rebuilt/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "def456"
    )
    var container = Container(name: "Toolbox", path: "/tmp/Toolbox.container")

    #expect(
        container.runtimePreparation(
            for: activeRuntime,
            hasInitializedRegistry: false
        ) == .initialize
    )
    #expect(
        container.runtimePreparation(
            for: activeRuntime,
            hasInitializedRegistry: true
        ) == .refresh
    )

    container.lastRuntime = ContainerRuntimeRecord(
        runtimeID: "wine-a",
        patchsetID: "patch-a"
    )
    #expect(
        container.runtimePreparation(
            for: activeRuntime,
            hasInitializedRegistry: true
        ) == .refresh
    )

    container.recordRuntimeUsage(activeRuntime, gptkFingerprint: "gptk-a")
    #expect(
        container.runtimePreparation(
            for: activeRuntime,
            hasInitializedRegistry: true
        ) == .none
    )
    #expect(
        container.runtimePreparation(
            for: nextRuntime,
            hasInitializedRegistry: true
        ) == .refresh
    )
    #expect(
        container.runtimePreparation(
            for: rebuiltRuntime,
            hasInitializedRegistry: true
        ) == .refresh
    )
}

@Test func environmentOverridePolicyRejectsReservedRuntimeIdentityKeys() {
    #expect(EnvironmentOverridePolicy.isAllowedKey("DXVK_LOG_LEVEL"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey(""))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("1INVALID"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("WINEPREFIX"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("WINEDLLPATH"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("DYLD_LIBRARY_PATH"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("DYLD_FRAMEWORK_PATH"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("SWITCHYARD_PATCHSET_ID"))
}

@Test func launchArgumentParserRoundTripsQuotedArguments() {
    let parsed = LaunchArgumentParser.parse("-safe-mode -login \"user name\" 'two words'")

    #expect(parsed == ["-safe-mode", "-login", "user name", "two words"])
    #expect(LaunchArgumentParser.parse(LaunchArgumentParser.format(parsed)) == parsed)
}

@Test func launchArgumentParserPreservesWindowsPathBackslashes() {
    let parsed = LaunchArgumentParser.parse(#"-config C:\Games\Steam\config.ini -quoted "C:\Program Files\App\app.exe""#)

    #expect(parsed == ["-config", #"C:\Games\Steam\config.ini"#, "-quoted", #"C:\Program Files\App\app.exe"#])
    #expect(LaunchArgumentParser.parse(LaunchArgumentParser.format(parsed)) == parsed)
}

@Test func wineProtocolManifestAcceptsOnlyCustomURLSchemes() {
    let manifest = """
    # switchyard-wine-protocols-v1
    XDT
    com.example.login
    https
    bad/scheme
    1invalid
    """

    #expect(
        WineProtocolAssociationFormat.schemes(inManifest: manifest)
            == ["xdt", "com.example.login"]
    )
    #expect(WineProtocolAssociationFormat.scheme(inRawURL: "XDT://callback?code=secret") == "xdt")
    #expect(WineProtocolAssociationFormat.scheme(inRawURL: "https://example.com") == nil)
}

@Test func wineProtocolRoutesPreferTheMostRecentlyActivatedContainer() {
    let olderID = UUID()
    let newerID = UUID()
    let older = WineProtocolRoute(
        scheme: "xdt",
        containerID: olderID,
        prefixPath: "/tmp/Older.container",
        winePath: "/opt/wine/bin/wine",
        runnerPath: "/Applications/Switchyard.app/Contents/Helpers/switchyard-runner",
        lastActivatedAt: Date(timeIntervalSince1970: 1)
    )
    let newer = WineProtocolRoute(
        scheme: "xdt",
        containerID: newerID,
        prefixPath: "/tmp/Newer.container",
        winePath: "/opt/wine/bin/wine",
        runnerPath: "/Applications/Switchyard.app/Contents/Helpers/switchyard-runner",
        lastActivatedAt: Date(timeIntervalSince1970: 2)
    )

    let index = WineProtocolRouteIndex(routes: [older, newer])

    #expect(index.route(forScheme: "XDT")?.containerID == newerID)
    #expect(index.route(forScheme: "https") == nil)
}

@Test func wineDesktopShortcutManifestDecodesOnlyPrivateDesktopEntries() throws {
    func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    let validPath = #"C:\users\steamuser\Desktop\Heartopia.lnk"#
    let validIcon = #"C:\windows\temp\switchyard-desktop-icons-v1\0123456789abcdef.png"#
    let traversalPath = #"C:\users\steamuser\Desktop\..\Outside.lnk"#
    let wrongKindPath = #"C:\users\steamuser\Desktop\Website.url"#
    let manifest = """
    \(WineDesktopShortcutFormat.manifestHeader)
    lnk\t\(hex("Heartopia"))\t\(hex(validPath))\t\(hex(validIcon))
    lnk\t\(hex("Outside"))\t\(hex(traversalPath))\t
    lnk\t\(hex("Wrong kind"))\t\(hex(wrongKindPath))\t
    """

    #expect(
        WineDesktopShortcutFormat.entries(inManifest: manifest)
            == [
                WineDesktopShortcutManifestEntry(
                    kind: .lnk,
                    displayName: "Heartopia",
                    windowsShortcutPath: validPath,
                    windowsIconPath: validIcon
                )
            ]
    )
    #expect(WineDesktopShortcutFormat.entries(inManifest: "# unknown\n").isEmpty)
}

@Test func wineDesktopShortcutPathsRejectDesktopLinksOutsideThePrefix() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchyard-shortcut-path-\(UUID().uuidString)", isDirectory: true)
    let prefix = root.appendingPathComponent("Test.container", isDirectory: true)
    let user = prefix.appendingPathComponent("drive_c/users/steamuser", isDirectory: true)
    let externalDesktop = root.appendingPathComponent("ExternalDesktop", isDirectory: true)
    let desktop = user.appendingPathComponent("Desktop", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalDesktop, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: desktop, withDestinationURL: externalDesktop)

    let windowsPath = #"C:\users\steamuser\Desktop\Heartopia.lnk"#
    #expect(
        WineDesktopShortcutFormat.hostShortcutURL(
            windowsPath: windowsPath,
            prefixPath: prefix.path
        ) == nil
    )

    try FileManager.default.removeItem(at: desktop)
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: false)
    let shortcut = desktop.appendingPathComponent("Heartopia.lnk")
    try Data("shortcut".utf8).write(to: shortcut)
    #expect(
        WineDesktopShortcutFormat.hostShortcutURL(
            windowsPath: windowsPath,
            prefixPath: prefix.path
        )?.standardizedFileURL == shortcut.standardizedFileURL
    )
    #expect(
        WineDesktopShortcutFormat.normalizedShortcutPath(
            #"D:\users\steamuser\Desktop\Heartopia.lnk"#
        ) == nil
    )
}

@Test func wineDesktopShortcutRouteIndexRequiresTheCurrentVersionAndExactID() {
    let id = String(repeating: "a", count: 64)
    let route = WineDesktopShortcutRoute(
        id: id,
        containerID: UUID(),
        prefixPath: "/tmp/Test.container",
        winePath: "/opt/wine/bin/wine",
        runnerPath: "/Applications/Switchyard.app/Contents/Helpers/switchyard-runner",
        windowsShortcutPath: #"C:\users\steamuser\Desktop\Heartopia.lnk"#
    )

    #expect(WineDesktopShortcutRouteIndex(routes: [route]).route(forID: id) == route)
    #expect(WineDesktopShortcutRouteIndex(version: 2, routes: [route]).route(forID: id) == nil)
    #expect(WineDesktopShortcutRouteIndex(routes: [route]).route(forID: "missing") == nil)
}

@Test func learnedWineProtocolAssociationsNormalizeReplaceAndPruneRoutes() {
    let retainedContainerID = UUID()
    let removedContainerID = UUID()
    let firstDate = Date(timeIntervalSince1970: 10)
    let replacementDate = Date(timeIntervalSince1970: 20)
    var index = WineProtocolLearnedAssociationIndex()

    #expect(
        index.learn(
            scheme: "XDT",
            for: retainedContainerID,
            handlerExecutablePath: #"C:\Games\First.exe"#,
            at: firstDate
        ) == "xdt"
    )
    #expect(
        index.learn(
            scheme: "xdt",
            for: retainedContainerID,
            handlerExecutablePath: #"C:\Games\Heartopia\xdt.exe"#,
            at: replacementDate
        ) == "xdt"
    )
    #expect(index.learn(scheme: "TapOAuth", for: removedContainerID, at: firstDate) == "tapoauth")
    #expect(index.learn(scheme: "https", for: retainedContainerID, at: firstDate) == nil)
    #expect(
        index.learn(
            scheme: "bad-handler",
            for: retainedContainerID,
            handlerExecutablePath: #"C:\Games\..\Bad.exe"#,
            at: firstDate
        ) == nil
    )

    #expect(
        index.associations(for: retainedContainerID)
            == [
                WineProtocolLearnedAssociation(
                    scheme: "xdt",
                    containerID: retainedContainerID,
                    handlerExecutablePath: #"C:\Games\Heartopia\xdt.exe"#,
                    learnedAt: replacementDate
                )
            ]
    )

    let pruned = index.pruning(to: [retainedContainerID])
    #expect(pruned.associations.count == 1)
    #expect(pruned.associations(for: removedContainerID).isEmpty)
}

@Test func windowsExecutablePathsAreNormalizedWithoutAllowingTraversal() {
    let prefixPath = "/tmp/Test.container"

    #expect(
        WineProtocolAssociationFormat.normalizedWindowsExecutablePath(#" C:/Games/Heartopia/xdt.EXE "#)
            == #"C:\Games\Heartopia\xdt.EXE"#
    )
    #expect(
        WineProtocolAssociationFormat.windowsExecutablePath(
            hostPath: "/tmp/Test.container/drive_c/Games/Heartopia/xdt.exe",
            prefixPath: prefixPath
        ) == #"C:\Games\Heartopia\xdt.exe"#
    )
    #expect(
        WineProtocolAssociationFormat.windowsExecutablePath(
            hostPath: "/tmp/Test.container-copy/drive_c/Games/xdt.exe",
            prefixPath: prefixPath
        ) == nil
    )
    #expect(WineProtocolAssociationFormat.normalizedWindowsExecutablePath(#"C:\Games\..\xdt.exe"#) == nil)
    #expect(
        WineProtocolAssociationFormat.normalizedWindowsExecutablePath(#"Z:\Games\xdt.exe"#)
            == #"Z:\Games\xdt.exe"#
    )
    #expect(WineProtocolAssociationFormat.normalizedWindowsExecutablePath(#"1:\Games\xdt.exe"#) == nil)
    #expect(WineProtocolAssociationFormat.normalizedWindowsExecutablePath(#"C:\Games\xdt.dll"#) == nil)
    #expect(WineProtocolAssociationFormat.normalizedWindowsExecutablePath(#"C:\Games\"xdt.exe"#) == nil)
}

@Test func callbackTargetsExcludeWineInfrastructureAndHelpers() {
    let paths = [
        #"C:\windows\system32\services.exe"#,
        #"C:\Program Files (x86)\Steam\steam.exe"#,
        #"C:\Program Files (x86)\Steam\steamwebhelper.exe"#,
        #"C:\Games\Heartopia\xdt.exe"#,
        #"D:\SteamLibrary\Another Game\game.exe"#,
        #"C:\Games\Heartopia\UnityCrashHandler64.exe"#,
        #"C:\Games\Heartopia\xdt.exe"#
    ]

    #expect(
        WineProtocolAssociationFormat.callbackTargetCandidates(from: paths)
            == [
                #"C:\Games\Heartopia\xdt.exe"#,
                #"C:\Program Files (x86)\Steam\steam.exe"#,
                #"D:\SteamLibrary\Another Game\game.exe"#
            ]
    )
    #expect(
        WineProtocolAssociationFormat.callbackTargetCandidates(
            from: paths,
            excluding: [#"C:\Program Files (x86)\Steam\steam.exe"#]
        ) == [#"C:\Games\Heartopia\xdt.exe"#, #"D:\SteamLibrary\Another Game\game.exe"#]
    )
}

@Test func containerPathPolicyAvoidsExistingDirectoryNames() {
    let existingNames: Set<String> = [
        "NewContainer.container",
        "NewContainer2.container",
        "Other.container"
    ]

    #expect(ContainerPathPolicy.directoryName(for: "New Container") == "NewContainer.container")
    #expect(ContainerPathPolicy.uniqueDirectoryName(for: "New Container", existingDirectoryNames: existingNames) == "NewContainer3.container")
}

@Test func windowsApplicationFileKindRecognizesExecutableAndInstallerExtensions() {
    #expect(WindowsApplicationFileKind(path: "/tmp/Setup.EXE") == .executable)
    #expect(WindowsApplicationFileKind(path: "/tmp/Package.mSi") == .installerPackage)
    #expect(WindowsApplicationFileKind(path: "/tmp/Archive.zip") == nil)
}

@Test func windowsInstallerLaunchUsesMSIExec() {
    let arguments = WindowsApplicationFileKind.installerPackage.wineArguments(
        for: "/tmp/Epic Installer.msi",
        additionalArguments: ["/quiet"]
    )

    #expect(arguments == ["msiexec.exe", "/i", "/tmp/Epic Installer.msi", "/quiet"])
}

@Test func battleNetLaunchUsesOneToOneCEFDisplayScaling() {
    let arguments = WindowsApplicationFileKind.executable.wineArguments(
        for: "/tmp/Battle.net/Battle.net.exe"
    )

    #expect(arguments == [
        "/tmp/Battle.net/Battle.net.exe",
        "--high-dpi-support=1",
        "--force-device-scale-factor=1",
    ])
}

@Test func battleNetLaunchPreservesExplicitDisplayScalingArguments() {
    let arguments = WindowsApplicationFileKind.executable.wineArguments(
        for: #"C:\Program Files (x86)\Battle.net\BATTLE.NET LAUNCHER.EXE"#,
        additionalArguments: [
            "--high-dpi-support=0",
            "--force-device-scale-factor=1.25",
            "--locale=koKR",
        ]
    )

    #expect(arguments == [
        #"C:\Program Files (x86)\Battle.net\BATTLE.NET LAUNCHER.EXE"#,
        "--high-dpi-support=0",
        "--force-device-scale-factor=1.25",
        "--locale=koKR",
    ])
}

@Test func otherExecutableLaunchDoesNotReceiveBattleNetDisplayArguments() {
    let arguments = WindowsApplicationFileKind.executable.wineArguments(
        for: "/tmp/Steam/steam.exe",
        additionalArguments: ["-silent"]
    )

    #expect(arguments == ["/tmp/Steam/steam.exe", "-silent"])
}

@Test func containerPathPolicyRelocatesOnlyPathsInsideRenamedContainer() {
    #expect(
        ContainerPathPolicy.relocatingPath(
            "/tmp/Library/Old.container/drive_c/Game/game.exe",
            from: "/tmp/Library/Old.container",
            to: "/tmp/Library/New.container"
        ) == "/tmp/Library/New.container/drive_c/Game/game.exe"
    )
    #expect(
        ContainerPathPolicy.relocatingPath(
            "/tmp/Library/Old.container-copy/game.exe",
            from: "/tmp/Library/Old.container",
            to: "/tmp/Library/New.container"
        ) == "/tmp/Library/Old.container-copy/game.exe"
    )
    #expect(
        ContainerPathPolicy.relocatingPath(
            #"C:\Program Files\Game\game.exe"#,
            from: "/tmp/Library/Old.container",
            to: "/tmp/Library/New.container"
        ) == #"C:\Program Files\Game\game.exe"#
    )
}

@Test func containerPathPolicyIncludesContainerAndDiskDirectoryNames() {
    let container = Container(
        name: "Steam",
        path: "/tmp/Switchyard/Steam.container"
    )

    let names = ContainerPathPolicy.occupiedDirectoryNames(
        containers: [container],
        existingDirectoryNames: ["BattleNet.container"]
    )

    #expect(names == ["Steam.container", "BattleNet.container"])
}

@Test func containerPathPolicyRemovesOnlyExactDuplicatePaths() {
    let first = Container(
        name: "First",
        path: "/tmp/Switchyard/Foo.container"
    )
    let duplicate = Container(
        name: "Duplicate",
        path: "/tmp/Switchyard/Foo.container"
    )
    let caseDistinct = Container(
        name: "Case Distinct",
        path: "/tmp/Switchyard/foo.container"
    )

    let result = ContainerPathPolicy.removingDuplicatePaths(from: [first, duplicate, caseDistinct])

    #expect(result.containers.map(\.name) == ["First", "Case Distinct"])
    #expect(result.removedNames == ["Duplicate"])
}

@Test func logLineKeepsContainerIdentityAndDecodesLegacyPayloads() throws {
    let containerID = UUID()
    let line = LogLine(
        containerID: containerID,
        level: "info",
        source: "Steam",
        message: "Launched"
    )
    let roundTripped = try JSONDecoder().decode(LogLine.self, from: JSONEncoder().encode(line))

    #expect(roundTripped.containerID == containerID)

    let legacyData = Data(
        """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "timestamp": 0,
          "level": "info",
          "source": "Steam",
          "message": "Legacy log"
        }
        """.utf8
    )
    let legacyLine = try JSONDecoder().decode(LogLine.self, from: legacyData)

    #expect(legacyLine.containerID == nil)
}

@Test func intentionalRunStopsNormalizeToReadyInsteadOfFailed() {
    let normalized = RunCompletionPolicy.normalizedOutcome(.failed, stoppedByUser: true)

    #expect(normalized == .cancelled)
    #expect(RunCompletionPolicy.containerStatus(for: normalized) == .ready)
    #expect(RunCompletionPolicy.containerStatus(for: .failed) == .failed)
    #expect(RunCompletionPolicy.containerStatus(for: .succeeded) == .succeeded)
}

@Test func logClearPolicyScopesContainerAndGlobalClears() {
    let firstContainerID = UUID()
    let secondContainerID = UUID()
    let logs = [
        LogLine(containerID: firstContainerID, level: "info", source: "first", message: "A"),
        LogLine(containerID: secondContainerID, level: "warning", source: "second", message: "B"),
        LogLine(level: "info", source: "runtime", message: "Global")
    ]

    #expect(LogClearPolicy.clearing(logs).isEmpty)
    #expect(
        LogClearPolicy.clearing(logs, for: firstContainerID).map(\.message)
            == ["B", "Global"]
    )
}

@Test func wineDebugLoggingProfilesKeepSEHTraceBehindVerboseMode() {
    let standard = WineDebugLoggingProfile.standard.environmentValue
    let verbose = WineDebugLoggingProfile.verbose.environmentValue

    #expect(standard.contains("err+all"))
    #expect(standard.contains("warn+all"))
    #expect(!standard.contains("trace+seh"))
    #expect(!standard.contains("fixme+all"))
    #expect(verbose.contains("err+all"))
    #expect(verbose.contains("warn+all"))
    #expect(verbose.contains("fixme+all"))
    #expect(verbose.contains("trace+seh"))
    #expect(verbose.contains("trace+dxgi"))
    #expect(verbose.contains("trace+wined3d"))
}

@Test func debugRunLogRetentionPolicyUsesSupportedValuesAndSafeDefaults() {
    let configured = DebugRunLogRetentionPolicy(
        retentionDays: 30,
        maximumFileCount: 100
    )
    let invalid = DebugRunLogRetentionPolicy(
        retentionDays: 0,
        maximumFileCount: 1_000
    )

    #expect(configured.retentionDays == 30)
    #expect(configured.maximumFileCount == 100)
    #expect(invalid.retentionDays == DebugRunLogRetentionPolicy.defaultRetentionDays)
    #expect(invalid.maximumFileCount == DebugRunLogRetentionPolicy.defaultMaximumFileCount)
}

@Test func processLogLevelPolicyUnderstandsWineDebugClasses() {
    #expect(
        ProcessLogLevelPolicy.normalizedLevel(
            for: "[Battle.net] 37884.833:0580:trace:seh:dispatch_exception code=c0000005",
            fallbackLevel: "error"
        ) == "debug"
    )
    #expect(
        ProcessLogLevelPolicy.normalizedLevel(
            for: "0430:warn:dxgi:dxgi_device_init Failed to create device",
            fallbackLevel: "error"
        ) == "warning"
    )
    #expect(
        ProcessLogLevelPolicy.normalizedLevel(
            for: "0088:fixme:msvcp:locale__Locimp__Makexloc semi-stub",
            fallbackLevel: "error"
        ) == "warning"
    )
    #expect(
        ProcessLogLevelPolicy.normalizedLevel(
            for: "0744:err:d3d:wined3d_check_gl_call GL error",
            fallbackLevel: "info"
        ) == "error"
    )
    #expect(
        ProcessLogLevelPolicy.normalizedLevel(
            for: "wine: Unhandled exception 0xe0000008",
            fallbackLevel: "error"
        ) == "error"
    )
}

@Test func liveLogPolicyPrependsChronologicalBatchesAndCapsRetention() {
    let existing = [
        LogLine(level: "info", source: "test", message: "C"),
        LogLine(level: "info", source: "test", message: "B"),
        LogLine(level: "info", source: "test", message: "A"),
    ]
    let incoming = [
        LogLine(level: "debug", source: "test", message: "D"),
        LogLine(level: "error", source: "test", message: "E"),
    ]

    #expect(
        LiveLogPolicy.merging(chronological: incoming, before: existing, limit: 4)
            .map(\.message) == ["E", "D", "C", "B"]
    )
    #expect(
        LiveLogPolicy.merging(chronological: incoming, before: existing, limit: 1)
            .map(\.message) == ["E"]
    )
    #expect(
        LiveLogPolicy.merging(chronological: incoming, before: existing, limit: 0).isEmpty
    )
}

@Test func recentProgramLaunchPolicyMovesRelaunchesToTheFrontAndCapsHistory() {
    let firstPath = "/tmp/Container/first.exe"
    let secondPath = "/tmp/Container/second.exe"
    let thirdPath = "/tmp/Container/third.exe"
    let firstLaunch = RecentProgramLaunch(
        executablePath: firstPath,
        launchedAt: Date(timeIntervalSince1970: 10)
    )
    let secondLaunch = RecentProgramLaunch(
        executablePath: secondPath,
        launchedAt: Date(timeIntervalSince1970: 20)
    )
    let thirdLaunch = RecentProgramLaunch(
        executablePath: thirdPath,
        launchedAt: Date(timeIntervalSince1970: 15)
    )

    let result = RecentProgramLaunchPolicy.recording(
        executablePath: firstPath,
        at: Date(timeIntervalSince1970: 30),
        in: [firstLaunch, secondLaunch, thirdLaunch],
        limit: 2
    )

    #expect(result.map(\.executablePath) == [firstPath, secondPath])
    #expect(result.map(\.launchedAt) == [
        Date(timeIntervalSince1970: 30),
        Date(timeIntervalSince1970: 20),
    ])
    #expect(RecentProgramLaunchPolicy.recording(executablePath: firstPath, in: result, limit: 0).isEmpty)
    #expect(
        RecentProgramLaunchPolicy.recording(executablePath: "  ", in: result, limit: 2) == result
    )
}

@Test func winePrefixFileLockCreatesPrivateContainerLockFile() throws {
    let prefixURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchyard-prefix-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: prefixURL) }

    let lock = try WinePrefixFileLock(prefixPath: prefixURL.path, mode: .exclusive)
    let lockURL = prefixURL.appendingPathComponent(WinePrefixFileLock.fileName)
    let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

    #expect(permissions.intValue & 0o777 == 0o600)
    lock.unlock()
}
