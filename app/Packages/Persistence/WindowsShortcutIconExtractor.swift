import AppCore
import Foundation

public struct WindowsShortcutIconSource: Equatable, Sendable {
    public let fileURL: URL
    public let iconIndex: Int?

    public init(fileURL: URL, iconIndex: Int?) {
        self.fileURL = fileURL
        self.iconIndex = iconIndex
    }
}

/// Resolves the icon source recorded by a Windows Start Menu shortcut without
/// executing the shortcut or linking the app against Wine.
public enum WindowsShortcutIconExtractor {
    private static let maximumShortcutBytes = 1 * 1_024 * 1_024
    private static let maximumDirectIconBytes = 8 * 1_024 * 1_024
    private static let maximumWindowsPathCharacters = 32_768
    private static let maximumPathComponents = 64
    private static let maximumComponentCharacters = 255

    public static func source(
        for entry: WindowsStartMenuEntry,
        prefixPath: String,
        fileManager: FileManager = .default
    ) -> WindowsShortcutIconSource? {
        sources(
            for: entry,
            prefixPath: prefixPath,
            fileManager: fileManager
        ).first
    }

    public static func sources(
        for entry: WindowsStartMenuEntry,
        prefixPath: String,
        fileManager: FileManager = .default
    ) -> [WindowsShortcutIconSource] {
        guard let shortcutURL = entry.hostURL(
            prefixPath: prefixPath,
            fileManager: fileManager
        ), let data = shortcutData(
            at: shortcutURL,
            fileManager: fileManager
        ) else {
            return []
        }

        let references: [ShortcutIconReference]
        switch entry.kind {
        case .lnk:
            guard let metadata = WindowsShellLinkMetadata(data: data) else {
                return []
            }
            references = metadata.iconReferences
        case .url:
            guard let metadata = WindowsInternetShortcutMetadata(data: data) else {
                return []
            }
            references = [metadata.iconReference]
        }

        var seenSources: Set<WindowsShortcutIconSourceKey> = []
        var sources: [WindowsShortcutIconSource] = []
        for reference in references {
            guard let expandedPath = expandedWindowsPath(
                reference.windowsPath,
                relativeTo: reference.workingDirectory,
                scope: entry.scope
            ), let fileURL = regularHostURL(
                windowsPath: expandedPath,
                prefixPath: prefixPath,
                fileManager: fileManager
            ) else {
                continue
            }
            let source = WindowsShortcutIconSource(
                fileURL: fileURL,
                iconIndex: reference.iconIndex
            )
            let key = WindowsShortcutIconSourceKey(source)
            guard seenSources.insert(key).inserted else {
                continue
            }
            sources.append(source)
        }
        return sources
    }

    public static func iconData(
        from source: WindowsShortcutIconSource,
        fileManager: FileManager = .default
    ) -> Data? {
        guard let values = try? source.fileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]), values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize > 0 else {
            return nil
        }

        let directIconExtensions: Set<String> = [
            "bmp", "ico", "icns", "jpeg", "jpg", "png",
        ]
        if directIconExtensions.contains(source.fileURL.pathExtension.lowercased()) {
            guard fileSize <= maximumDirectIconBytes else { return nil }
            return try? Data(
                contentsOf: source.fileURL,
                options: [.mappedIfSafe]
            )
        }

        return WindowsExecutableIconExtractor.iconData(
            at: source.fileURL,
            iconIndex: source.iconIndex
        )
    }

    public static func iconData(
        for entry: WindowsStartMenuEntry,
        prefixPath: String,
        fileManager: FileManager = .default
    ) -> Data? {
        let sources = sources(
            for: entry,
            prefixPath: prefixPath,
            fileManager: fileManager
        )
        for source in sources {
            if let iconData = iconData(from: source, fileManager: fileManager) {
                return iconData
            }
        }
        return nil
    }

    private static func shortcutData(
        at url: URL,
        fileManager: FileManager
    ) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]), values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize > 0,
        fileSize <= maximumShortcutBytes else {
            return nil
        }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func expandedWindowsPath(
        _ rawPath: String,
        relativeTo workingDirectory: String?,
        scope: WindowsStartMenuScope
    ) -> String? {
        var path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        if path.hasPrefix("@") {
            path.removeFirst()
        }
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path.removeFirst()
            path.removeLast()
        }

        let userName: String?
        switch scope {
        case .allUsers:
            userName = nil
        case .user(let value):
            userName = value
        }
        var replacements: [(String, String)] = [
            ("%ProgramFiles(x86)%", #"C:\Program Files (x86)"#),
            ("%CommonProgramFiles(x86)%", #"C:\Program Files (x86)\Common Files"#),
            ("%CommonProgramFiles%", #"C:\Program Files\Common Files"#),
            ("%ProgramW6432%", #"C:\Program Files"#),
            ("%ProgramFiles%", #"C:\Program Files"#),
            ("%ALLUSERSPROFILE%", #"C:\ProgramData"#),
            ("%ProgramData%", #"C:\ProgramData"#),
            ("%SystemRoot%", #"C:\windows"#),
            ("%SystemDrive%", "C:"),
            ("%PUBLIC%", #"C:\users\Public"#),
            ("%windir%", #"C:\windows"#),
        ]
        if let userName {
            replacements.append(
                ("%LOCALAPPDATA%", #"C:\users\"# + userName + #"\AppData\Local"#)
            )
            replacements.append(
                ("%APPDATA%", #"C:\users\"# + userName + #"\AppData\Roaming"#)
            )
            replacements.append(
                ("%USERPROFILE%", #"C:\users\"# + userName)
            )
        }
        for (variable, value) in replacements {
            path = path.replacingOccurrences(
                of: variable,
                with: value,
                options: [.caseInsensitive]
            )
        }
        guard !path.contains("%") else { return nil }

        path = path.replacingOccurrences(of: "/", with: #"\"#)
        if isAbsoluteDriveCPath(path) {
            return path
        }
        guard let workingDirectory,
              let expandedWorkingDirectory = expandedWindowsPath(
                workingDirectory,
                relativeTo: nil,
                scope: scope
              ),
              isAbsoluteDriveCPath(expandedWorkingDirectory),
              !path.isEmpty,
              !path.contains(":"),
              !path.hasPrefix(#"\"#) else {
            return nil
        }
        return expandedWorkingDirectory.trimmingCharacters(
            in: CharacterSet(charactersIn: #"\"#)
        ) + #"\"# + path
    }

    private static func isAbsoluteDriveCPath(_ value: String) -> Bool {
        value.count >= 3
            && value.prefix(1).caseInsensitiveCompare("C") == .orderedSame
            && value.dropFirst().first == ":"
            && value.dropFirst(2).first == #"\"#
    }

    private static func regularHostURL(
        windowsPath: String,
        prefixPath: String,
        fileManager: FileManager
    ) -> URL? {
        guard windowsPath.utf16.count <= maximumWindowsPathCharacters,
              isAbsoluteDriveCPath(windowsPath) else {
            return nil
        }
        let components = windowsPath.dropFirst(3).split(
            separator: #"\"#,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.count <= maximumPathComponents,
              components.allSatisfy(isValidPathComponent) else {
            return nil
        }

        let prefixURL = URL(
            fileURLWithPath: prefixPath,
            isDirectory: true
        ).standardizedFileURL
        guard itemType(at: prefixURL, fileManager: fileManager) == .typeDirectory,
              let canonicalPrefixURL = canonicalDirectoryURL(
                prefixURL,
                fileManager: fileManager
              ) else {
            return nil
        }

        let driveURL = canonicalPrefixURL.appendingPathComponent(
            "drive_c",
            isDirectory: true
        )
        let candidateURL = components.reduce(driveURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL
        guard isContained(candidateURL, in: canonicalPrefixURL) else {
            return nil
        }

        let hostComponents = ["drive_c"] + components
        var currentURL = canonicalPrefixURL
        for (index, component) in hostComponents.enumerated() {
            currentURL.appendPathComponent(component)
            guard let type = itemType(at: currentURL, fileManager: fileManager),
                  type != .typeSymbolicLink else {
                return nil
            }
            if index == hostComponents.count - 1 {
                guard type == .typeRegular else { return nil }
            } else {
                guard type == .typeDirectory else { return nil }
            }
        }

        let resolvedCandidateURL = candidateURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(candidateURL.lastPathComponent)
            .standardizedFileURL
        guard isContained(resolvedCandidateURL, in: canonicalPrefixURL) else {
            return nil
        }
        return candidateURL
    }

    private static func canonicalDirectoryURL(
        _ url: URL,
        fileManager: FileManager
    ) -> URL? {
        guard itemType(at: url, fileManager: fileManager) == .typeDirectory else {
            return nil
        }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard itemType(at: resolvedURL, fileManager: fileManager) == .typeDirectory else {
            return nil
        }
        return resolvedURL
    }

    private static func itemType(
        at url: URL,
        fileManager: FileManager
    ) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type])
            as? FileAttributeType
    }

    private static func isValidPathComponent(_ component: String) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              component.utf16.count <= maximumComponentCharacters,
              !component.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return false
        }
        let invalidCharacters = CharacterSet(charactersIn: #"\/:*?\"<>|"#)
        return component.rangeOfCharacter(from: invalidCharacters) == nil
    }

    private static func isContained(_ candidateURL: URL, in rootURL: URL) -> Bool {
        candidateURL.path == rootURL.path
            || candidateURL.path.hasPrefix(rootURL.path + "/")
    }
}

private struct WindowsShortcutIconSourceKey: Hashable {
    let path: String
    let iconIndex: Int?

    init(_ source: WindowsShortcutIconSource) {
        path = source.fileURL.standardizedFileURL.path.lowercased()
        iconIndex = source.iconIndex
    }
}

struct ShortcutIconReference {
    let windowsPath: String
    let iconIndex: Int?
    let workingDirectory: String?
}

private struct WindowsInternetShortcutMetadata {
    let iconReference: ShortcutIconReference

    init?(data: Data) {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
        }
        guard let text else { return nil }

        var inInternetShortcutSection = false
        var iconFile: String?
        var iconIndex: Int?
        for rawLine in text.split(
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        ).prefix(4_096) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inInternetShortcutSection = line
                    .dropFirst()
                    .dropLast()
                    .caseInsensitiveCompare("InternetShortcut") == .orderedSame
                continue
            }
            guard inInternetShortcutSection,
                  let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare("IconFile") == .orderedSame {
                iconFile = value
            } else if key.caseInsensitiveCompare("IconIndex") == .orderedSame {
                iconIndex = Int(value)
            }
        }
        guard var iconFile, !iconFile.isEmpty else { return nil }
        if iconIndex == nil,
           let commaIndex = iconFile.lastIndex(of: ","),
           let parsedIndex = Int(
            iconFile[iconFile.index(after: commaIndex)...]
                .trimmingCharacters(in: .whitespaces)
           ) {
            iconIndex = parsedIndex
            iconFile = String(iconFile[..<commaIndex])
                .trimmingCharacters(in: .whitespaces)
        }
        iconReference = ShortcutIconReference(
            windowsPath: iconFile,
            iconIndex: iconIndex,
            workingDirectory: nil
        )
    }
}
