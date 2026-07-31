import AppCore
import Darwin
import Foundation
@testable import JobEngine
import RuntimeCatalog
import Testing

@Test func jobEngineCreatesInstallPlan() throws {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container")
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
    #expect(
        plan.environment[WineDesktopShortcutFormat.manifestEnvironmentKey]
            == WineDesktopShortcutFormat.windowsManifestPath
    )
    #expect(plan.environment[WineDesktopShortcutFormat.privateDesktopEnvironmentKey] == "1")
    #expect(plan.containerDisplayMode == .standard)
}

@Test func jobEngineCreatesWindowsInstallerPlan() throws {
    let container = Container(name: "Epic", path: "/tmp/Epic.container")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().installPlan(
        container: container,
        runtime: runtime,
        gptkPath: nil,
        installerPath: "/tmp/Epic Installer.msi"
    )

    #expect(plan.executable == "/opt/wine/bin/wine")
    #expect(plan.arguments == ["msiexec.exe", "/i", "/tmp/Epic Installer.msi"])
}

@Test func jobEngineUsesExplicitGlobalRuntimeComponentsInsteadOfContainerHistory() throws {
    let gptkRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Switchyard-GPTK-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: gptkRoot) }
    let wineDirectory = gptkRoot.appendingPathComponent(
        "redist/lib/wine",
        isDirectory: true
    )
    let externalDirectory = gptkRoot.appendingPathComponent(
        "redist/lib/external",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: wineDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: externalDirectory.appendingPathComponent(
            "D3DMetal.framework",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    try Data().write(
        to: externalDirectory.appendingPathComponent(
            "libd3dshared.dylib"
        )
    )

    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        lastRuntime: ContainerRuntimeRecord(
            runtimeID: "old-wine",
            patchsetID: "old-patch",
            sourceRevision: "old-source",
            gptkFingerprint: "old-gptk"
        )
    )
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )
    let gptkPath = externalDirectory.path
    let canonicalGPTKPath = gptkRoot
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
    let plan = try JobEngine().installPlan(
        container: container,
        runtime: runtime,
        gptkPath: gptkPath,
        installerPath: "/tmp/Setup.exe"
    )

    #expect(plan.executable == runtime.winePath)
    #expect(
        plan.environment["SWITCHYARD_GPTK_PATH"] == canonicalGPTKPath
    )
    #expect(
        plan.environment["WINEDLLPATH"]
            == "\(canonicalGPTKPath)/redist/lib/wine"
    )
    #expect(
        plan.environment["DYLD_LIBRARY_PATH"]
            == "\(canonicalGPTKPath)/redist/lib/external"
    )
    #expect(
        plan.environment["DYLD_FRAMEWORK_PATH"]
            == "\(canonicalGPTKPath)/redist/lib/external"
    )
}

@Test func jobEngineFailsWhenContainerExecutableIsMissing() {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    #expect(throws: JobEngineError.missingExecutable(container.id)) {
        _ = try JobEngine().runPlan(container: container, runtime: runtime, gptkPath: nil)
    }
}

@Test func jobEngineRunsAdHocExecutableWithoutConfiguredDefault() throws {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container")
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

@Test func jobEngineDoesNotReuseSavedArgumentsForAdHocExecutables() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        executablePath: "/tmp/Toolbox/Toolbox.exe",
        executableArguments: ["-silent"]
    )
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )

    let plan = try JobEngine().runPlan(
        container: container,
        executablePath: "/tmp/Installers/Setup.exe",
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.arguments == ["/tmp/Installers/Setup.exe"])
}

@Test func jobEngineAppliesBattleNetDisplayCompatibilityArguments() throws {
    let container = Container(name: "Battle.net", path: "/tmp/BattleNet.container")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(
        container: container,
        executablePath: "/tmp/BattleNet.container/drive_c/Program Files (x86)/Battle.net/Battle.net.exe",
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.arguments == [
        "/tmp/BattleNet.container/drive_c/Program Files (x86)/Battle.net/Battle.net.exe",
        "--high-dpi-support=1",
        "--force-device-scale-factor=1",
    ])
}

@Test func jobEngineRunsAdHocWindowsInstallerWithArguments() throws {
    let container = Container(name: "Toolbox", path: "/tmp/Toolbox.container")
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(
        container: container,
        executablePath: "/tmp/Installers/Toolbox.msi",
        executableArguments: ["/quiet"],
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.arguments == ["msiexec.exe", "/i", "/tmp/Installers/Toolbox.msi", "/quiet"])
}

@Test func jobEngineUsesContainerEnvironmentOverrides() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
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
        executablePath: "/tmp/Toolbox/Toolbox.exe",
        executableArguments: ["-safe-mode", "-lang", "ko-KR"]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(container: container, runtime: runtime, gptkPath: nil)

    #expect(plan.arguments == ["/tmp/Toolbox/Toolbox.exe", "-safe-mode", "-lang", "ko-KR"])
}

@Test func jobEnginePreservesExplicitlyEmptyArgumentsForDefaultRuns() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        executablePath: "/tmp/Toolbox/Toolbox.exe",
        executableArguments: ["-safe-mode", "-lang", "ko-KR"]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(
        container: container,
        executableArguments: [],
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.arguments == ["/tmp/Toolbox/Toolbox.exe"])
}

@Test func jobEngineCanReplaceAnExistingPrefixSessionBeforeDefaultRun() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
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

@Test func jobEngineConfiguresTheSelectedContainerDisplayMode() throws {
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )

    for displayMode in ContainerDisplayMode.allCases {
        let container = Container(
            name: "Toolbox",
            path: "/tmp/Toolbox.container",
            executablePath: "/tmp/Toolbox/Toolbox.exe",
            displayMode: displayMode
        )

        let plan = try JobEngine().runPlan(
            container: container,
            runtime: runtime,
            gptkPath: nil
        )

        #expect(plan.containerDisplayMode == displayMode)
    }
}

@Test func jobEngineSkipsDisplayConfigurationWhenReusingAnActivePrefix() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        executablePath: "/tmp/Toolbox/Toolbox.exe",
        displayMode: .retinaWithLargerInterface
    )
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )

    let plan = try JobEngine().runPlan(
        container: container,
        runtime: runtime,
        gptkPath: nil,
        configureContainerDisplay: false
    )

    #expect(plan.containerDisplayMode == nil)
}

@Test func jobEnginePreservesDisplayConfigurationForLegacyContainers() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        executablePath: "/tmp/Toolbox/Toolbox.exe",
        displayMode: nil
    )
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )

    let plan = try JobEngine().runPlan(
        container: container,
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.containerDisplayMode == nil)
}

@Test func runtimePreparationUpdatesWithoutRunningStartupProgramsOrFollowingThePrefix() {
    let container = Container(
        name: "Steam",
        path: "/tmp/Steam.container",
        environmentOverrides: ["DXVK_LOG_LEVEL": "none"]
    )
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )

    let plan = JobEngine().runtimePreparationPlan(
        container: container,
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.arguments == ["wineboot.exe", "-u", "-r"])
    #expect(plan.environment["WINEPREFIX"] == container.path)
    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
    #expect(plan.containerDisplayMode == nil)
    #expect(plan.keepLoggingWhilePrefixIsActive == false)
}

@Test func jobEngineTransportsGPUIdentityOnlyForGPTKPlans()
    throws
{
    let fileManager = FileManager.default
    let gptkRoot = fileManager.temporaryDirectory
        .appendingPathComponent(
            "Switchyard-GPU-Plan-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? fileManager.removeItem(at: gptkRoot) }
    try fileManager.createDirectory(
        at: gptkRoot.appendingPathComponent(
            "redist/lib/wine",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    let externalRoot = gptkRoot.appendingPathComponent(
        "redist/lib/external",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: externalRoot.appendingPathComponent(
            "D3DMetal.framework",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    try Data().write(
        to: externalRoot.appendingPathComponent(
            "libd3dshared.dylib"
        )
    )

    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        executablePath: "/tmp/Toolbox.exe"
    )
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: String(repeating: "a", count: 40)
    )
    let snapshot = try jobEngineGPUIdentitySnapshot(
        for: runtime
    )

    let runPlan = try JobEngine().runPlan(
        container: container,
        runtime: runtime,
        gptkPath: gptkRoot.path,
        gptkGPUIdentitySnapshot: snapshot
    )
    let preparationPlan =
        JobEngine().runtimePreparationPlan(
            container: container,
            runtime: runtime,
            gptkPath: gptkRoot.path,
            gptkGPUIdentitySnapshot: snapshot
        )
    let nonGPTKPlan = try JobEngine().runPlan(
        container: container,
        runtime: runtime,
        gptkPath: nil,
        gptkGPUIdentitySnapshot: snapshot
    )

    #expect(runPlan.gptkGPUIdentitySnapshot == snapshot)
    #expect(
        preparationPlan.gptkGPUIdentitySnapshot
            == snapshot
    )
    #expect(nonGPTKPlan.gptkGPUIdentitySnapshot == nil)
}

@Test func jobEngineUsesAdHocExecutableArgumentsForProgramRuns() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
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

private func jobEngineGPUIdentitySnapshot(
    for runtime: RuntimeBuild
) throws -> GPTKGPUIdentitySnapshot {
    let runtimeRoot = URL(
        fileURLWithPath: runtime.winePath
    )
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    let fingerprint =
        try RuntimeGPUIdentityContentFingerprint.make(
            for: runtime
        )
    let helper = try RuntimeGPUIdentityFileEvidence(
        canonicalPath: runtimeRoot
            .appendingPathComponent(
                "libexec/switchyard-host-gpu-info"
            ).path,
        device: 1,
        inode: 2,
        size: 4_096,
        modificationTimeNanoseconds: 1_000,
        mode: 0o100755,
        sha256: String(repeating: "a", count: 64)
    )
    let policy = try RuntimeGPUIdentityFileEvidence(
        canonicalPath: runtimeRoot
            .appendingPathComponent(
                "share/switchyard/gpu_capability_policy.sh"
            ).path,
        device: 1,
        inode: 3,
        size: 1_024,
        modificationTimeNanoseconds: 2_000,
        mode: 0o100644,
        sha256: String(repeating: "b", count: 64)
    )
    let evidence = try RuntimeGPUIdentityEvidence(
        runtimeID: runtime.id,
        runtimeRoot: runtimeRoot.path,
        runtimeContentFingerprint: fingerprint,
        helper: helper,
        policy: policy
    )
    return GPTKGPUIdentitySnapshot(
        cacheKey: try GPTKGPUIdentityCacheKey(
            operatingSystemBuild: "24G90",
            defaultGPURegistryID: 0x100,
            runtime: evidence
        ),
        identity: try HostGPUIdentity(
            vendorID: 0x106B,
            deviceID: 1,
            subsystemID: 0,
            revisionID: 0,
            description: "Apple GPU"
        )
    )
}

@Test func jobEngineRunsWindowsShortcutThroughStartWithContainerEnvironment() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        environmentOverrides: ["DXVK_LOG_LEVEL": "none"]
    )
    let runtime = RuntimeBuild(
        id: "wine-a",
        winePath: "/opt/wine/bin/wine",
        patchsetID: "patch-a",
        sourceRevision: "abc123"
    )
    let shortcutPath =
        #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Toolbox.lnk"#

    let plan = try JobEngine().runPlan(
        container: container,
        executablePath: "start",
        executableArguments: [shortcutPath],
        runtime: runtime,
        gptkPath: nil
    )

    #expect(plan.arguments == ["start", shortcutPath])
    #expect(plan.environment["WINEPREFIX"] == container.path)
    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
    #expect(
        plan.environment[WineDesktopShortcutFormat.privateDesktopEnvironmentKey] == "1"
    )
}

@Test func jobEngineRejectsReservedEnvironmentOverrides() throws {
    let container = Container(
        name: "Toolbox",
        path: "/tmp/Toolbox.container",
        executablePath: "/tmp/Toolbox.exe",
        environmentOverrides: [
            "WINEPREFIX": "/tmp/Other.container",
            "WINEDLLPATH": "/tmp/untrusted-wine",
            "DYLD_LIBRARY_PATH": "/tmp/untrusted-libraries",
            "DYLD_FRAMEWORK_PATH": "/tmp/untrusted-frameworks",
            "SWITCHYARD_PATCHSET_ID": "other",
            "DXVK_LOG_LEVEL": "none"
        ]
    )
    let runtime = RuntimeBuild(id: "wine-a", winePath: "/opt/wine/bin/wine", patchsetID: "patch-a", sourceRevision: "abc123")

    let plan = try JobEngine().runPlan(container: container, runtime: runtime, gptkPath: nil)

    #expect(plan.environment["WINEPREFIX"] == "/tmp/Toolbox.container")
    #expect(plan.environment["WINEDLLPATH"] == nil)
    #expect(plan.environment["DYLD_LIBRARY_PATH"] == nil)
    #expect(plan.environment["DYLD_FRAMEWORK_PATH"] == nil)
    #expect(plan.environment["SWITCHYARD_PATCHSET_ID"] == "patch-a")
    #expect(plan.environment["DXVK_LOG_LEVEL"] == "none")
}

@Test func containerFontInstallerCopiesFontsAndRegistersWineMappings() throws {
    let root = canonicalTestTemporaryDirectory()
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
    let container = Container(name: "Fonts", path: containerURL.path)
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

    let firstSystemRegistryData = try Data(
        contentsOf: containerURL.appendingPathComponent("system.reg")
    )
    let firstUserRegistryData = try Data(
        contentsOf: containerURL.appendingPathComponent("user.reg")
    )
    let secondResult = try installer.installOpenFontPack(into: container, from: cache)
    #expect(secondResult.installedFonts.isEmpty)
    #expect(secondResult.reusedFonts == ["Switchyard Sans Test"])
    #expect(
        try Data(contentsOf: containerURL.appendingPathComponent("system.reg"))
            == firstSystemRegistryData
    )
    #expect(
        try Data(contentsOf: containerURL.appendingPathComponent("user.reg"))
            == firstUserRegistryData
    )
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: installedFont.deletingLastPathComponent().path
        ).allSatisfy { !$0.hasPrefix(".switchyard-font-") }
    )
    #expect(try fontRegistryTemporaryFiles(in: containerURL).isEmpty)
}

@Test func containerFontInstallerSkipsUninitializedContainerWithoutCreatingRegistry() throws {
    let root = canonicalTestTemporaryDirectory()
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
    let container = Container(name: "Fresh", path: containerURL.path)
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])

    let result = try installer.installOpenFontPack(into: container, from: cache)

    #expect(result.skippedReason == "Wine has not initialized this container yet.")
    #expect(!FileManager.default.fileExists(atPath: containerURL.appendingPathComponent("system.reg").path))
    #expect(!FileManager.default.fileExists(atPath: containerURL.appendingPathComponent("user.reg").path))
    #expect(!FileManager.default.fileExists(atPath: containerURL.appendingPathComponent("drive_c").path))
}

@Test func containerFontInstallerRejectsSymlinkedCachedFontAndPreservesExistingFont() throws {
    let root = canonicalTestTemporaryDirectory()
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let containerURL = root.appendingPathComponent("Fonts.container", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    try writeInitializedRegistryFiles(to: containerURL)

    let fontName = "SwitchyardSans-Regular.ttf"
    let outsideFont = outside.appendingPathComponent(fontName)
    try Data("trusted font bytes".utf8).write(to: outsideFont)
    let cachedFont = cache.appendingPathComponent(fontName)
    try FileManager.default.createSymbolicLink(
        at: cachedFont,
        withDestinationURL: outsideFont
    )

    let fontsDirectory = containerURL.appendingPathComponent(
        "drive_c/windows/Fonts",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: fontsDirectory,
        withIntermediateDirectories: true
    )
    let installedFont = fontsDirectory.appendingPathComponent(fontName)
    let originalInstalledBytes = Data("existing font must survive".utf8)
    try originalInstalledBytes.write(to: installedFont)

    let font = makeTestOpenFont(
        fileName: fontName,
        sha256: try OpenFontPackCatalog.sha256Hex(for: outsideFont)
    )
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])
    let container = Container(name: "Fonts", path: containerURL.path)

    #expect(
        throws: ContainerFontInstallerError.unsafeFileSystemEntry(cachedFont.path)
    ) {
        try installer.installOpenFontPack(into: container, from: cache)
    }
    #expect(try Data(contentsOf: installedFont) == originalInstalledBytes)
    #expect(try Data(contentsOf: outsideFont) == Data("trusted font bytes".utf8))
}

@Test func containerFontInstallerRejectsSymlinkedCacheRootComponent() throws {
    let root = canonicalTestTemporaryDirectory()
    let cacheParent = root.appendingPathComponent("cache-parent", isDirectory: true)
    let outsideCache = root.appendingPathComponent("outside-cache", isDirectory: true)
    let linkedCache = cacheParent.appendingPathComponent("font-cache", isDirectory: true)
    let containerURL = root.appendingPathComponent("Fonts.container", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
        at: cacheParent,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: outsideCache,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: containerURL,
        withIntermediateDirectories: true
    )
    try writeInitializedRegistryFiles(to: containerURL)

    let fontName = "SwitchyardSans-Regular.ttf"
    let outsideFont = outsideCache.appendingPathComponent(fontName)
    try Data("trusted font bytes".utf8).write(to: outsideFont)
    try FileManager.default.createSymbolicLink(
        at: linkedCache,
        withDestinationURL: outsideCache
    )

    let font = makeTestOpenFont(
        fileName: fontName,
        sha256: try OpenFontPackCatalog.sha256Hex(for: outsideFont)
    )
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])
    let container = Container(name: "Fonts", path: containerURL.path)

    #expect(
        throws: ContainerFontInstallerError.unsafeFileSystemEntry(linkedCache.path)
    ) {
        try installer.installOpenFontPack(into: container, from: linkedCache)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: containerURL.appendingPathComponent("drive_c").path
        )
    )
}

@Test func containerFontInstallerRejectsSymlinkedContainerRoot() throws {
    let root = canonicalTestTemporaryDirectory()
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let actualContainer = root.appendingPathComponent(
        "Actual.container",
        isDirectory: true
    )
    let linkedContainer = root.appendingPathComponent(
        "Linked.container",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: actualContainer,
        withIntermediateDirectories: true
    )
    try writeInitializedRegistryFiles(to: actualContainer)
    try FileManager.default.createSymbolicLink(
        at: linkedContainer,
        withDestinationURL: actualContainer
    )

    let fontName = "SwitchyardSans-Regular.ttf"
    let sourceFont = cache.appendingPathComponent(fontName)
    try Data("trusted font bytes".utf8).write(to: sourceFont)
    let font = makeTestOpenFont(
        fileName: fontName,
        sha256: try OpenFontPackCatalog.sha256Hex(for: sourceFont)
    )
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])
    let container = Container(name: "Fonts", path: linkedContainer.path)

    #expect(
        throws: ContainerFontInstallerError.unsafeFileSystemEntry(
            linkedContainer.path
        )
    ) {
        try installer.installOpenFontPack(into: container, from: cache)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: actualContainer.appendingPathComponent("drive_c").path
        )
    )
}

@Test func containerFontInstallerRejectsSymlinkedFontsDirectory() throws {
    let root = canonicalTestTemporaryDirectory()
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let outsideFonts = root.appendingPathComponent("outside-fonts", isDirectory: true)
    let containerURL = root.appendingPathComponent("Fonts.container", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: outsideFonts,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: containerURL.appendingPathComponent("drive_c/windows", isDirectory: true),
        withIntermediateDirectories: true
    )
    try writeInitializedRegistryFiles(to: containerURL)

    let fontName = "SwitchyardSans-Regular.ttf"
    let sourceFont = cache.appendingPathComponent(fontName)
    try Data("trusted font bytes".utf8).write(to: sourceFont)
    let fontsDirectory = containerURL.appendingPathComponent(
        "drive_c/windows/Fonts",
        isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
        at: fontsDirectory,
        withDestinationURL: outsideFonts
    )

    let font = makeTestOpenFont(
        fileName: fontName,
        sha256: try OpenFontPackCatalog.sha256Hex(for: sourceFont)
    )
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])
    let container = Container(name: "Fonts", path: containerURL.path)

    #expect(
        throws: ContainerFontInstallerError.unsafeFileSystemEntry(fontsDirectory.path)
    ) {
        try installer.installOpenFontPack(into: container, from: cache)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: outsideFonts.appendingPathComponent(fontName).path
        )
    )
}

@Test func containerFontInstallerRejectsNonRegularCachedFont() throws {
    let root = canonicalTestTemporaryDirectory()
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let containerURL = root.appendingPathComponent("Fonts.container", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    try writeInitializedRegistryFiles(to: containerURL)

    let fontName = "SwitchyardSans-Regular.ttf"
    let cachedFont = cache.appendingPathComponent(fontName, isDirectory: true)
    try FileManager.default.createDirectory(
        at: cachedFont,
        withIntermediateDirectories: false
    )
    let fontsDirectory = containerURL.appendingPathComponent(
        "drive_c/windows/Fonts",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: fontsDirectory,
        withIntermediateDirectories: true
    )
    let installedFont = fontsDirectory.appendingPathComponent(fontName)
    let originalInstalledBytes = Data("existing font must survive".utf8)
    try originalInstalledBytes.write(to: installedFont)

    let font = makeTestOpenFont(fileName: fontName, sha256: String(repeating: "0", count: 64))
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])
    let container = Container(name: "Fonts", path: containerURL.path)

    #expect(
        throws: ContainerFontInstallerError.unsafeFileSystemEntry(cachedFont.path)
    ) {
        try installer.installOpenFontPack(into: container, from: cache)
    }
    #expect(try Data(contentsOf: installedFont) == originalInstalledBytes)
}

@Test func containerFontInstallerRejectsSymlinkedDestinationFont() throws {
    let root = canonicalTestTemporaryDirectory()
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let containerURL = root.appendingPathComponent("Fonts.container", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    try writeInitializedRegistryFiles(to: containerURL)

    let fontName = "SwitchyardSans-Regular.ttf"
    let sourceFont = cache.appendingPathComponent(fontName)
    try Data("trusted font bytes".utf8).write(to: sourceFont)
    let fontsDirectory = containerURL.appendingPathComponent(
        "drive_c/windows/Fonts",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: fontsDirectory,
        withIntermediateDirectories: true
    )
    let outsideFont = outside.appendingPathComponent(fontName)
    let outsideBytes = Data("outside file must survive".utf8)
    try outsideBytes.write(to: outsideFont)
    let installedFont = fontsDirectory.appendingPathComponent(fontName)
    try FileManager.default.createSymbolicLink(
        at: installedFont,
        withDestinationURL: outsideFont
    )

    let font = makeTestOpenFont(
        fileName: fontName,
        sha256: try OpenFontPackCatalog.sha256Hex(for: sourceFont)
    )
    let installer = ContainerFontInstaller(catalog: [font], replacements: [])
    let container = Container(name: "Fonts", path: containerURL.path)

    #expect(
        throws: ContainerFontInstallerError.unsafeFileSystemEntry(installedFont.path)
    ) {
        try installer.installOpenFontPack(into: container, from: cache)
    }
    #expect(try Data(contentsOf: outsideFont) == outsideBytes)
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: installedFont.path
        ) == outsideFont.path
    )
}

@Test func containerFontInstallerRejectsUnreadableRegistryWithoutChangingEitherFile() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let systemRegistryURL = fixture.containerURL.appendingPathComponent("system.reg")
    let userRegistryURL = fixture.containerURL.appendingPathComponent("user.reg")
    let originalSystem = try Data(contentsOf: systemRegistryURL)
    let originalUser = try Data(contentsOf: userRegistryURL)
    guard Darwin.chmod(systemRegistryURL.path, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = Darwin.chmod(systemRegistryURL.path, mode_t(S_IRUSR | S_IWUSR)) }

    do {
        _ = try registryOnlyFontInstaller().installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
        Issue.record("Expected an unreadable registry to fail")
    } catch let error as ContainerFontInstallerError {
        guard case .registryReadFailed(let path, _) = error else {
            Issue.record("Unexpected font installer error: \(error)")
            return
        }
        #expect(path == systemRegistryURL.path)
    }

    guard Darwin.chmod(systemRegistryURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    #expect(try Data(contentsOf: systemRegistryURL) == originalSystem)
    #expect(try Data(contentsOf: userRegistryURL) == originalUser)
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerRejectsInvalidUTF8RegistryWithoutChangingEitherFile() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let systemRegistryURL = fixture.containerURL.appendingPathComponent("system.reg")
    let userRegistryURL = fixture.containerURL.appendingPathComponent("user.reg")
    let originalSystem = try Data(contentsOf: systemRegistryURL)
    var invalidUser = try Data(contentsOf: userRegistryURL)
    invalidUser.append(contentsOf: [0xFF, 0xFE])
    try invalidUser.write(to: userRegistryURL)

    #expect(
        throws: ContainerFontInstallerError.invalidRegistryEncoding(
            userRegistryURL.path
        )
    ) {
        try registryOnlyFontInstaller().installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
    }

    #expect(try Data(contentsOf: systemRegistryURL) == originalSystem)
    #expect(try Data(contentsOf: userRegistryURL) == invalidUser)
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerStopsAtPrefixLockDeadline() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalSystem = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
    )
    let originalUser = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
    )
    let heldLock = try WinePrefixFileLock(
        prefixPath: fixture.containerURL.path,
        mode: .shared
    )
    defer { heldLock.unlock() }

    #expect(throws: WinePrefixFileLockAcquisitionError.timedOut) {
        try registryOnlyFontInstaller(
            lockAcquisitionTimeout: .milliseconds(50)
        ).installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
    }

    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
        ) == originalSystem
    )
    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
        ) == originalUser
    )
}

@Test func containerFontInstallerPreservesRegistriesWhenCommitFailsBeforeFirstReplacement() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalSystem = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
    )
    let originalUser = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
    )
    let installer = registryOnlyFontInstaller { point in
        if point == .beforeFirstRegistryReplacement {
            throw InjectedFontRegistryFailure.expected
        }
    }

    expectRegistryTransactionFailure {
        _ = try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
    }

    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
        ) == originalSystem
    )
    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
        ) == originalUser
    )
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerCleansEarlierTempsWhenStagingFails() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalSystem = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
    )
    let originalUser = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
    )
    let installer = registryOnlyFontInstaller { point in
        if point == .beforeUserRegistryStaging {
            throw InjectedFontRegistryFailure.expected
        }
    }

    #expect(throws: InjectedFontRegistryFailure.expected) {
        try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
    }

    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
        ) == originalSystem
    )
    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
        ) == originalUser
    )
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerRollsBackWhenCommitFailsAfterFirstReplacement() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let originalSystem = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
    )
    let originalUser = try Data(
        contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
    )
    let installer = registryOnlyFontInstaller { point in
        if point == .afterFirstRegistryReplacement {
            throw InjectedFontRegistryFailure.expected
        }
    }

    expectRegistryTransactionFailure {
        _ = try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
    }

    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("system.reg")
        ) == originalSystem
    )
    #expect(
        try Data(
            contentsOf: fixture.containerURL.appendingPathComponent("user.reg")
        ) == originalUser
    )
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerPreservesConcurrentRegistryChange() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let systemRegistryURL = fixture.containerURL.appendingPathComponent("system.reg")
    let userRegistryURL = fixture.containerURL.appendingPathComponent("user.reg")
    let originalUser = try Data(contentsOf: userRegistryURL)
    let concurrentlyChangedSystem = Data(
        """
        WINE REGISTRY Version 2
        #arch=win64
        ; concurrent writer

        """.utf8
    )
    let installer = registryOnlyFontInstaller { point in
        if point == .beforeOriginalRegistryValidation {
            try concurrentlyChangedSystem.write(
                to: systemRegistryURL,
                options: .atomic
            )
        }
    }

    #expect(
        throws: ContainerFontInstallerError.registryChanged(
            systemRegistryURL.path
        )
    ) {
        try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
    }

    #expect(try Data(contentsOf: systemRegistryURL) == concurrentlyChangedSystem)
    #expect(try Data(contentsOf: userRegistryURL) == originalUser)
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerRevalidatesRegistryImmediatelyBeforeReplacement() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let systemRegistryURL = fixture.containerURL.appendingPathComponent("system.reg")
    let userRegistryURL = fixture.containerURL.appendingPathComponent("user.reg")
    let originalUser = try Data(contentsOf: userRegistryURL)
    let concurrentlyChangedSystem = Data(
        """
        WINE REGISTRY Version 2
        #arch=win64
        ; changed immediately before replacement

        """.utf8
    )
    let installer = registryOnlyFontInstaller { point in
        if point == .beforeFirstRegistryReplacement {
            try concurrentlyChangedSystem.write(
                to: systemRegistryURL,
                options: .atomic
            )
        }
    }

    #expect(
        throws: ContainerFontInstallerError.registryChanged(
            systemRegistryURL.path
        )
    ) {
        try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
    }

    #expect(try Data(contentsOf: systemRegistryURL) == concurrentlyChangedSystem)
    #expect(try Data(contentsOf: userRegistryURL) == originalUser)
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerRejectsInPlaceStagedRegistryMutation() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let systemRegistryURL = fixture.containerURL.appendingPathComponent("system.reg")
    let userRegistryURL = fixture.containerURL.appendingPathComponent("user.reg")
    let originalSystem = try Data(contentsOf: systemRegistryURL)
    let originalUser = try Data(contentsOf: userRegistryURL)
    let installer = registryOnlyFontInstaller { point in
        guard point == .beforeFirstRegistryReplacement else {
            return
        }
        let stagedName = try #require(
            FileManager.default
                .contentsOfDirectory(atPath: fixture.containerURL.path)
                .first {
                    $0.hasPrefix(".switchyard-font-registry-system-new-")
                }
        )
        let stagedURL = fixture.containerURL.appendingPathComponent(stagedName)
        let handle = try FileHandle(forWritingTo: stagedURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([0x58]))
        try handle.synchronize()
    }

    do {
        _ = try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
        Issue.record("Expected the modified staged registry to be rejected")
    } catch let error as ContainerFontInstallerError {
        guard case .registryChanged(let path) = error else {
            Issue.record("Unexpected font installer error: \(error)")
            return
        }
        #expect(
            path.contains(".switchyard-font-registry-system-new-")
        )
    }

    #expect(try Data(contentsOf: systemRegistryURL) == originalSystem)
    #expect(try Data(contentsOf: userRegistryURL) == originalUser)
    #expect(try fontRegistryTemporaryFiles(in: fixture.containerURL).isEmpty)
}

@Test func containerFontInstallerSurfacesRegistryRecoveryFailure() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let installer = registryOnlyFontInstaller { point in
        switch point {
        case .afterFirstRegistryReplacement,
             .beforeSystemRegistryRollback:
            throw InjectedFontRegistryFailure.expected
        default:
            break
        }
    }

    do {
        _ = try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
        Issue.record("Expected registry recovery to fail")
    } catch let error as ContainerFontInstallerError {
        guard case .registryRecoveryFailed = error else {
            Issue.record("Unexpected font installer error: \(error)")
            return
        }
    }

    #expect(
        try fontRegistryTemporaryFiles(in: fixture.containerURL)
            .contains { $0.contains("-backup-") }
    )
}

@Test func containerFontInstallerDoesNotOverwriteConcurrentChangeDuringRollback() throws {
    let fixture = try makeFontRegistryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let systemRegistryURL = fixture.containerURL.appendingPathComponent("system.reg")
    let userRegistryURL = fixture.containerURL.appendingPathComponent("user.reg")
    let originalUser = try Data(contentsOf: userRegistryURL)
    let concurrentSystem = Data(
        """
        WINE REGISTRY Version 2
        #arch=win64
        ; concurrent rollback-window update

        """.utf8
    )
    let installer = registryOnlyFontInstaller { point in
        switch point {
        case .afterFirstRegistryReplacement:
            throw InjectedFontRegistryFailure.expected
        case .beforeSystemRegistryRollback:
            try concurrentSystem.write(
                to: systemRegistryURL,
                options: .atomic
            )
        default:
            break
        }
    }

    do {
        _ = try installer.installOpenFontPack(
            into: fixture.container,
            from: fixture.cacheURL
        )
        Issue.record("Expected registry recovery to fail closed")
    } catch let error as ContainerFontInstallerError {
        guard case .registryRecoveryFailed = error else {
            Issue.record("Unexpected font installer error: \(error)")
            return
        }
    }

    #expect(try Data(contentsOf: systemRegistryURL) == concurrentSystem)
    #expect(try Data(contentsOf: userRegistryURL) == originalUser)
    #expect(
        try fontRegistryTemporaryFiles(in: fixture.containerURL)
            .contains { $0.contains("-backup-") }
    )
}

private func canonicalTestTemporaryDirectory() -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let resolvedPath = temporaryPath.withCString { pathPointer -> String in
        guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else {
            return temporaryPath
        }
        defer { Darwin.free(resolvedPointer) }
        return String(cString: resolvedPointer)
    }
    return URL(fileURLWithPath: resolvedPath, isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func makeTestOpenFont(fileName: String, sha256: String) -> OpenFontFile {
    OpenFontFile(
        id: "switchyard-test-font",
        displayName: "Switchyard Sans Test",
        fileName: fileName,
        sourceURL: URL(string: "https://example.invalid/\(fileName)")!,
        sha256: sha256,
        licenseName: "SIL Open Font License 1.1",
        licenseURL: URL(string: "https://openfontlicense.org/")!,
        registryEntries: ["Switchyard Sans Test (TrueType)"]
    )
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

private struct FontRegistryFixture {
    let root: URL
    let cacheURL: URL
    let containerURL: URL
    let container: Container
}

private enum InjectedFontRegistryFailure: Error {
    case expected
}

private func makeFontRegistryFixture() throws -> FontRegistryFixture {
    let root = canonicalTestTemporaryDirectory()
    let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
    let containerURL = root.appendingPathComponent(
        "Registry.container",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: containerURL,
        withIntermediateDirectories: true
    )
    try writeInitializedRegistryFiles(to: containerURL)
    return FontRegistryFixture(
        root: root,
        cacheURL: cacheURL,
        containerURL: containerURL,
        container: Container(name: "Registry", path: containerURL.path)
    )
}

private func registryOnlyFontInstaller(
    lockAcquisitionTimeout: Duration = .seconds(1)
) -> ContainerFontInstaller {
    ContainerFontInstaller(
        catalog: [],
        replacements: [
            FontReplacement(
                requestedFamily: "Segoe UI",
                replacementFamily: "Switchyard Sans Test"
            )
        ],
        lockAcquisitionTimeout: lockAcquisitionTimeout
    )
}

private func registryOnlyFontInstaller(
    lockAcquisitionTimeout: Duration = .seconds(1),
    failureInjector:
        @escaping @Sendable (ContainerFontInstallerFailurePoint) throws -> Void
) -> ContainerFontInstaller {
    ContainerFontInstaller(
        catalog: [],
        replacements: [
            FontReplacement(
                requestedFamily: "Segoe UI",
                replacementFamily: "Switchyard Sans Test"
            )
        ],
        lockAcquisitionTimeout: lockAcquisitionTimeout,
        failureInjector: failureInjector
    )
}

private func expectRegistryTransactionFailure(
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected the registry transaction to fail")
    } catch let error as ContainerFontInstallerError {
        guard case .registryTransactionFailed = error else {
            Issue.record("Unexpected font installer error: \(error)")
            return
        }
    } catch {
        Issue.record("Unexpected registry transaction error: \(error)")
    }
}

private func fontRegistryTemporaryFiles(in containerURL: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: containerURL.path)
        .filter { $0.hasPrefix(".switchyard-font-registry-") }
}
