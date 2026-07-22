import AppCore
import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

enum WineDesktopShortcutBridgeError: LocalizedError {
    case missingShortcutHandler
    case couldNotSignShortcut(String)
    case desktopNameCollision(String)

    var errorDescription: String? {
        switch self {
        case .missingShortcutHandler:
            "switchyard-shortcut-handler was not found in the app bundle or build directory."
        case let .couldNotSignShortcut(name):
            "Could not sign the generated macOS shortcut for \(name)."
        case let .desktopNameCollision(name):
            "Could not choose a safe macOS desktop name for \(name)."
        }
    }
}

struct WineDesktopShortcutBridgeRefreshResult {
    var createdShortcutNames: [String]
    var removedShortcutNames: [String]
}

@MainActor
final class WineDesktopShortcutBridge {
    private struct DesiredShortcut {
        var id: String
        var displayName: String
        var containerName: String
        var iconURL: URL?
        var route: WineDesktopShortcutRoute
    }

    private struct Placement {
        var desired: DesiredShortcut
        var bundleURL: URL
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let desktopURL: URL

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        desktopURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Switchyard", isDirectory: true)
                .appendingPathComponent("DesktopShortcutBridge", isDirectory: true)
        self.desktopURL = desktopURL
            ?? fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func refresh(
        containers: [Container],
        winePath: String,
        runnerPath: String
    ) throws -> WineDesktopShortcutBridgeRefreshResult {
        guard fileManager.isExecutableFile(atPath: winePath),
              fileManager.isExecutableFile(atPath: runnerPath) else {
            return WineDesktopShortcutBridgeRefreshResult(
                createdShortcutNames: [],
                removedShortcutNames: []
            )
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard Darwin.chmod(rootURL.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(.EACCES)
        }
        try fileManager.createDirectory(at: desktopURL, withIntermediateDirectories: true)

        let desired = desiredShortcuts(
            containers: containers,
            winePath: winePath,
            runnerPath: runnerPath
        )
        try writeRouteIndex(WineDesktopShortcutRouteIndex(routes: desired.map(\.route)))

        let desiredIDs = Set(desired.map(\.id))
        var removedNames = try removeManagedBundles(excluding: desiredIDs)
        guard !desired.isEmpty else {
            return WineDesktopShortcutBridgeRefreshResult(
                createdShortcutNames: [],
                removedShortcutNames: removedNames.sorted()
            )
        }

        let helperURL = try locateShortcutHandler()
        let helperDigest = try sha256Hex(of: helperURL)
        let placements = try makePlacements(for: desired)
        var createdNames: [String] = []

        for placement in placements {
            let iconDigest = try placement.desired.iconURL.map(sha256Hex(of:))
            if !isCurrentBundle(
                at: placement.bundleURL,
                desired: placement.desired,
                helperDigest: helperDigest,
                iconDigest: iconDigest
            ) {
                try materialize(
                    placement,
                    helperURL: helperURL,
                    helperDigest: helperDigest,
                    iconDigest: iconDigest
                )
                createdNames.append(placement.desired.displayName)
            }
        }
        let keptBundles = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.desired.id, $0.bundleURL)
        })
        removedNames.append(contentsOf: try removeDuplicateBundles(keeping: keptBundles))

        return WineDesktopShortcutBridgeRefreshResult(
            createdShortcutNames: createdNames.sorted(),
            removedShortcutNames: removedNames.sorted()
        )
    }

    private func desiredShortcuts(
        containers: [Container],
        winePath: String,
        runnerPath: String
    ) -> [DesiredShortcut] {
        var shortcutsByID: [String: DesiredShortcut] = [:]
        for container in containers {
            let manifestURL = WineDesktopShortcutFormat.manifestURL(prefixPath: container.path)
            guard isRegularFileInsidePrefix(manifestURL, prefixPath: container.path),
                  let contents = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                continue
            }

            for entry in WineDesktopShortcutFormat.entries(inManifest: contents) {
                guard let sourceURL = WineDesktopShortcutFormat.hostShortcutURL(
                    windowsPath: entry.windowsShortcutPath,
                    prefixPath: container.path
                ),
                      isRegularNonSymbolicFile(sourceURL) else {
                    continue
                }
                let id = shortcutID(containerID: container.id, windowsPath: entry.windowsShortcutPath)
                let iconURL = entry.windowsIconPath.flatMap {
                    WineDesktopShortcutFormat.hostIconURL(
                        windowsPath: $0,
                        prefixPath: container.path
                    )
                }.flatMap { isRegularNonSymbolicFile($0) ? $0 : nil }
                shortcutsByID[id] = DesiredShortcut(
                    id: id,
                    displayName: entry.displayName,
                    containerName: WineDesktopShortcutFormat.nativeDisplayName(container.name)
                        ?? "Switchyard",
                    iconURL: iconURL,
                    route: WineDesktopShortcutRoute(
                        id: id,
                        containerID: container.id,
                        prefixPath: container.path,
                        winePath: winePath,
                        runnerPath: runnerPath,
                        windowsShortcutPath: entry.windowsShortcutPath
                    )
                )
            }
        }

        return shortcutsByID.values.sorted {
            let displayComparison = $0.displayName.localizedStandardCompare($1.displayName)
            if displayComparison != .orderedSame { return displayComparison == .orderedAscending }
            let containerComparison = $0.containerName.localizedStandardCompare($1.containerName)
            if containerComparison != .orderedSame { return containerComparison == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private func makePlacements(for desired: [DesiredShortcut]) throws -> [Placement] {
        let managedByPath = try managedBundles().reduce(into: [String: String]()) { result, item in
            result[pathKey(item.url)] = item.id
        }
        var reservedPaths: Set<String> = []
        var placements: [Placement] = []

        for shortcut in desired {
            let bases = [
                shortcut.displayName,
                "\(shortcut.displayName) — \(shortcut.containerName)",
                "\(shortcut.displayName) (Switchyard)"
            ]
            var selectedURL: URL?
            for base in bases {
                let candidate = desktopURL.appendingPathComponent("\(base).app", isDirectory: true)
                if isAvailable(candidate, for: shortcut.id, managedByPath: managedByPath, reserved: reservedPaths) {
                    selectedURL = candidate
                    break
                }
            }
            if selectedURL == nil {
                for suffix in 2...999 {
                    let candidate = desktopURL.appendingPathComponent(
                        "\(shortcut.displayName) (Switchyard \(suffix)).app",
                        isDirectory: true
                    )
                    if isAvailable(candidate, for: shortcut.id, managedByPath: managedByPath, reserved: reservedPaths) {
                        selectedURL = candidate
                        break
                    }
                }
            }
            guard let selectedURL else {
                throw WineDesktopShortcutBridgeError.desktopNameCollision(shortcut.displayName)
            }
            reservedPaths.insert(pathKey(selectedURL))
            placements.append(Placement(desired: shortcut, bundleURL: selectedURL))
        }
        return placements
    }

    private func isAvailable(
        _ url: URL,
        for id: String,
        managedByPath: [String: String],
        reserved: Set<String>
    ) -> Bool {
        let key = pathKey(url)
        guard !reserved.contains(key) else { return false }
        if !fileManager.fileExists(atPath: url.path) { return true }
        return managedByPath[key] == id
    }

    private func materialize(
        _ placement: Placement,
        helperURL: URL,
        helperDigest: String,
        iconDigest: String?
    ) throws {
        let temporaryURL = desktopURL.appendingPathComponent(
            ".switchyard-shortcut-\(UUID().uuidString).app",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let macOSURL = temporaryURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let executableURL = macOSURL.appendingPathComponent("switchyard-shortcut-handler")
        try fileManager.copyItem(at: helperURL, to: executableURL)
        guard Darwin.chmod(
            executableURL.path,
            mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
        ) == 0 else {
            throw POSIXError(.EACCES)
        }

        var infoPlist: [String: Any] = [
            "CFBundleDisplayName": placement.desired.displayName,
            "CFBundleExecutable": "switchyard-shortcut-handler",
            "CFBundleIdentifier": bundleIdentifier(for: placement.desired.id),
            "CFBundleName": placement.desired.displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "SwitchyardDesktopShortcutID": placement.desired.id,
            "SwitchyardDesktopShortcutOwner": "dev.switchyard",
            "SwitchyardShortcutHelperSHA256": helperDigest
        ]
        let icon = placement.desired.iconURL.flatMap(NSImage.init(contentsOf:))
            ?? fallbackIcon()
        if try writeBundleIcon(icon, to: temporaryURL) {
            infoPlist["CFBundleIconFile"] = "Shortcut.icns"
        }
        if let iconDigest {
            infoPlist["SwitchyardShortcutIconSHA256"] = iconDigest
        }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(
            to: temporaryURL.appendingPathComponent("Contents/Info.plist"),
            options: [.atomic]
        )
        try signBundle(at: temporaryURL, displayName: placement.desired.displayName)

        if fileManager.fileExists(atPath: placement.bundleURL.path) {
            guard managedShortcutID(at: placement.bundleURL) == placement.desired.id else {
                throw WineDesktopShortcutBridgeError.desktopNameCollision(
                    placement.desired.displayName
                )
            }
            try fileManager.removeItem(at: placement.bundleURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: placement.bundleURL)
    }

    private func writeBundleIcon(_ image: NSImage, to bundleURL: URL) throws -> Bool {
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let iconsetURL = resourcesURL.appendingPathComponent("Shortcut.iconset", isDirectory: true)
        let outputURL = resourcesURL.appendingPathComponent("Shortcut.icns")
        try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: iconsetURL) }

        let representations: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1_024)
        ]
        var dataBySize: [Int: Data] = [:]
        for representation in representations {
            let data: Data
            if let cached = dataBySize[representation.pixels] {
                data = cached
            } else if let rendered = pngData(for: image, pixels: representation.pixels) {
                dataBySize[representation.pixels] = rendered
                data = rendered
            } else {
                return false
            }
            try data.write(
                to: iconsetURL.appendingPathComponent(representation.name),
                options: [.atomic]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["--convert", "icns", iconsetURL.path, "--output", outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            try? fileManager.removeItem(at: outputURL)
            return false
        }
        return fileManager.fileExists(atPath: outputURL.path)
    }

    private func pngData(for image: NSImage, pixels: Int) -> Data? {
        guard pixels > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixels,
                  pixelsHigh: pixels,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        let sourceSize = image.size
        let sourceWidth = max(sourceSize.width, 1)
        let sourceHeight = max(sourceSize.height, 1)
        let scale = min(CGFloat(pixels) / sourceWidth, CGFloat(pixels) / sourceHeight)
        let targetSize = NSSize(width: sourceWidth * scale, height: sourceHeight * scale)
        let targetRect = NSRect(
            x: (CGFloat(pixels) - targetSize.width) / 2,
            y: (CGFloat(pixels) - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        image.draw(
            in: targetRect,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private func fallbackIcon() -> NSImage {
        guard let applicationIcon = NSApplication.shared.applicationIconImage,
              applicationIcon.size.width > 0,
              applicationIcon.size.height > 0 else {
            let image = NSImage(size: NSSize(width: 512, height: 512))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 24, y: 24, width: 464, height: 464),
                xRadius: 96,
                yRadius: 96
            ).fill()
            image.unlockFocus()
            return image
        }
        return applicationIcon
    }

    private func isCurrentBundle(
        at url: URL,
        desired: DesiredShortcut,
        helperDigest: String,
        iconDigest: String?
    ) -> Bool {
        let executableURL = url
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("switchyard-shortcut-handler")
        guard let info = infoDictionary(at: url),
              fileManager.isExecutableFile(atPath: executableURL.path),
              hasValidSignature(at: url) else {
            return false
        }
        return info["CFBundleDisplayName"] as? String == desired.displayName
            && info["CFBundleIdentifier"] as? String == bundleIdentifier(for: desired.id)
            && info["SwitchyardDesktopShortcutID"] as? String == desired.id
            && info["SwitchyardDesktopShortcutOwner"] as? String == "dev.switchyard"
            && info["SwitchyardShortcutHelperSHA256"] as? String == helperDigest
            && info["SwitchyardShortcutIconSHA256"] as? String == iconDigest
    }

    private func hasValidSignature(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess
    }

    private func removeManagedBundles(excluding desiredIDs: Set<String>) throws -> [String] {
        var removed: [String] = []
        for bundle in try managedBundles() where !desiredIDs.contains(bundle.id) {
            removed.append(bundle.url.deletingPathExtension().lastPathComponent)
            try fileManager.removeItem(at: bundle.url)
        }
        return removed
    }

    private func removeDuplicateBundles(keeping keptURLs: [String: URL]) throws -> [String] {
        var removed: [String] = []
        for bundle in try managedBundles() {
            guard let keptURL = keptURLs[bundle.id],
                  pathKey(bundle.url) != pathKey(keptURL) else {
                continue
            }
            removed.append(bundle.url.deletingPathExtension().lastPathComponent)
            try fileManager.removeItem(at: bundle.url)
        }
        return removed
    }

    private func managedBundles() throws -> [(id: String, url: URL)] {
        let entries = try fileManager.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        return entries.compactMap { url in
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  let id = managedShortcutID(at: url) else {
                return nil
            }
            return (id, url)
        }
    }

    private func managedShortcutID(at url: URL) -> String? {
        guard let info = infoDictionary(at: url),
              info["SwitchyardDesktopShortcutOwner"] as? String == "dev.switchyard",
              let id = info["SwitchyardDesktopShortcutID"] as? String,
              id.count == 64,
              id.allSatisfy(\.isHexDigit),
              info["CFBundleIdentifier"] as? String == bundleIdentifier(for: id) else {
            return nil
        }
        return id
    }

    private func infoDictionary(at bundleURL: URL) -> [String: Any]? {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            return nil
        }
        return info
    }

    private func writeRouteIndex(_ index: WineDesktopShortcutRouteIndex) throws {
        let routesURL = rootURL.appendingPathComponent("routes-v1.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        if (try? Data(contentsOf: routesURL)) != data {
            try data.write(to: routesURL, options: [.atomic])
        }
        guard Darwin.chmod(routesURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    private func locateShortcutHandler() throws -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("switchyard-shortcut-handler")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }

        if let override = ProcessInfo.processInfo.environment["SWITCHYARD_SHORTCUT_HANDLER_PATH"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let fallback = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/debug/switchyard-shortcut-handler")
        if fileManager.isExecutableFile(atPath: fallback.path) { return fallback }
        throw WineDesktopShortcutBridgeError.missingShortcutHandler
    }

    private func signBundle(at url: URL, displayName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WineDesktopShortcutBridgeError.couldNotSignShortcut(displayName)
        }
    }

    private func shortcutID(containerID: UUID, windowsPath: String) -> String {
        let input = containerID.uuidString.lowercased() + "\u{0}" + windowsPath.lowercased()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func bundleIdentifier(for id: String) -> String {
        "dev.switchyard.desktop-shortcut.\(id.prefix(24))"
    }

    private func sha256Hex(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isRegularFileInsidePrefix(_ url: URL, prefixPath: String) -> Bool {
        let resolvedPrefix = URL(fileURLWithPath: prefixPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        return path(resolvedURL.path, isWithin: resolvedPrefix.path)
            && isRegularNonSymbolicFile(url)
    }

    private func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private func path(_ candidatePath: String, isWithin directoryPath: String) -> Bool {
        candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
    }
}
