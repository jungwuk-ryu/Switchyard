import RuntimeCatalog
import Testing
import Foundation

@Test func missingGPTKPathReportsMissing() {
    let locator = RuntimeLocator()
    let result = locator.validateGPTK(at: nil)
    #expect(result.status == .missing)
}

@Test func gptkMarkerProducesFingerprint() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let marker = root.appendingPathComponent("libd3dmetal.dylib")
    try Data().write(to: marker)

    let result = RuntimeLocator().validateGPTK(at: root.path)
    #expect(result.status == .ok)
    #expect(result.fingerprint != nil)
}

@Test func regularFileGPTKPathReportsMissing() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)

    let result = RuntimeLocator().validateGPTK(at: file.path)
    #expect(result.status == .missing)
}

@Test func gptkDiskImagePathReportsWarningWhenProvided() {
    guard let path = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_GPTK_DMG"], !path.isEmpty else {
        return
    }

    let result = RuntimeLocator().validateGPTK(at: path)
    #expect(result.status == .warning)
    #expect(result.fingerprint != nil)
}

@Test func gptkDiskImageCanBeImportedWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_GPTK_DMG"], !path.isEmpty else {
        return
    }

    let importRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: importRoot) }

    let locator = RuntimeLocator()
    let importedPath = try locator.importGPTKDiskImage(at: path, to: importRoot.path)
    let result = locator.validateGPTK(at: importedPath)

    #expect(result.status == .ok)
    #expect(result.fingerprint != nil)
}

@Test func wineDirectorySelectionResolvesBinWineExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let wine = bin.appendingPathComponent("wine")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: wine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

    let locator = RuntimeLocator()
    #expect(locator.resolveWineExecutablePath(for: root.path) == wine.path)

    let result = locator.diagnose(gptkPath: nil, winePath: root.path)
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })
    #expect(wineCheck.status == .ok)
    #expect(wineCheck.result.contains(wine.path))
}

@Test func preferredWineExecutablePathTracksLatestManagedRuntimeCache() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let oldRoot = cacheRoot.appendingPathComponent("switchyard-local-old", isDirectory: true)
    let newRoot = cacheRoot.appendingPathComponent("switchyard-local-new", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let sourceRevision = String(repeating: "a", count: 40)
    let oldWine = try createSwitchyardWineRuntime(
        at: oldRoot,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: sourceRevision
    )
    let newWine = try createSwitchyardWineRuntime(
        at: newRoot,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: sourceRevision
    )
    try setManifestModificationDate(at: oldRoot, to: Date(timeIntervalSince1970: 100))
    try setManifestModificationDate(at: newRoot, to: Date(timeIntervalSince1970: 200))

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: nil) == newWine.path)
    #expect(locator.preferredWineExecutablePath(for: oldWine.path) == newWine.path)
    #expect(locator.preferredWineExecutablePath(for: oldWine.path, expectedSourceRevision: sourceRevision) == newWine.path)
}

@Test func preferredWineExecutablePathRecoversDeletedManagedRuntimeSelection() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheRuntimeRoot = cacheRoot.appendingPathComponent("switchyard-local-new", isDirectory: true)
    let deletedManagedWine = cacheRoot
        .appendingPathComponent("switchyard-local-deleted", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("switchyard-wine")
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let newWine = try createSwitchyardWineRuntime(at: cacheRuntimeRoot, peArchitectures: ["i386", "x86_64"])

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: deletedManagedWine.path) == newWine.path)
}

@Test func preferredWineExecutablePathKeepsExternalWineSelection() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheRuntimeRoot = cacheRoot.appendingPathComponent("switchyard-local-new", isDirectory: true)
    let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let externalBin = externalRoot.appendingPathComponent("bin", isDirectory: true)
    let externalWine = externalBin.appendingPathComponent("wine")
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: externalRoot)
    }

    try createSwitchyardWineRuntime(at: cacheRuntimeRoot, peArchitectures: ["i386", "x86_64"])
    try FileManager.default.createDirectory(at: externalBin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: externalWine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: externalRoot.path) == externalWine.path)
}

@Test func pinnedSourcePolicyRejectsUnverifiedExternalWine() throws {
    let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let externalBin = externalRoot.appendingPathComponent("bin", isDirectory: true)
    let externalWine = externalBin.appendingPathComponent("wine")
    defer { try? FileManager.default.removeItem(at: externalRoot) }

    try FileManager.default.createDirectory(at: externalBin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: externalWine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)

    let locator = RuntimeLocator()
    let result = locator.diagnose(
        gptkPath: nil,
        winePath: externalWine.path,
        expectedSourceRevision: String(repeating: "e", count: 40)
    )
    let sourceCheck = try #require(result.1.first { $0.id == "runtime-source" })
    let runtime = locator.runtimeBuild(for: externalWine.path)

    #expect(result.0.patchset == .warning)
    #expect(!result.0.canLaunch)
    #expect(sourceCheck.result.contains("cannot be verified"))
    #expect(runtime.id == "external-unverified")
    #expect(runtime.patchsetID == "external-unverified")
    #expect(runtime.sourceRevision.isEmpty)
}

@Test func runtimeBuildUsesManifestIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let revision = String(repeating: "f", count: 40)
    let wine = try createSwitchyardWineRuntime(
        at: root,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: revision
    )

    let runtime = RuntimeLocator().runtimeBuild(for: wine.path)

    #expect(runtime.id == "switchyard-test-runtime")
    #expect(runtime.patchsetID == "switchyard-test-patchset")
    #expect(runtime.sourceRevision == revision)
    #expect(runtime.winePath == wine.path)
}

@Test func switchyardWineRuntimeReportsWoW64PEArchitectures() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let wine = try createSwitchyardWineRuntime(at: root, peArchitectures: ["i386", "x86_64"])
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: root.path)
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })

    #expect(wineCheck.status == .ok)
    #expect(wineCheck.result.contains("Switchyard Wine runtime"))
    #expect(wineCheck.result.contains("i386"))
    #expect(wineCheck.result.contains("x86_64"))
    #expect(wineCheck.result.contains(wine.path))
}

@Test func switchyardWineRuntimeMissingI386ReportsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try createSwitchyardWineRuntime(at: root, peArchitectures: ["x86_64"])
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: root.path)
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })

    #expect(wineCheck.status == .warning)
    #expect(wineCheck.result.contains("missing PE architecture(s): i386"))
}

@Test func switchyardWineRuntimeSourceMismatchReportsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let oldRevision = String(repeating: "a", count: 40)
    let expectedRevision = String(repeating: "b", count: 40)
    try createSwitchyardWineRuntime(
        at: root,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: oldRevision
    )

    let result = RuntimeLocator().diagnose(
        gptkPath: nil,
        winePath: root.path,
        expectedSourceRevision: expectedRevision
    )
    let sourceCheck = try #require(result.1.first { $0.id == "runtime-source" })

    #expect(result.0.wine == .ok)
    #expect(result.0.patchset == .warning)
    #expect(!result.0.canLaunch)
    #expect(sourceCheck.result.contains(oldRevision.prefix(12)))
    #expect(sourceCheck.result.contains(expectedRevision.prefix(12)))
}

@Test func switchyardWineRuntimeDirtySourceReportsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceRevision = String(repeating: "c", count: 40)
    try createSwitchyardWineRuntime(
        at: root,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: sourceRevision,
        sourceDirty: true
    )

    let result = RuntimeLocator().diagnose(
        gptkPath: nil,
        winePath: root.path,
        expectedSourceRevision: sourceRevision
    )
    let sourceCheck = try #require(result.1.first { $0.id == "runtime-source" })

    #expect(result.0.patchset == .warning)
    #expect(sourceCheck.result.contains("dirty source tree"))
}

@Test func missingRuntimeSourcePreventsLaunchReadiness() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let result = RuntimeLocator(runtimeCacheRoot: cacheRoot).diagnose(
        gptkPath: nil,
        winePath: nil,
        expectedSourceRevision: String(repeating: "d", count: 40)
    )
    #expect(result.0.patchset == .missing)
    #expect(!result.0.canLaunch)
}

@Test func openFontPackDiagnoseReportsMissingCacheAsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let status = OpenFontPackCatalog.diagnose(cacheRoot: root)

    #expect(status.status == .warning)
    #expect(status.missingFonts.count == OpenFontPackCatalog.files.count)
}

@discardableResult
private func createSwitchyardWineRuntime(
    at root: URL,
    peArchitectures: [String],
    sourceRevision: String = String(repeating: "a", count: 40),
    sourceDirty: Bool = false
) throws -> URL {
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let wine = bin.appendingPathComponent("wine")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: wine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

    for architecture in peArchitectures {
        let peDirectory = root
            .appendingPathComponent("lib/wine", isDirectory: true)
            .appendingPathComponent("\(architecture)-windows", isDirectory: true)
        try FileManager.default.createDirectory(at: peDirectory, withIntermediateDirectories: true)
        try Data().write(to: peDirectory.appendingPathComponent("ntdll.dll"))
    }

    let quotedArchitectures = peArchitectures
        .map { "\"\($0)\"" }
        .joined(separator: ", ")
    let manifest = """
    {
      "id": "switchyard-test-runtime",
      "buildProfile": "switchyard-wow64-pe",
      "peArchitectures": [\(quotedArchitectures)],
      "executable": "\(wine.path)",
      "sourceRepository": "https://github.com/jungwuk-ryu/switchyard-wine",
      "sourceRevision": "\(sourceRevision)",
      "sourceDirty": \(sourceDirty),
      "patchsetID": "switchyard-test-patchset"
    }
    """
    try Data(manifest.utf8).write(to: root.appendingPathComponent("switchyard-runtime.json"))
    return wine
}

private func setManifestModificationDate(at runtimeRoot: URL, to date: Date) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: runtimeRoot.appendingPathComponent("switchyard-runtime.json").path
    )
}
