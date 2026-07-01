import AppCore
import JobEngine
import Testing

@Test func jobEngineCreatesInstallPlan() throws {
    let bottle = Bottle(name: "Steam", path: "/tmp/Steam.bottle", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let plan = try JobEngine().installPlan(
        launcherKind: .steam,
        bottle: bottle,
        runtime: runtime,
        gptkPath: nil,
        installerPath: "/tmp/SteamSetup.exe"
    )

    #expect(plan.executable == "/opt/wine/bin/wine")
    #expect(plan.arguments == ["/tmp/SteamSetup.exe"])
    #expect(plan.environment["WINEPREFIX"] == "/tmp/Steam.bottle")
}

@Test func jobEngineFailsWhenBottleIsMissing() {
    let bottle = Bottle(name: "Steam", path: "/tmp/Steam.bottle", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let launcher = Launcher(name: "Steam", kind: .steam, bottleID: bottle.id)

    #expect(throws: JobEngineError.missingBottle(bottle.id)) {
        _ = try JobEngine().runPlan(launcher: launcher, bottles: [], runtime: runtime, gptkPath: nil)
    }
}
