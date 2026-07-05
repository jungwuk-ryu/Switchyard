import CryptoKit
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

@Test func preferredWineExecutablePathTracksLatestManagedRuntimeCache() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let patchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let oldRoot = cacheRoot.appendingPathComponent("switchyard-local-old", isDirectory: true)
    let newRoot = cacheRoot.appendingPathComponent("switchyard-local-new", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: patchRoot)
    }

    let patchSeries = try createPatchSeries(at: patchRoot)
    let oldWine = try createSwitchyardWineRuntime(
        at: oldRoot,
        peArchitectures: ["i386", "x86_64"],
        patchQueueDigest: patchSeries.digest
    )
    let newWine = try createSwitchyardWineRuntime(
        at: newRoot,
        peArchitectures: ["i386", "x86_64"],
        patchQueueDigest: patchSeries.digest
    )
    try setManifestModificationDate(at: oldRoot, to: Date(timeIntervalSince1970: 100))
    try setManifestModificationDate(at: newRoot, to: Date(timeIntervalSince1970: 200))

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: nil) == newWine.path)
    #expect(locator.preferredWineExecutablePath(for: oldWine.path) == newWine.path)
    #expect(locator.preferredWineExecutablePath(for: oldWine.path, patchSeriesPath: patchSeries.seriesURL.path) == newWine.path)
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

@Test func switchyardWineRuntimeReportsWoW64PEArchitectures() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let wine = try createSwitchyardWineRuntime(at: root, peArchitectures: ["i386", "x86_64"])
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: root.path, patchSeriesPath: "/definitely/missing/series")
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
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: root.path, patchSeriesPath: "/definitely/missing/series")
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })

    #expect(wineCheck.status == .warning)
    #expect(wineCheck.result.contains("missing PE architecture(s): i386"))
}

@Test func switchyardWineRuntimePatchDigestMismatchReportsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let patchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: patchRoot)
    }

    try createSwitchyardWineRuntime(at: root, peArchitectures: ["i386", "x86_64"], patchQueueDigest: "old-digest")
    try FileManager.default.createDirectory(at: patchRoot, withIntermediateDirectories: true)
    try Data("current.patch\n".utf8).write(to: patchRoot.appendingPathComponent("series"))
    try Data("diff --git a/file b/file\n".utf8).write(to: patchRoot.appendingPathComponent("current.patch"))

    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: root.path, patchSeriesPath: patchRoot.appendingPathComponent("series").path)
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })

    #expect(result.0.wine == .warning)
    #expect(!result.0.canLaunch)
    #expect(wineCheck.result.contains("old-digest"))
    #expect(wineCheck.result.contains("current queue"))
}

@Test func missingPatchSeriesPreventsLaunchReadiness() {
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: nil, patchSeriesPath: "/definitely/missing/series")
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
    patchQueueDigest: String? = nil
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
      "executable": "\(wine.path)"\(patchQueueDigest.map { ",\n      \"patchQueueDigest\": \"\($0)\"" } ?? "")
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

private func createPatchSeries(at root: URL) throws -> (seriesURL: URL, digest: String) {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let seriesURL = root.appendingPathComponent("series")
    let patchURL = root.appendingPathComponent("current.patch")
    try Data("current.patch\n".utf8).write(to: seriesURL)
    try Data("diff --git a/file b/file\n".utf8).write(to: patchURL)
    return (seriesURL, try patchQueueDigest(forSeriesAt: seriesURL))
}

private func patchQueueDigest(forSeriesAt seriesURL: URL) throws -> String {
    let seriesData = try Data(contentsOf: seriesURL)
    let seriesHash = sha256Hex(seriesData)
    let patchDirectoryURL = seriesURL.deletingLastPathComponent()
    let seriesText = String(decoding: seriesData, as: UTF8.self)
    var digestInput = Data()

    digestInput.append(contentsOf: "series \(seriesHash)\n".utf8)
    for patchName in seriesText.components(separatedBy: .newlines) {
        guard !patchName.isEmpty, !patchName.hasPrefix("#") else { continue }
        let patchURL = patchDirectoryURL.appendingPathComponent(patchName)
        let patchData = try Data(contentsOf: patchURL)
        digestInput.append(contentsOf: "\(patchName) \(sha256Hex(patchData))\n".utf8)
    }

    return String(sha256Hex(digestInput).prefix(12))
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
