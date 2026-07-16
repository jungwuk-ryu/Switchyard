import AppCore
import Foundation
import Testing

@Test func runtimeStatusCanLaunchOnlyWhenRequiredComponentsAreReady() {
    let ready = RuntimeStatus(architecture: .ok, macOS: .ok, gptk: .ok, wine: .ok, patchset: .ok)
    #expect(ready.canLaunch)

    let missingGPTK = RuntimeStatus(architecture: .ok, macOS: .ok, gptk: .missing, wine: .ok, patchset: .ok)
    #expect(!missingGPTK.canLaunch)

    let missingPatchset = RuntimeStatus(architecture: .ok, macOS: .ok, gptk: .ok, wine: .ok, patchset: .missing)
    #expect(!missingPatchset.canLaunch)
}

@Test func containerPinsRuntimeIdentity() {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container", wineBuildID: "wine-a", patchsetID: "patch-a", gptkFingerprint: "gptk-a")
    #expect(container.wineBuildID == "wine-a")
    #expect(container.patchsetID == "patch-a")
    #expect(container.gptkFingerprint == "gptk-a")
    #expect(container.schemaVersion == 3)
}

@Test func environmentOverridePolicyRejectsReservedRuntimeIdentityKeys() {
    #expect(EnvironmentOverridePolicy.isAllowedKey("DXVK_LOG_LEVEL"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey(""))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("1INVALID"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("WINEPREFIX"))
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

@Test func containerPathPolicyIncludesContainerAndDiskDirectoryNames() {
    let container = Container(
        name: "Steam",
        path: "/tmp/Switchyard/Steam.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
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
        path: "/tmp/Switchyard/Foo.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )
    let duplicate = Container(
        name: "Duplicate",
        path: "/tmp/Switchyard/Foo.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )
    let caseDistinct = Container(
        name: "Case Distinct",
        path: "/tmp/Switchyard/foo.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
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
