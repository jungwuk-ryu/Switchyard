import AppCore
import JobEngine
import RuntimeCatalog
import Testing
import Foundation

@Test func jobEngineCreatesInstallPlan() throws {
    let container = Container(name: "Steam", path: "/tmp/Steam.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let plan = try JobEngine().installPlan(
        launcherKind: .steam,
        container: container,
        runtime: runtime,
        gptkPath: nil,
        installerPath: "/tmp/SteamSetup.exe"
    )

    #expect(plan.executable == "/opt/wine/bin/wine")
    #expect(plan.arguments == ["/tmp/SteamSetup.exe"])
    #expect(plan.environment["WINEPREFIX"] == "/tmp/Steam.container")
}

@Test func jobEngineFailsWhenContainerIsMissing() {
    let container = Container(name: "Steam", path: "/tmp/Steam.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let launcher = Launcher(name: "Steam", kind: .steam, containerID: container.id)

    #expect(throws: JobEngineError.missingContainer(container.id)) {
        _ = try JobEngine().runPlan(launcher: launcher, containers: [], runtime: runtime, gptkPath: nil)
    }
}

@Test func jobEngineUsesContainerEnvironmentOverrides() throws {
    let container = Container(
        name: "Steam",
        path: "/tmp/Steam.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        environmentOverrides: ["DXVK_LOG_LEVEL": "none"]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let launcher = Launcher(name: "Steam", kind: .steam, containerID: container.id, executablePath: "/tmp/Steam.exe")

    let plan = try JobEngine().runPlan(launcher: launcher, containers: [container], runtime: runtime, gptkPath: nil)

    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
}

@Test func containerFontInstallerCopiesFontsAndRegistersWineMappings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let containerURL = root.appendingPathComponent("Steam.container", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    try writeInitializedRegistryFiles(to: containerURL)

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
    let container = Container(name: "Steam", path: containerURL.path, wineBuildID: "wine-a", patchsetID: "patch-a")
    let installer = ContainerFontInstaller(catalog: [font], replacements: [replacement])

    let firstResult = try installer.installOpenFontPack(into: container, from: cache)
    let installedFont = containerURL
        .appendingPathComponent("drive_c/windows/Fonts", isDirectory: true)
        .appendingPathComponent(sourceFont.lastPathComponent)
    let systemRegistry = try String(contentsOf: containerURL.appendingPathComponent("system.reg"), encoding: .utf8)
    let userRegistry = try String(contentsOf: containerURL.appendingPathComponent("user.reg"), encoding: .utf8)

    #expect(firstResult.installedFonts == ["Switchyard Sans Test"])
    #expect(FileManager.default.fileExists(atPath: installedFont.path))
    #expect(systemRegistry.contains("\"Switchyard Sans Test (TrueType)\"=\"SwitchyardSans-Regular.ttf\""))
    #expect(systemRegistry.contains("\"Segoe UI\"=\"Switchyard Sans Test\""))
    #expect(userRegistry.contains("[Software\\\\Wine\\\\Fonts\\\\Replacements]"))
    #expect(userRegistry.contains("\"Segoe UI\"=\"Switchyard Sans Test\""))

    let secondResult = try installer.installOpenFontPack(into: container, from: cache)
    #expect(secondResult.installedFonts.isEmpty)
    #expect(secondResult.reusedFonts == ["Switchyard Sans Test"])
}

@Test func containerFontInstallerSkipsUninitializedContainerWithoutCreatingRegistry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let containerURL = root.appendingPathComponent("Fresh.container", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)

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
    let container = Container(name: "Fresh", path: containerURL.path, wineBuildID: "wine-a", patchsetID: "patch-a")
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])

    let result = try installer.installOpenFontPack(into: container, from: cache)

    #expect(result.skippedReason == "Wine has not initialized this container yet.")
    #expect(!FileManager.default.fileExists(atPath: containerURL.appendingPathComponent("system.reg").path))
    #expect(!FileManager.default.fileExists(atPath: containerURL.appendingPathComponent("user.reg").path))
    #expect(!FileManager.default.fileExists(atPath: containerURL.appendingPathComponent("drive_c").path))
}

private func writeInitializedRegistryFiles(to containerURL: URL) throws {
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
    try Data(systemRegistry.utf8).write(to: containerURL.appendingPathComponent("system.reg"))
    try Data(userRegistry.utf8).write(to: containerURL.appendingPathComponent("user.reg"))
}
