import AppCore
import LauncherAdapters
import Testing

@Test func steamInstallPlanUsesWinePrefixAndGPTKPath() throws {
    let bottle = Bottle(name: "Steam", path: "/tmp/Steam.bottle", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let plan = SteamAdapter().installPlan(
        bottle: bottle,
        runtime: runtime,
        gptkPath: "/Applications/Game Porting Toolkit",
        installerPath: "/Users/example/Installers/SteamSetup.exe"
    )

    #expect(plan.executable == "/opt/wine/bin/wine")
    #expect(plan.arguments == ["/Users/example/Installers/SteamSetup.exe"])
    #expect(plan.environment["WINEPREFIX"] == "/tmp/Steam.bottle")
    #expect(plan.environment["SWITCHYARD_GPTK_PATH"] == "/Applications/Game Porting Toolkit")
}

@Test func runPlanRequiresConfiguredExecutable() throws {
    let bottle = Bottle(name: "Steam", path: "/tmp/Steam.bottle", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let launcher = Launcher(name: "Steam", kind: .steam, bottleID: bottle.id)
    let profile = LaunchProfile(launcher: launcher, bottle: bottle, runtime: runtime, useGPTK: false, gptkPath: nil)

    #expect(throws: LauncherAdapterError.missingExecutable(.steam)) {
        _ = try SteamAdapter().runPlan(profile: profile)
    }
}
