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

    let result = locator.diagnose(gptkPath: nil, winePath: root.path, patchSeriesPath: "/definitely/missing/series")
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })
    #expect(wineCheck.status == .ok)
    #expect(wineCheck.result.contains(wine.path))
}

@Test func missingPatchSeriesPreventsLaunchReadiness() {
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: nil, patchSeriesPath: "/definitely/missing/series")
    #expect(result.0.patchset == .missing)
    #expect(!result.0.canLaunch)
}
