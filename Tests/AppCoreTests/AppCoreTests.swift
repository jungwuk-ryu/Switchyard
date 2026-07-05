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
}

@Test func environmentOverridePolicyRejectsReservedRuntimeIdentityKeys() {
    #expect(EnvironmentOverridePolicy.isAllowedKey("DXVK_LOG_LEVEL"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey(""))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("1INVALID"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("WINEPREFIX"))
    #expect(!EnvironmentOverridePolicy.isAllowedKey("SWITCHYARD_PATCHSET_ID"))
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
