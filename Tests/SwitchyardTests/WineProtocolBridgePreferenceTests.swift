import AppCore
import Foundation
import Testing
@testable import Switchyard

@MainActor
@Test func protocolRecoveryRequestCarriesExplicitRosettaAVXPreference() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(
            "switchyard-protocol-preference-\(UUID().uuidString)",
            isDirectory: true
        )
    let prefix = root.appendingPathComponent("Test.container", isDirectory: true)
    let wine = root.appendingPathComponent("wine")
    let runner = root.appendingPathComponent("switchyard-runner")
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: runner.path
    )

    let container = Container(
        name: "Test Container",
        path: prefix.path,
        environmentOverrides: [
            RosettaAVXAdvertisingPolicy.environmentKey: "0"
        ]
    )
    let bridge = WineProtocolBridge(
        fileManager: fileManager,
        rootURL: root.appendingPathComponent("Bridge", isDirectory: true)
    )

    let request = try bridge.makeCallbackRecoveryRequest(
        rawURL: "xdt://callback",
        containerID: container.id,
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path,
        handlerExecutablePath: nil
    )

    #expect(request.rosettaAVXAdvertisingPreference == .disabled)
}
