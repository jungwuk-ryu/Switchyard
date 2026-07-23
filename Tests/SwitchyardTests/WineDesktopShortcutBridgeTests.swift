import AppCore
import Darwin
import Foundation
import Testing
@testable import Switchyard

@MainActor
@Test func desktopShortcutBridgeMaterializesReusesAndRemovesOwnedBundles() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("switchyard-desktop-bridge-\(UUID().uuidString)", isDirectory: true)
    let prefix = root.appendingPathComponent("Test.container", isDirectory: true)
    let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
    let bridgeRoot = root.appendingPathComponent("Bridge", isDirectory: true)
    let wine = root.appendingPathComponent("wine")
    let runner = root.appendingPathComponent("switchyard-runner")
    let wineDesktop = prefix.appendingPathComponent(
        "drive_c/users/steamuser/Desktop",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: wineDesktop, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)

    let source = wineDesktop.appendingPathComponent("Heartopia.url")
    try Data("[InternetShortcut]\nURL=xdt://launch\n".utf8).write(to: source)
    let manifestURL = WineDesktopShortcutFormat.manifestURL(prefixPath: prefix.path)
    try fileManager.createDirectory(
        at: manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
    let windowsPath = #"C:\users\steamuser\Desktop\Heartopia.url"#
    let manifest = """
    \(WineDesktopShortcutFormat.manifestHeader)
    url\t\(hex("Heartopia"))\t\(hex(windowsPath))\t
    """
    try Data(manifest.utf8).write(to: manifestURL)

    let unownedCollision = desktop.appendingPathComponent("Heartopia.app", isDirectory: true)
    try fileManager.createDirectory(at: unownedCollision, withIntermediateDirectories: false)
    let container = Container(
        name: "Test Container",
        path: prefix.path
    )
    let bridge = WineDesktopShortcutBridge(
        fileManager: fileManager,
        rootURL: bridgeRoot,
        desktopURL: desktop
    )

    let first = try bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(first.createdShortcutNames == ["Heartopia"])
    let bundle = desktop.appendingPathComponent(
        "Heartopia — Test Container.app",
        isDirectory: true
    )
    #expect(fileManager.fileExists(atPath: bundle.path))
    #expect(fileManager.fileExists(atPath: unownedCollision.path))
    let info = try #require(Bundle(url: bundle)?.infoDictionary)
    let shortcutID = try #require(info["SwitchyardDesktopShortcutID"] as? String)
    #expect(info["SwitchyardDesktopShortcutOwner"] as? String == "dev.switchyard")
    #expect(info["CFBundleIconFile"] as? String == "Shortcut.icns")
    #expect(shortcutID.count == 64)
    #expect(
        fileManager.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Resources/Shortcut.icns").path
        )
    )
    let signatureCheck = Process()
    signatureCheck.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signatureCheck.arguments = ["--verify", "--strict", bundle.path]
    signatureCheck.standardOutput = FileHandle.nullDevice
    signatureCheck.standardError = FileHandle.nullDevice
    try signatureCheck.run()
    signatureCheck.waitUntilExit()
    #expect(signatureCheck.terminationStatus == 0)

    let routesData = try Data(contentsOf: bridgeRoot.appendingPathComponent("routes-v1.json"))
    let routes = try JSONDecoder().decode(WineDesktopShortcutRouteIndex.self, from: routesData)
    #expect(routes.route(forID: shortcutID)?.windowsShortcutPath == windowsPath)

    let second = try bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(second.createdShortcutNames.isEmpty)
    #expect(second.removedShortcutNames.isEmpty)

    let embeddedHelper = bundle.appendingPathComponent(
        "Contents/MacOS/switchyard-shortcut-handler"
    )
    let expectedHelper = try Data(contentsOf: embeddedHelper)
    try Data("tampered helper\n".utf8).write(to: embeddedHelper)
    let repaired = try bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(repaired.createdShortcutNames == ["Heartopia"])
    #expect(repaired.removedShortcutNames.isEmpty)
    #expect(try Data(contentsOf: embeddedHelper) == expectedHelper)
    let repairedSignatureCheck = Process()
    repairedSignatureCheck.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    repairedSignatureCheck.arguments = ["--verify", "--strict", bundle.path]
    repairedSignatureCheck.standardOutput = FileHandle.nullDevice
    repairedSignatureCheck.standardError = FileHandle.nullDevice
    try repairedSignatureCheck.run()
    repairedSignatureCheck.waitUntilExit()
    #expect(repairedSignatureCheck.terminationStatus == 0)

    try fileManager.removeItem(at: source)
    let third = try bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(third.removedShortcutNames == ["Heartopia — Test Container"])
    #expect(!fileManager.fileExists(atPath: bundle.path))
    #expect(fileManager.fileExists(atPath: unownedCollision.path))
}
