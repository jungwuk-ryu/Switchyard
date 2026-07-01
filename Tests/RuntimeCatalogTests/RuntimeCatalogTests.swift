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

@Test func missingPatchSeriesPreventsLaunchReadiness() {
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: nil, patchSeriesPath: "/definitely/missing/series")
    #expect(result.0.patchset == .missing)
    #expect(!result.0.canLaunch)
}
