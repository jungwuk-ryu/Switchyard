import AppCore
import Foundation
import RuntimeCatalog

public struct ContainerFontInstallResult: Codable, Equatable, Sendable {
    public var installedFonts: [String]
    public var reusedFonts: [String]
    public var registeredFontEntries: Int
    public var registeredReplacements: Int
    public var skippedReason: String?

    public init(
        installedFonts: [String],
        reusedFonts: [String],
        registeredFontEntries: Int,
        registeredReplacements: Int,
        skippedReason: String? = nil
    ) {
        self.installedFonts = installedFonts
        self.reusedFonts = reusedFonts
        self.registeredFontEntries = registeredFontEntries
        self.registeredReplacements = registeredReplacements
        self.skippedReason = skippedReason
    }

    public var summary: String {
        if let skippedReason {
            return "Open fonts skipped: \(skippedReason)"
        }
        return "Open fonts ready: \(installedFonts.count) copied, \(reusedFonts.count) already present, \(registeredReplacements) family replacements registered."
    }
}

public enum ContainerFontInstallerError: LocalizedError, Equatable {
    case missingCachedFont(String, String)
    case invalidCachedFont(String, expected: String, actual: String)
    case invalidContainerPath(String)

    public var errorDescription: String? {
        switch self {
        case .missingCachedFont(let fontName, let path):
            return "\(fontName) is missing from the Open Font Pack cache: \(path)"
        case .invalidCachedFont(let fontName, let expected, let actual):
            return "\(fontName) in the Open Font Pack cache failed checksum validation. Expected \(expected), got \(actual)."
        case .invalidContainerPath(let path):
            return "Container path is empty or invalid: \(path)"
        }
    }
}

public struct ContainerFontInstaller {
    public var fileManager: FileManager
    public var catalog: [OpenFontFile]
    public var replacements: [FontReplacement]

    public init(
        fileManager: FileManager = .default,
        catalog: [OpenFontFile] = OpenFontPackCatalog.files,
        replacements: [FontReplacement] = OpenFontPackCatalog.replacements
    ) {
        self.fileManager = fileManager
        self.catalog = catalog
        self.replacements = replacements
    }

    public func installOpenFontPack(into container: Container, from fontCacheRoot: URL) throws -> ContainerFontInstallResult {
        let containerPath = container.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerPath.isEmpty else {
            throw ContainerFontInstallerError.invalidContainerPath(container.path)
        }

        let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        let systemRegistryURL = containerURL.appendingPathComponent("system.reg")
        let userRegistryURL = containerURL.appendingPathComponent("user.reg")
        guard registryHasArchitectureMarker(at: systemRegistryURL),
              registryHasArchitectureMarker(at: userRegistryURL) else {
            return ContainerFontInstallResult(
                installedFonts: [],
                reusedFonts: [],
                registeredFontEntries: 0,
                registeredReplacements: 0,
                skippedReason: "Wine has not initialized this container yet."
            )
        }

        let fontsURL = containerURL
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("windows", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
        try fileManager.createDirectory(at: fontsURL, withIntermediateDirectories: true)

        var installedFonts: [String] = []
        var reusedFonts: [String] = []
        var fontRegistryValues: [String: String] = [:]

        for font in catalog {
            let source = fontCacheRoot.appendingPathComponent(font.fileName)
            guard fileManager.fileExists(atPath: source.path) else {
                throw ContainerFontInstallerError.missingCachedFont(font.displayName, source.path)
            }

            let sourceDigest = try OpenFontPackCatalog.sha256Hex(for: source)
            guard sourceDigest == font.sha256 else {
                throw ContainerFontInstallerError.invalidCachedFont(font.displayName, expected: font.sha256, actual: sourceDigest)
            }

            let destination = fontsURL.appendingPathComponent(font.fileName)
            if try cachedFont(at: destination, matchesSHA256: font.sha256) {
                reusedFonts.append(font.displayName)
            } else {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
                installedFonts.append(font.displayName)
            }

            for entry in font.registryEntries {
                fontRegistryValues[entry] = font.fileName
            }
        }

        let replacementValues = Dictionary(
            uniqueKeysWithValues: replacements.map { ($0.requestedFamily, $0.replacementFamily) }
        )

        try registerFonts(
            containerURL: containerURL,
            fontValues: fontRegistryValues,
            replacementValues: replacementValues
        )

        return ContainerFontInstallResult(
            installedFonts: installedFonts,
            reusedFonts: reusedFonts,
            registeredFontEntries: fontRegistryValues.count,
            registeredReplacements: replacementValues.count
        )
    }

    private func registryHasArchitectureMarker(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.components(separatedBy: .newlines).contains { line in
            line.hasPrefix("#arch=")
        }
    }

    private func cachedFont(at url: URL, matchesSHA256 expectedSHA256: String) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        return try OpenFontPackCatalog.sha256Hex(for: url) == expectedSHA256
    }

    private func registerFonts(
        containerURL: URL,
        fontValues: [String: String],
        replacementValues: [String: String]
    ) throws {
        let systemRegistryURL = containerURL.appendingPathComponent("system.reg")
        var systemRegistry = try WineRegistryFile(url: systemRegistryURL)
        for section in [
            "Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts",
            "Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Fonts",
            "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts",
            "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Fonts"
        ] {
            systemRegistry.upsertStringValues(fontValues, in: section)
        }
        for section in [
            "Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes",
            "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes"
        ] {
            systemRegistry.upsertStringValues(replacementValues, in: section)
        }
        try systemRegistry.write()

        let userRegistryURL = containerURL.appendingPathComponent("user.reg")
        var userRegistry = try WineRegistryFile(url: userRegistryURL)
        userRegistry.upsertStringValues(replacementValues, in: "Software\\\\Wine\\\\Fonts\\\\Replacements")
        try userRegistry.write()
    }
}

private struct WineRegistryFile {
    var url: URL
    var lines: [String]

    init(url: URL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            self.lines = text.components(separatedBy: .newlines)
        } else {
            self.lines = ["WINE REGISTRY Version 2", ""]
        }
    }

    mutating func upsertStringValues(_ values: [String: String], in section: String) {
        guard !values.isEmpty else { return }

        let headerPrefix = "[\(section)]"
        let sectionStart: Int
        if let existingStart = lines.firstIndex(where: { $0.hasPrefix(headerPrefix) }) {
            sectionStart = existingStart
        } else {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[\(section)] \(Int(Date().timeIntervalSince1970))")
            lines.append("")
            sectionStart = lines.count - 2
        }

        var sectionEnd = lines.count
        if sectionStart + 1 < lines.count {
            for index in (sectionStart + 1)..<lines.count where lines[index].hasPrefix("[") {
                sectionEnd = index
                break
            }
        }

        var existingValueLines: [String: Int] = [:]
        for index in (sectionStart + 1)..<sectionEnd {
            guard let key = registryValueName(from: lines[index]) else {
                continue
            }
            existingValueLines[key] = index
        }

        var insertions: [String] = []
        for key in values.keys.sorted() {
            let line = "\"\(escapeRegistryString(key))\"=\"\(escapeRegistryString(values[key] ?? ""))\""
            if let index = existingValueLines[key] {
                lines[index] = line
            } else {
                insertions.append(line)
            }
        }

        if !insertions.isEmpty {
            lines.insert(contentsOf: insertions, at: sectionEnd)
        }
    }

    func write() throws {
        let text = lines.joined(separator: "\n")
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func registryValueName(from line: String) -> String? {
        guard line.first == "\"" else {
            return nil
        }
        var escaped = false
        var value = ""
        for character in line.dropFirst() {
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                return value
            }
            value.append(character)
        }
        return nil
    }

    private func escapeRegistryString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
