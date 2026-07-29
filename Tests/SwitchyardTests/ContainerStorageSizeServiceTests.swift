import Foundation
import Testing
@testable import Switchyard

@Test func containerStorageSizeServiceCountsNestedFilesButNotSymlinkTargets() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let containerURL = rootURL.appendingPathComponent(
        "Test.container",
        isDirectory: true
    )
    let nestedURL = containerURL.appendingPathComponent(
        "drive_c/nested",
        isDirectory: true
    )
    let externalURL = rootURL.appendingPathComponent(
        "external.bin",
        isDirectory: false
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try FileManager.default.createDirectory(
        at: nestedURL,
        withIntermediateDirectories: true
    )
    try Data(repeating: 1, count: 4_096).write(
        to: containerURL.appendingPathComponent("manifest.bin")
    )
    try Data(repeating: 2, count: 8_192).write(
        to: nestedURL.appendingPathComponent("game.bin")
    )
    try Data(repeating: 3, count: 1_048_576).write(to: externalURL)
    try FileManager.default.createSymbolicLink(
        at: containerURL.appendingPathComponent("external-link.bin"),
        withDestinationURL: externalURL
    )

    let byteCount = try ContainerStorageSizeService.calculateByteCount(
        forContainerAt: containerURL
    )
    #expect(byteCount == 12_288)
}
