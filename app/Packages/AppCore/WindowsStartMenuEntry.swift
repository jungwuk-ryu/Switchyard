import Foundation

public enum WindowsStartMenuEntryKind: String, Codable, Equatable, Hashable, Sendable {
    case lnk
    case url
}

public enum WindowsStartMenuScope: Codable, Equatable, Hashable, Sendable {
    case allUsers
    case user(String)

    public var userName: String? {
        guard case let .user(userName) = self else { return nil }
        return userName
    }
}

/// A validated Windows shortcut path rooted in one of Wine's Start Menu locations.
public struct WindowsStartMenuPath: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public static let allUsersProgramsPath =
        #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs"#

    public let rawValue: String
    public let kind: WindowsStartMenuEntryKind
    public let scope: WindowsStartMenuScope
    public let relativeComponents: [String]

    public var groupComponents: [String] {
        Array(relativeComponents.dropLast())
    }

    public var relativePath: String {
        relativeComponents.joined(separator: #"\"#)
    }

    public var groupPath: String {
        groupComponents.joined(separator: #"\"#)
    }

    public var displayName: String {
        String(relativeComponents.last?.dropLast(4) ?? "")
    }

    public init?(rawValue: String) {
        guard let parsed = Self.parse(rawValue) else { return nil }
        self.rawValue = parsed.rawValue
        kind = parsed.kind
        scope = parsed.scope
        relativeComponents = parsed.relativeComponents
    }

    public init?(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let path = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Windows Start Menu shortcut path."
            )
        }
        self = path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func normalizedShortcutPath(_ rawValue: String) -> String? {
        Self(rawValue: rawValue)?.rawValue
    }

    public static func programsPath(for scope: WindowsStartMenuScope) -> String? {
        switch scope {
        case .allUsers:
            return allUsersProgramsPath
        case let .user(userName):
            guard isValidComponent(userName) else { return nil }
            return #"C:\users\"# + userName
                + #"\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"#
        }
    }

    /// Converts a validated shortcut path to a host URL and verifies that every
    /// existing component is inside the prefix and is not a symbolic link.
    public func hostURL(
        prefixPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        Self.validatedHostURL(
            windowsComponents: windowsComponents,
            prefixPath: prefixPath,
            expectedItemType: .regularFile,
            fileManager: fileManager
        )
    }

    public static func hostShortcutURL(
        windowsPath: String,
        prefixPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        Self(rawValue: windowsPath)?.hostURL(
            prefixPath: prefixPath,
            fileManager: fileManager
        )
    }

    /// Returns an existing, non-symlink Programs directory for a Start Menu scope.
    public static func hostProgramsDirectoryURL(
        for scope: WindowsStartMenuScope,
        prefixPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let windowsPath = programsPath(for: scope) else { return nil }
        let components = Array(windowsPath.dropFirst(3).split(separator: #"\"#).map(String.init))
        return validatedHostURL(
            windowsComponents: components,
            prefixPath: prefixPath,
            expectedItemType: .directory,
            fileManager: fileManager
        )
    }

    private var windowsComponents: [String] {
        Array(rawValue.dropFirst(3).split(separator: #"\"#).map(String.init))
    }

    private static let maximumPathLength = 32_768
    private static let maximumComponentLength = 255
    private static let maximumRelativeComponentCount = 64
    private static let allUsersRootComponents = [
        "ProgramData",
        "Microsoft",
        "Windows",
        "Start Menu",
        "Programs",
    ]
    private static let userRootSuffixComponents = [
        "AppData",
        "Roaming",
        "Microsoft",
        "Windows",
        "Start Menu",
        "Programs",
    ]

    private struct ParsedPath {
        var rawValue: String
        var kind: WindowsStartMenuEntryKind
        var scope: WindowsStartMenuScope
        var relativeComponents: [String]
    }

    private enum ExpectedHostItemType {
        case directory
        case regularFile
    }

    private static func parse(_ rawValue: String) -> ParsedPath? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSeparators = trimmed.replacingOccurrences(of: "/", with: #"\"#)
        guard normalizedSeparators.utf16.count <= maximumPathLength,
              normalizedSeparators.count >= 4,
              !normalizedSeparators.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return nil
        }

        let scalars = normalizedSeparators.unicodeScalars
        guard let drive = scalars.first,
              isASCIILetter(drive),
              scalars.dropFirst().first == ":",
              scalars.dropFirst(2).first == #"\"#,
              String(drive).caseInsensitiveCompare("C") == .orderedSame else {
            return nil
        }

        let components = normalizedSeparators.dropFirst(3).split(
            separator: #"\"#,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.allSatisfy(isValidComponent) else { return nil }

        let scope: WindowsStartMenuScope
        let canonicalRoot: [String]
        let relativeComponents: [String]
        if components.count > allUsersRootComponents.count,
           hasCaseInsensitivePrefix(components, prefix: allUsersRootComponents) {
            scope = .allUsers
            canonicalRoot = allUsersRootComponents
            relativeComponents = Array(components.dropFirst(allUsersRootComponents.count))
        } else if components.count > userRootSuffixComponents.count + 1,
                  components[0].caseInsensitiveCompare("users") == .orderedSame,
                  hasCaseInsensitivePrefix(
                    Array(components.dropFirst(2)),
                    prefix: userRootSuffixComponents
                  ) {
            let userName = components[1]
            scope = .user(userName)
            canonicalRoot = ["users", userName] + userRootSuffixComponents
            relativeComponents = Array(components.dropFirst(userRootSuffixComponents.count + 2))
        } else {
            return nil
        }

        guard !relativeComponents.isEmpty,
              relativeComponents.count <= maximumRelativeComponentCount,
              let filename = relativeComponents.last,
              filename.count > 4,
              let kind = shortcutKind(for: filename) else {
            return nil
        }

        return ParsedPath(
            rawValue: "C:" + #"\"# + (canonicalRoot + relativeComponents).joined(separator: #"\"#),
            kind: kind,
            scope: scope,
            relativeComponents: relativeComponents
        )
    }

    private static func shortcutKind(for filename: String) -> WindowsStartMenuEntryKind? {
        switch filename.suffix(4).lowercased() {
        case ".lnk":
            .lnk
        case ".url":
            .url
        default:
            nil
        }
    }

    private static func hasCaseInsensitivePrefix(
        _ components: [String],
        prefix: [String]
    ) -> Bool {
        guard components.count >= prefix.count else { return false }
        return zip(components, prefix).allSatisfy {
            $0.caseInsensitiveCompare($1) == .orderedSame
        }
    }

    private static func isValidComponent(_ component: String) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              component.utf16.count <= maximumComponentLength,
              component.last != ".",
              component.last != " ",
              !component.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return false
        }
        let invalidCharacters = CharacterSet(charactersIn: #"\/:"<>|?*"#)
        return component.rangeOfCharacter(from: invalidCharacters) == nil
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func validatedHostURL(
        windowsComponents: [String],
        prefixPath: String,
        expectedItemType: ExpectedHostItemType,
        fileManager: FileManager
    ) -> URL? {
        guard !prefixPath.isEmpty,
              prefixPath.utf8.count <= maximumPathLength,
              (prefixPath as NSString).isAbsolutePath else {
            return nil
        }

        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true).standardizedFileURL
        let hostComponents = ["drive_c"] + windowsComponents
        let candidateURL = hostComponents.reduce(prefixURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL
        guard isContained(candidateURL, in: prefixURL),
              isContained(
                  candidateURL.resolvingSymlinksInPath().standardizedFileURL,
                  in: prefixURL.resolvingSymlinksInPath().standardizedFileURL
              ),
              itemType(at: prefixURL, fileManager: fileManager) == .typeDirectory else {
            return nil
        }

        var currentURL = prefixURL
        for (index, component) in hostComponents.enumerated() {
            currentURL.appendPathComponent(component)
            guard let type = itemType(at: currentURL, fileManager: fileManager),
                  type != .typeSymbolicLink else {
                return nil
            }

            let isLastComponent = index == hostComponents.count - 1
            if isLastComponent {
                switch expectedItemType {
                case .directory:
                    guard type == .typeDirectory else { return nil }
                case .regularFile:
                    guard type == .typeRegular else { return nil }
                }
            } else {
                guard type == .typeDirectory else { return nil }
            }
        }
        return candidateURL
    }

    private static func itemType(
        at url: URL,
        fileManager: FileManager
    ) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private static func isContained(_ candidateURL: URL, in rootURL: URL) -> Bool {
        candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(rootURL.path + "/")
    }
}

public struct WindowsStartMenuEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String {
        windowsShortcutPath.lowercased()
    }

    public let kind: WindowsStartMenuEntryKind
    public let displayName: String
    public let groupComponents: [String]
    public let scope: WindowsStartMenuScope
    public let windowsShortcutPath: String

    public var groupPath: String {
        groupComponents.joined(separator: #"\"#)
    }

    public init?(windowsShortcutPath: String) {
        guard let path = WindowsStartMenuPath(rawValue: windowsShortcutPath) else { return nil }
        kind = path.kind
        displayName = path.displayName
        groupComponents = path.groupComponents
        scope = path.scope
        self.windowsShortcutPath = path.rawValue
    }

    public func hostURL(
        prefixPath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        WindowsStartMenuPath(rawValue: windowsShortcutPath)?.hostURL(
            prefixPath: prefixPath,
            fileManager: fileManager
        )
    }
}
