import AppCore
import JobEngine
import RuntimeCatalog
import Testing
import Foundation

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

@Test func bottleFontInstallerCopiesFontsAndRegistersWineMappings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let bottleURL = root.appendingPathComponent("Steam.bottle", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
    try writeInitializedRegistryFiles(to: bottleURL)

    let sourceFont = cache.appendingPathComponent("SwitchyardSans-Regular.ttf")
    try Data("fake switchyard test font".utf8).write(to: sourceFont)
    let digest = try OpenFontPackCatalog.sha256Hex(for: sourceFont)
    let font = OpenFontFile(
        id: "switchyard-test-font",
        displayName: "Switchyard Sans Test",
        fileName: sourceFont.lastPathComponent,
        sourceURL: URL(string: "https://example.invalid/SwitchyardSans-Regular.ttf")!,
        sha256: digest,
        licenseName: "SIL Open Font License 1.1",
        licenseURL: URL(string: "https://openfontlicense.org/")!,
        registryEntries: ["Switchyard Sans Test (TrueType)"]
    )
    let replacement = FontReplacement(requestedFamily: "Segoe UI", replacementFamily: "Switchyard Sans Test")
    let bottle = Bottle(name: "Steam", path: bottleURL.path, wineBuildID: "wine-a", patchsetID: "patch-a")
    let installer = BottleFontInstaller(catalog: [font], replacements: [replacement])

    let firstResult = try installer.installOpenFontPack(into: bottle, from: cache)
    let installedFont = bottleURL
        .appendingPathComponent("drive_c/windows/Fonts", isDirectory: true)
        .appendingPathComponent(sourceFont.lastPathComponent)
    let systemRegistry = try String(contentsOf: bottleURL.appendingPathComponent("system.reg"), encoding: .utf8)
    let userRegistry = try String(contentsOf: bottleURL.appendingPathComponent("user.reg"), encoding: .utf8)

    #expect(firstResult.installedFonts == ["Switchyard Sans Test"])
    #expect(FileManager.default.fileExists(atPath: installedFont.path))
    #expect(systemRegistry.contains("\"Switchyard Sans Test (TrueType)\"=\"SwitchyardSans-Regular.ttf\""))
    #expect(systemRegistry.contains("\"Segoe UI\"=\"Switchyard Sans Test\""))
    #expect(userRegistry.contains("[Software\\\\Wine\\\\Fonts\\\\Replacements]"))
    #expect(userRegistry.contains("\"Segoe UI\"=\"Switchyard Sans Test\""))

    let secondResult = try installer.installOpenFontPack(into: bottle, from: cache)
    #expect(secondResult.installedFonts.isEmpty)
    #expect(secondResult.reusedFonts == ["Switchyard Sans Test"])
}

@Test func bottleFontInstallerSkipsUninitializedBottleWithoutCreatingRegistry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let bottleURL = root.appendingPathComponent("Fresh.bottle", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)

    let sourceFont = cache.appendingPathComponent("SwitchyardSans-Regular.ttf")
    try Data("fake switchyard test font".utf8).write(to: sourceFont)
    let digest = try OpenFontPackCatalog.sha256Hex(for: sourceFont)
    let font = OpenFontFile(
        id: "switchyard-test-font",
        displayName: "Switchyard Sans Test",
        fileName: sourceFont.lastPathComponent,
        sourceURL: URL(string: "https://example.invalid/SwitchyardSans-Regular.ttf")!,
        sha256: digest,
        licenseName: "SIL Open Font License 1.1",
        licenseURL: URL(string: "https://openfontlicense.org/")!,
        registryEntries: ["Switchyard Sans Test (TrueType)"]
    )
    let bottle = Bottle(name: "Fresh", path: bottleURL.path, wineBuildID: "wine-a", patchsetID: "patch-a")
    let installer = BottleFontInstaller(catalog: [font], replacements: [])

    let result = try installer.installOpenFontPack(into: bottle, from: cache)

    #expect(result.skippedReason == "Wine has not initialized this bottle yet.")
    #expect(!FileManager.default.fileExists(atPath: bottleURL.appendingPathComponent("system.reg").path))
    #expect(!FileManager.default.fileExists(atPath: bottleURL.appendingPathComponent("user.reg").path))
    #expect(!FileManager.default.fileExists(atPath: bottleURL.appendingPathComponent("drive_c").path))
}

private func writeInitializedRegistryFiles(to bottleURL: URL) throws {
    let systemRegistry = """
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\\\Machine

    #arch=win64

    """
    let userRegistry = """
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000

    #arch=win64

    """
    try Data(systemRegistry.utf8).write(to: bottleURL.appendingPathComponent("system.reg"))
    try Data(userRegistry.utf8).write(to: bottleURL.appendingPathComponent("user.reg"))
}
