import AppCore
import LauncherAdapters
import Testing

@Test func steamInstallPlanUsesWinePrefixAndGPTKPath() throws {
    let container = Container(name: "Steam", path: "/tmp/Steam.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let plan = SteamAdapter().installPlan(
        container: container,
        runtime: runtime,
        gptkPath: "/Applications/Game Porting Toolkit",
        installerPath: "/Users/example/Installers/SteamSetup.exe"
    )

    #expect(plan.executable == "/opt/wine/bin/wine")
    #expect(plan.arguments == ["/Users/example/Installers/SteamSetup.exe"])
    #expect(plan.environment["WINEPREFIX"] == "/tmp/Steam.container")
    #expect(plan.environment["SWITCHYARD_GPTK_PATH"] == "/Applications/Game Porting Toolkit")
}

@Test func runPlanRequiresConfiguredExecutable() throws {
    let container = Container(name: "Steam", path: "/tmp/Steam.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let launcher = Launcher(name: "Steam", kind: .steam, containerID: container.id)
    let profile = LaunchProfile(launcher: launcher, container: container, runtime: runtime, useGPTK: false, gptkPath: nil)

    #expect(throws: LauncherAdapterError.missingExecutable(.steam)) {
        _ = try SteamAdapter().runPlan(profile: profile)
    }
}

@Test func runPlanAppliesEnvironmentOverrides() throws {
    let container = Container(name: "Steam", path: "/tmp/Steam.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let launcher = Launcher(name: "Steam", kind: .steam, containerID: container.id, executablePath: "/tmp/Steam.exe")
    let profile = LaunchProfile(
        launcher: launcher,
        container: container,
        runtime: runtime,
        useGPTK: false,
        gptkPath: nil,
        environmentOverrides: ["DXVK_LOG_LEVEL": "none"]
    )

    let plan = try SteamAdapter().runPlan(profile: profile)

    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
}

@Test func runPlanRejectsReservedEnvironmentOverrides() throws {
    let container = Container(name: "Steam", path: "/tmp/Steam.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let launcher = Launcher(name: "Steam", kind: .steam, containerID: container.id, executablePath: "/tmp/Steam.exe")
    let profile = LaunchProfile(
        launcher: launcher,
        container: container,
        runtime: runtime,
        useGPTK: false,
        gptkPath: nil,
        environmentOverrides: [
            "WINEPREFIX": "/tmp/Other.container",
            "SWITCHYARD_PATCHSET_ID": "other",
            "DXVK_LOG_LEVEL": "none"
        ]
    )

    let plan = try SteamAdapter().runPlan(profile: profile)

    #expect(plan.environment["WINEPREFIX"] == "/tmp/Steam.container")
    #expect(plan.environment["SWITCHYARD_PATCHSET_ID"] == "patch-a")
    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
}
