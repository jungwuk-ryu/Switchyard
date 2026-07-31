import AppCore
import Foundation
import Testing
@testable import Switchyard

@Suite("Wine manifest service preflight")
struct WineManifestPreflightTests {
    @Test func boundedReaderKeepsTheValidatedDescriptorWhenThePathIsReplaced() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-manifest-replacement-\(UUID().uuidString)")
        let manifestURL = root.appendingPathComponent("manifest.txt")
        let originalContents = WineProtocolAssociationFormat.manifestHeader + "\nxdt\n"
        let replacementContents = String(
            repeating: "x",
            count: WineProtocolAssociationFormat.maximumManifestBytes + 1
        )
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(originalContents.utf8).write(to: manifestURL)
        var replacementError: String?

        let contents = WineManifestFileReader.contents(
            at: manifestURL,
            insidePrefix: root.path,
            maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes,
            afterFileValidation: {
                do {
                    try fileManager.removeItem(at: manifestURL)
                    try Data(replacementContents.utf8).write(to: manifestURL)
                } catch {
                    replacementError = error.localizedDescription
                }
            }
        )

        #expect(replacementError == nil)
        #expect(contents == originalContents)
        #expect(
            try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == replacementContents.utf8.count
        )
    }

    @Test func boundedReaderRejectsAValidatedDescriptorThatGrowsPastTheLimit() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-manifest-growth-\(UUID().uuidString)")
        let manifestURL = root.appendingPathComponent("manifest.txt")
        let originalContents = WineProtocolAssociationFormat.manifestHeader + "\nxdt\n"
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(originalContents.utf8).write(to: manifestURL)
        var growthError: String?

        let contents = WineManifestFileReader.contents(
            at: manifestURL,
            insidePrefix: root.path,
            maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes,
            afterFileValidation: {
                do {
                    let handle = try FileHandle(forWritingTo: manifestURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(
                        contentsOf: Data(
                            repeating: 0x61,
                            count: WineProtocolAssociationFormat.maximumManifestBytes
                        )
                    )
                } catch {
                    growthError = error.localizedDescription
                }
            }
        )

        #expect(growthError == nil)
        #expect(contents == nil)
    }

    @Test func boundedReaderRejectsSymbolicLinksEvenWhenTheirTargetIsContained() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-manifest-symlink-\(UUID().uuidString)")
        let targetURL = root.appendingPathComponent("target.txt")
        let manifestURL = root.appendingPathComponent("manifest.txt")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(WineProtocolAssociationFormat.manifestHeader.utf8).write(to: targetURL)
        try fileManager.createSymbolicLink(at: manifestURL, withDestinationURL: targetURL)

        #expect(
            WineManifestFileReader.contents(
                at: manifestURL,
                insidePrefix: root.path,
                maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
            ) == nil
        )
    }

    @Test func boundedReaderWalksAnOrdinaryContainedPathAndRejectsRebasedPaths() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-manifest-contained-\(UUID().uuidString)")
        let prefix = root.appendingPathComponent("Test.container", isDirectory: true)
        let manifestURL = prefix.appendingPathComponent("a/b/manifest.txt")
        let rebasedTargetURL = prefix.appendingPathComponent("rebased.txt")
        let outsideURL = root.appendingPathComponent("Outside/manifest.txt")
        let contents = WineProtocolAssociationFormat.manifestHeader + "\nxdt\n"
        defer { try? fileManager.removeItem(at: root) }

        for url in [manifestURL, rebasedTargetURL, outsideURL] {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }

        #expect(
            WineManifestFileReader.contents(
                at: manifestURL,
                insidePrefix: prefix.path,
                maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
            ) == contents
        )
        #expect(
            WineManifestFileReader.contents(
                at: URL(fileURLWithPath: prefix.path + "/a/../rebased.txt"),
                insidePrefix: prefix.path,
                maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
            ) == nil
        )
        #expect(
            WineManifestFileReader.contents(
                at: outsideURL,
                insidePrefix: prefix.path,
                maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
            ) == nil
        )
        #expect(
            WineManifestFileReader.contents(
                at: manifestURL,
                insidePrefix: "relative-prefix",
                maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
            ) == nil
        )
    }

    @Test func boundedReaderStaysInOpenedTreeWhenAnIntermediatePathBecomesASymlink() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-manifest-directory-race-\(UUID().uuidString)")
        let prefix = root.appendingPathComponent("Test.container", isDirectory: true)
        let windowsURL = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        let retainedWindowsURL = prefix.appendingPathComponent(
            "drive_c/windows-retained",
            isDirectory: true
        )
        let manifestURL = windowsURL.appendingPathComponent("temp/manifest.txt")
        let outsideWindowsURL = root.appendingPathComponent("OutsideWindows", isDirectory: true)
        let outsideManifestURL = outsideWindowsURL.appendingPathComponent("temp/manifest.txt")
        let originalContents = WineProtocolAssociationFormat.manifestHeader + "\noriginal\n"
        let outsideContents = WineProtocolAssociationFormat.manifestHeader + "\noutside\n"
        defer { try? fileManager.removeItem(at: root) }

        for (url, value) in [
            (manifestURL, originalContents),
            (outsideManifestURL, outsideContents)
        ] {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: url)
        }
        var swapError: String?
        var didSwap = false

        let contents = WineManifestFileReader.contents(
            at: manifestURL,
            insidePrefix: prefix.path,
            maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes,
            afterDirectoryValidation: { openedPath in
                guard openedPath == "drive_c/windows" else { return }
                do {
                    try fileManager.moveItem(at: windowsURL, to: retainedWindowsURL)
                    try fileManager.createSymbolicLink(
                        at: windowsURL,
                        withDestinationURL: outsideWindowsURL
                    )
                    didSwap = true
                } catch {
                    swapError = error.localizedDescription
                }
            }
        )

        #expect(swapError == nil)
        #expect(didSwap)
        #expect(contents == originalContents)
        #expect(try String(contentsOf: manifestURL, encoding: .utf8) == outsideContents)
    }

    @MainActor
    @Test func protocolBridgePreflightsSizeAndRejectsOverCardinalityWithoutHandlers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-protocol-limits-\(UUID().uuidString)", isDirectory: true)
        let oversizedPrefix = root.appendingPathComponent("Oversized.container", isDirectory: true)
        let overCardinalityPrefix = root.appendingPathComponent(
            "OverCardinality.container",
            isDirectory: true
        )
        let bridgeRoot = root.appendingPathComponent("Bridge", isDirectory: true)
        let wine = root.appendingPathComponent("wine")
        let runner = root.appendingPathComponent("switchyard-runner")
        let staleHandler = bridgeRoot.appendingPathComponent(
            "Handlers/dev.switchyard.protocol.\(String(repeating: "a", count: 24)).app",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        try makeExecutable(at: wine, fileManager: fileManager)
        try makeExecutable(at: runner, fileManager: fileManager)
        try fileManager.createDirectory(at: staleHandler, withIntermediateDirectories: true)
        let oversizedManifestURL = WineProtocolAssociationFormat.manifestURL(
            prefixPath: oversizedPrefix.path
        )
        try writeSparseManifest(
            header: WineProtocolAssociationFormat.manifestHeader,
            byteCount: WineProtocolAssociationFormat.maximumManifestBytes + 1,
            to: oversizedManifestURL,
            fileManager: fileManager
        )
        let overCardinalityManifestURL = WineProtocolAssociationFormat.manifestURL(
            prefixPath: overCardinalityPrefix.path
        )
        try fileManager.createDirectory(
            at: overCardinalityManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let overCardinalityManifest = (
            [WineProtocolAssociationFormat.manifestHeader]
                + (0...WineProtocolAssociationFormat.maximumSchemes).map { "scheme\($0)" }
        ).joined(separator: "\n")
        try Data(overCardinalityManifest.utf8).write(to: overCardinalityManifestURL)

        let oversizedContainer = Container(name: "Oversized", path: oversizedPrefix.path)
        let overCardinalityContainer = Container(
            name: "Over cardinality",
            path: overCardinalityPrefix.path
        )
        let bridge = WineProtocolBridge(fileManager: fileManager, rootURL: bridgeRoot)
        let result = try bridge.refresh(
            containers: [oversizedContainer, overCardinalityContainer],
            winePath: wine.path,
            runnerPath: runner.path
        )

        #expect(result.newlyRegisteredSchemes.isEmpty)
        #expect(!bridge.hasRegisteredScheme("scheme0", in: oversizedContainer))
        #expect(!bridge.hasRegisteredScheme("scheme0", in: overCardinalityContainer))
        let routeData = try Data(contentsOf: bridgeRoot.appendingPathComponent("routes-v1.json"))
        let routes = try JSONDecoder().decode(WineProtocolRouteIndex.self, from: routeData)
        #expect(routes.routes.isEmpty)
        let handlerEntries = (try? fileManager.contentsOfDirectory(
            at: bridgeRoot.appendingPathComponent("Handlers", isDirectory: true),
            includingPropertiesForKeys: nil
        )) ?? []
        #expect(handlerEntries.isEmpty)
        #expect(!fileManager.fileExists(atPath: staleHandler.path))
    }

    @MainActor
    @Test func invalidDesktopSourcesDoNotConsumeTheGlobalCandidateLimit() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(
                "switchyard-desktop-candidate-limit-\(UUID().uuidString)",
                isDirectory: true
            )
        let invalidPrefix = root.appendingPathComponent("Invalid.container", isDirectory: true)
        let validPrefix = root.appendingPathComponent("Valid.container", isDirectory: true)
        let invalidManifestURL = WineDesktopShortcutFormat.manifestURL(
            prefixPath: invalidPrefix.path
        )
        let validManifestURL = WineDesktopShortcutFormat.manifestURL(prefixPath: validPrefix.path)
        let validWindowsPath = #"C:\users\steamuser\Desktop\Valid.url"#
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: invalidManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let invalidManifest = (
            [WineDesktopShortcutFormat.manifestHeader]
                + (0..<WineDesktopShortcutFormat.maximumEntries).map { index in
                    desktopManifestLine(
                        name: String(format: "A%03d", index),
                        windowsPath:
                            #"C:\users\steamuser\Desktop\Missing \#(index).url"#
                    )
                }
        ).joined(separator: "\n")
        try Data(invalidManifest.utf8).write(to: invalidManifestURL)

        try fileManager.createDirectory(
            at: validManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let validManifest = [
            WineDesktopShortcutFormat.manifestHeader,
            desktopManifestLine(name: "ZZZ Valid", windowsPath: validWindowsPath)
        ].joined(separator: "\n")
        try Data(validManifest.utf8).write(to: validManifestURL)
        let validSourceURL = validPrefix.appendingPathComponent(
            "drive_c/users/steamuser/Desktop/Valid.url"
        )
        try fileManager.createDirectory(
            at: validSourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("[InternetShortcut]\nURL=xdt://launch\n".utf8).write(to: validSourceURL)

        let invalidContainer = Container(name: "Invalid", path: invalidPrefix.path)
        let validContainer = Container(name: "Valid", path: validPrefix.path)
        let bridge = WineDesktopShortcutBridge(
            fileManager: fileManager,
            rootURL: root.appendingPathComponent("Bridge", isDirectory: true),
            desktopURL: root.appendingPathComponent("Desktop", isDirectory: true)
        )
        let routes = bridge.desiredShortcutRoutesForTesting(
            containers: [invalidContainer, validContainer],
            winePath: "/test/wine",
            runnerPath: "/test/runner"
        )

        #expect(routes.count == 1)
        #expect(routes.first?.containerID == validContainer.id)
        #expect(routes.first?.windowsShortcutPath == validWindowsPath)
    }

    @MainActor
    @Test func desktopBridgePreflightsSizeAndRejectsOverCardinalityWithoutArtifacts()
        async throws
    {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-desktop-limits-\(UUID().uuidString)", isDirectory: true)
        let oversizedPrefix = root.appendingPathComponent("Oversized.container", isDirectory: true)
        let overCardinalityPrefix = root.appendingPathComponent(
            "OverCardinality.container",
            isDirectory: true
        )
        let bridgeRoot = root.appendingPathComponent("Bridge", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let wine = root.appendingPathComponent("wine")
        let runner = root.appendingPathComponent("switchyard-runner")
        defer { try? fileManager.removeItem(at: root) }

        try makeExecutable(at: wine, fileManager: fileManager)
        try makeExecutable(at: runner, fileManager: fileManager)
        let oversizedManifestURL = WineDesktopShortcutFormat.manifestURL(
            prefixPath: oversizedPrefix.path
        )
        try writeSparseManifest(
            header: WineDesktopShortcutFormat.manifestHeader,
            byteCount: WineDesktopShortcutFormat.maximumManifestBytes + 1,
            to: oversizedManifestURL,
            fileManager: fileManager
        )

        let overCardinalityManifestURL = WineDesktopShortcutFormat.manifestURL(
            prefixPath: overCardinalityPrefix.path
        )
        try fileManager.createDirectory(
            at: overCardinalityManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let overCardinalityManifest = (
            [WineDesktopShortcutFormat.manifestHeader]
                + (0...WineDesktopShortcutFormat.maximumEntries).map(desktopManifestLine)
        ).joined(separator: "\n")
        try Data(overCardinalityManifest.utf8).write(to: overCardinalityManifestURL)

        let firstSource = overCardinalityPrefix.appendingPathComponent(
            "drive_c/users/steamuser/Desktop/Shortcut 0.url"
        )
        try fileManager.createDirectory(
            at: firstSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("[InternetShortcut]\nURL=scheme0://launch\n".utf8).write(to: firstSource)

        let bridge = WineDesktopShortcutBridge(
            fileManager: fileManager,
            rootURL: bridgeRoot,
            desktopURL: desktop
        )
        let result = try await bridge.refresh(
            containers: [
                Container(name: "Oversized", path: oversizedPrefix.path),
                Container(name: "Over cardinality", path: overCardinalityPrefix.path)
            ],
            winePath: wine.path,
            runnerPath: runner.path
        )

        #expect(result.createdShortcutNames.isEmpty)
        #expect(result.removedShortcutNames.isEmpty)
        let routeData = try Data(contentsOf: bridgeRoot.appendingPathComponent("routes-v1.json"))
        let routes = try JSONDecoder().decode(WineDesktopShortcutRouteIndex.self, from: routeData)
        #expect(routes.routes.isEmpty)
        let desktopEntries = try fileManager.contentsOfDirectory(
            at: desktop,
            includingPropertiesForKeys: nil
        )
        #expect(desktopEntries.allSatisfy { $0.pathExtension.lowercased() != "app" })
    }

    @MainActor
    @Test func indexedProtocolRefreshNeverFallsBackToTheManifestOnDisk() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(
                "switchyard-indexed-protocol-\(UUID().uuidString)",
                isDirectory: true
            )
        let prefix = root.appendingPathComponent(
            "Test.container",
            isDirectory: true
        )
        let bridgeRoot = root.appendingPathComponent(
            "Bridge",
            isDirectory: true
        )
        let wine = root.appendingPathComponent("wine")
        let runner = root.appendingPathComponent("runner")
        defer { try? fileManager.removeItem(at: root) }

        try makeExecutable(at: wine, fileManager: fileManager)
        try makeExecutable(at: runner, fileManager: fileManager)
        let manifestURL = WineProtocolAssociationFormat.manifestURL(
            prefixPath: prefix.path
        )
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            "\(WineProtocolAssociationFormat.manifestHeader)\nxdt\n".utf8
        ).write(to: manifestURL)
        let container = Container(name: "Test", path: prefix.path)
        let bridge = WineProtocolBridge(
            fileManager: fileManager,
            rootURL: bridgeRoot
        )

        _ = try bridge.refresh(
            containers: [container],
            indexedMetadataByContainerID: [:],
            winePath: wine.path,
            runnerPath: runner.path
        )

        let routeData = try Data(
            contentsOf: bridgeRoot.appendingPathComponent("routes-v1.json")
        )
        let routes = try JSONDecoder().decode(
            WineProtocolRouteIndex.self,
            from: routeData
        )
        #expect(routes.routes.isEmpty)
    }

    @MainActor
    @Test func indexedDesktopRoutesUseOnlySharedMetadata() {
        let container = Container(
            name: "Test",
            path: "/containers/Test"
        )
        let entry = WineDesktopShortcutManifestEntry(
            kind: .url,
            displayName: "Indexed Game",
            windowsShortcutPath:
                #"C:\users\steamuser\Desktop\Indexed Game.url"#
        )
        let bridge = WineDesktopShortcutBridge()

        let absent = bridge.desiredShortcutRoutesForTesting(
            containers: [container],
            indexedMetadataByContainerID: [:],
            winePath: "/test/wine",
            runnerPath: "/test/runner"
        )
        let indexed = bridge.desiredShortcutRoutesForTesting(
            containers: [container],
            indexedMetadataByContainerID: [
                container.id: ContainerBridgeIndexMetadata(
                    desktopShortcutEntries: [entry]
                )
            ],
            winePath: "/test/wine",
            runnerPath: "/test/runner"
        )

        #expect(absent.isEmpty)
        #expect(indexed.count == 1)
        #expect(indexed.first?.containerID == container.id)
        #expect(indexed.first?.windowsShortcutPath == entry.windowsShortcutPath)
    }

    private func desktopManifestLine(_ index: Int) -> String {
        desktopManifestLine(
            name: "Shortcut \(index)",
            windowsPath: #"C:\users\steamuser\Desktop\Shortcut \#(index).url"#
        )
    }

    private func desktopManifestLine(name: String, windowsPath: String) -> String {
        "url\t\(hex(name))\t\(hex(windowsPath))\t"
    }

    private func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func makeExecutable(at url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeSparseManifest(
        header: String,
        byteCount: Int,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(fileManager.createFile(atPath: url.path, contents: Data(header.utf8)))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
    }
}
