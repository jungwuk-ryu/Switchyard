import AppCore
import Foundation
import JobEngine
import RuntimeCatalog
import Testing

@Test func jobEngineCreatesInstallPlan() throws {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")
    let plan = try JobEngine().installPlan(
        container: container,
        runtime: runtime,
        gptkPath: nil,
        installerPath: "/tmp/Setup.exe"
    )

    #expect(plan.executable == "/opt/wine/bin/wine")
    #expect(plan.arguments == ["/tmp/Setup.exe"])
    #expect(plan.environment["WINEPREFIX"] == "/tmp/Toolbox.container")
    #expect(
        plan.environment[WineProtocolAssociationFormat.manifestEnvironmentKey]
            == WineProtocolAssociationFormat.windowsManifestPath
    )
}

@Test func jobEngineFailsWhenContainerExecutableIsMissing() {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    #expect(throws: JobEngineError.missingExecutable(container.id)) {
        _ = try JobEngine().runPlan(container: container, runtime: runtime, gptkPath: nil)
    }
}

@Test func jobEngineRunsAdHocExecutableWithoutConfiguredDefault() throws {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(
        container: container,
        executablePath: "/tmp/Installers/Setup.exe",
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.executable == "/opt/wine/bin/wine")
    #expect(plan.arguments == ["/tmp/Installers/Setup.exe"])
    #expect(plan.environment["WINEPREFIX"] == "/tmp/Toolbox.container")
    #expect(plan.workingDirectory == "/tmp/Toolbox.container")
}

@Test func jobEngineUsesContainerEnvironmentOverrides() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: "/tmp/Toolbox.exe",
        environmentOverrides: ["DXVK_LOG_LEVEL": "none"]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(container: container, runtime: runtime, gptkPath: nil)

    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
}

@Test func jobEngineUsesContainerExecutableArgumentsForDefaultRuns() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: "/tmp/Toolbox/Toolbox.exe",
        executableArguments: ["-safe-mode", "-lang", "ko-KR"]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(container: container, runtime: runtime, gptkPath: nil)

    #expect(plan.arguments == ["/tmp/Toolbox/Toolbox.exe", "-safe-mode", "-lang", "ko-KR"])
}

@Test func jobEngineCanReplaceAnExistingPrefixSessionBeforeDefaultRun() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: "/tmp/Toolbox/Toolbox.exe"
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(
        container: container,
        runtime: runtime,
        gptkPath: nil,
        terminateExistingPrefixSession: true
    )

    #expect(plan.terminateExistingPrefixSession == true)
}

@Test func jobEngineUsesAdHocExecutableArgumentsForProgramRuns() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: "/tmp/Toolbox/Toolbox.exe",
        executableArguments: ["-silent"]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(
        container: container,
        executablePath: "/tmp/Tools/Repair.exe",
        executableArguments: ["/repair"],
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.arguments == ["/tmp/Tools/Repair.exe", "/repair"])
}

@Test func jobEngineRejectsReservedEnvironmentOverrides() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: "/tmp/Toolbox.exe",
        environmentOverrides: [
            "WINEPREFIX": "/tmp/Other.container",
            "SWITCHYARD_PATCHSET_ID": "other",
            "DXVK_LOG_LEVEL": "none"
        ]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(container: container, runtime: runtime, gptkPath: nil)

    #expect(plan.environment["WINEPREFIX"] == "/tmp/Toolbox.container")
    #expect(plan.environment["SWITCHYARD_PATCHSET_ID"] == "patch-a")
    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
}

@Test func containerFontInstallerCopiesFontsAndRegistersWineMappings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let containerURL = root.appendingPathComponent("Fonts.container", isDirectory: true)
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
    let container = Container(name: "Fonts", path: containerURL.path, wineBuildID: "wine-a", patchsetID: "patch-a")
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
