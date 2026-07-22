import Foundation

public enum WineDesktopShortcutKind: String, Codable, Equatable, Sendable {
    case lnk
    case url
}

public struct WineDesktopShortcutManifestEntry: Equatable, Sendable {
    public var kind: WineDesktopShortcutKind
    public var displayName: String
    public var windowsShortcutPath: String
    public var windowsIconPath: String?

    public init(
        kind: WineDesktopShortcutKind,
        displayName: String,
        windowsShortcutPath: String,
        windowsIconPath: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.windowsShortcutPath = windowsShortcutPath
        self.windowsIconPath = windowsIconPath
    }
}

public enum WineDesktopShortcutFormat {
    public static let manifestHeader = "# switchyard-wine-desktop-shortcuts-v1"
    public static let manifestEnvironmentKey = "SWITCHYARD_DESKTOP_SHORTCUTS_FILE"
    public static let privateDesktopEnvironmentKey = "SWITCHYARD_PRIVATE_DESKTOP"
    public static let windowsManifestPath = #"C:\windows\temp\switchyard-desktop-shortcuts-v1.txt"#

    public static func manifestURL(prefixPath: String) -> URL {
        URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c/windows/temp", isDirectory: true)
            .appendingPathComponent("switchyard-desktop-shortcuts-v1.txt")
    }

    public static func entries(inManifest contents: String) -> [WineDesktopShortcutManifestEntry] {
        guard contents.utf8.count <= 4 * 1_024 * 1_024 else { return [] }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map(trimmedLine) == manifestHeader else { return [] }

        var entriesByPath: [String: WineDesktopShortcutManifestEntry] = [:]
        for rawLine in lines.dropFirst() {
            let line = trimmedLine(rawLine)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let kind = WineDesktopShortcutKind(rawValue: String(fields[0])),
                  let rawDisplayName = decodeHex(fields[1]),
                  let displayName = nativeDisplayName(rawDisplayName),
                  let rawShortcutPath = decodeHex(fields[2]),
                  let shortcutPath = normalizedShortcutPath(rawShortcutPath, kind: kind) else {
                continue
            }

            let iconPath: String?
            if fields[3].isEmpty {
                iconPath = nil
            } else if let rawIconPath = decodeHex(fields[3]) {
                iconPath = normalizedIconPath(rawIconPath)
            } else {
                iconPath = nil
            }
            entriesByPath[shortcutPath.lowercased()] = WineDesktopShortcutManifestEntry(
                kind: kind,
                displayName: displayName,
                windowsShortcutPath: shortcutPath,
                windowsIconPath: iconPath
            )
        }

        return entriesByPath.values.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.windowsShortcutPath.localizedStandardCompare($1.windowsShortcutPath)
                == .orderedAscending
        }
    }

    public static func normalizedShortcutPath(
        _ rawValue: String,
        kind: WineDesktopShortcutKind? = nil
    ) -> String? {
        guard let path = normalizedWindowsPath(rawValue), path.drive == "C" else { return nil }
        let components = path.components
        guard components.count == 4,
              components[0].caseInsensitiveCompare("users") == .orderedSame,
              components[2].caseInsensitiveCompare("Desktop") == .orderedSame,
              let detectedKind = shortcutKind(forFilename: components[3]),
              kind == nil || kind == detectedKind else {
            return nil
        }
        return path.drive + #":\"# + components.joined(separator: #"\"#)
    }

    public static func normalizedIconPath(_ rawValue: String) -> String? {
        guard let path = normalizedWindowsPath(rawValue), path.drive == "C" else { return nil }
        let components = path.components
        guard components.count == 4,
              components[0].caseInsensitiveCompare("windows") == .orderedSame,
              components[1].caseInsensitiveCompare("temp") == .orderedSame,
              components[2].caseInsensitiveCompare("switchyard-desktop-icons-v1") == .orderedSame,
              isIconFilename(components[3]) else {
            return nil
        }
        return path.drive + #":\"# + components.joined(separator: #"\"#)
    }

    public static func hostShortcutURL(windowsPath: String, prefixPath: String) -> URL? {
        guard let normalized = normalizedShortcutPath(windowsPath) else { return nil }
        return hostURL(forNormalizedWindowsPath: normalized, prefixPath: prefixPath)
    }

    public static func hostIconURL(windowsPath: String, prefixPath: String) -> URL? {
        guard let normalized = normalizedIconPath(windowsPath) else { return nil }
        return hostURL(forNormalizedWindowsPath: normalized, prefixPath: prefixPath)
    }

    public static func nativeDisplayName(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return nil
        }
        let replaced = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var limited = replaced
        while limited.utf8.count > 100 { limited.removeLast() }
        limited = limited.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return limited.isEmpty ? nil : limited
    }

    private static func hostURL(forNormalizedWindowsPath path: String, prefixPath: String) -> URL? {
        guard let parsed = normalizedWindowsPath(path), parsed.drive == "C" else { return nil }
        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true).standardizedFileURL
        let driveURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let candidateURL = parsed.components.reduce(driveURL) { url, component in
            url.appendingPathComponent(component)
        }.standardizedFileURL
        let resolvedPrefixURL = prefixURL.resolvingSymlinksInPath()
        let resolvedCandidateURL = candidateURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(candidateURL.lastPathComponent)
            .standardizedFileURL
        guard isContained(resolvedCandidateURL, in: resolvedPrefixURL) else { return nil }
        return candidateURL
    }

    private static func normalizedWindowsPath(
        _ rawValue: String
    ) -> (drive: String, components: [String])? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: "/", with: #"\"#)
        guard normalized.utf8.count <= 32_768,
              normalized.count >= 4,
              !normalized.contains("\""),
              !normalized.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return nil
        }
        let scalars = normalized.unicodeScalars
        guard let first = scalars.first,
              isASCIILetter(first),
              scalars.dropFirst().first == ":",
              scalars.dropFirst(2).first == #"\"# else {
            return nil
        }
        let components = normalized.dropFirst(3).split(
            separator: #"\"#,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return (String(first).uppercased(), components)
    }

    private static func shortcutKind(forFilename filename: String) -> WineDesktopShortcutKind? {
        let lowercase = filename.lowercased()
        if lowercase.hasSuffix(".lnk") { return .lnk }
        if lowercase.hasSuffix(".url") { return .url }
        return nil
    }

    private static func isIconFilename(_ value: String) -> Bool {
        let lowercase = value.lowercased()
        guard lowercase.count == 20, lowercase.hasSuffix(".png") else { return false }
        return lowercase.dropLast(4).allSatisfy { character in
            character.isNumber || ("a"..."f").contains(String(character))
        }
    }

    private static func decodeHex(_ value: Substring) -> String? {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2), bytes.count <= 131_072 else { return nil }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexValue(bytes[index]), let low = hexValue(bytes[index + 1]) else {
                return nil
            }
            decoded.append((high << 4) | low)
        }
        return String(bytes: decoded, encoding: .utf8)
    }

    private static func hexValue(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 55
        case 97...102: value - 87
        default: nil
        }
    }

    private static func trimmedLine(_ line: Substring) -> String {
        line.last == "\r" ? String(line.dropLast()) : String(line)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isContained(_ candidateURL: URL, in rootURL: URL) -> Bool {
        candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(rootURL.path + "/")
    }
}

public struct WineDesktopShortcutRoute: Codable, Equatable, Sendable {
    public var id: String
    public var containerID: UUID
    public var prefixPath: String
    public var winePath: String
    public var runnerPath: String
    public var windowsShortcutPath: String

    public init(
        id: String,
        containerID: UUID,
        prefixPath: String,
        winePath: String,
        runnerPath: String,
        windowsShortcutPath: String
    ) {
        self.id = id
        self.containerID = containerID
        self.prefixPath = prefixPath
        self.winePath = winePath
        self.runnerPath = runnerPath
        self.windowsShortcutPath = windowsShortcutPath
    }
}

public struct WineDesktopShortcutRouteIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var routes: [WineDesktopShortcutRoute]

    public init(version: Int = currentVersion, routes: [WineDesktopShortcutRoute]) {
        self.version = version
        self.routes = routes
    }

    public func route(forID id: String) -> WineDesktopShortcutRoute? {
        guard version == Self.currentVersion, !id.isEmpty, id.utf8.count <= 256 else { return nil }
        return routes.first { $0.id == id }
    }
}

public struct WineDesktopShortcutRequest: Codable, Equatable, Sendable {
    public var shortcutID: String
    public var prefixPath: String
    public var winePath: String
    public var windowsShortcutPath: String

    public init(
        shortcutID: String,
        prefixPath: String,
        winePath: String,
        windowsShortcutPath: String
    ) {
        self.shortcutID = shortcutID
        self.prefixPath = prefixPath
        self.winePath = winePath
        self.windowsShortcutPath = windowsShortcutPath
    }
}
