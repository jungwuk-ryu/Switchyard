import AppCore
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
    let parsed = LaunchArgumentParser.parse("-cef-disable-gpu -login \"user name\" 'two words'")

    #expect(parsed == ["-cef-disable-gpu", "-login", "user name", "two words"])
    #expect(LaunchArgumentParser.parse(LaunchArgumentParser.format(parsed)) == parsed)
}

@Test func launchArgumentParserPreservesWindowsPathBackslashes() {
    let parsed = LaunchArgumentParser.parse(#"-config C:\Games\Steam\config.ini -quoted "C:\Program Files\App\app.exe""#)

    #expect(parsed == ["-config", #"C:\Games\Steam\config.ini"#, "-quoted", #"C:\Program Files\App\app.exe"#])
    #expect(LaunchArgumentParser.parse(LaunchArgumentParser.format(parsed)) == parsed)
}

@Test func executableArgumentRecommendationsAddsSteamCEFWorkarounds() {
    let steamArguments = ExecutableArgumentRecommendations.arguments(forExecutablePath: "C:\\Program Files (x86)\\Steam\\steam.exe")
    let otherArguments = ExecutableArgumentRecommendations.arguments(forExecutablePath: "C:\\Tools\\Toolbox.exe")

    #expect(steamArguments == ["-cef-disable-gpu", "-cef-disable-sandbox"])
    #expect(otherArguments.isEmpty)
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
