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
