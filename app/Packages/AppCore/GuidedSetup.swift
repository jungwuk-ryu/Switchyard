import Foundation

public enum GuidedSetupRequirement: String, Codable, Equatable, Sendable {
    case checking
    case unsupportedMac
    case rosetta
    case runtime
    case toolkit
    case ready
}

public enum GuidedSetupPolicy {
    public static func nextRequirement(for status: RuntimeStatus) -> GuidedSetupRequirement {
        if status.architecture == .unknown || status.macOS == .unknown {
            return .checking
        }
        if status.architecture != .ok || status.macOS != .ok {
            return .unsupportedMac
        }
        if status.rosetta == .unknown {
            return .checking
        }
        if status.rosetta != .ok {
            return .rosetta
        }
        if status.wine == .unknown || status.patchset == .unknown {
            return .checking
        }
        if status.wine != .ok || status.patchset != .ok {
            return .runtime
        }
        if status.gptk == .unknown {
            return .checking
        }
        if status.gptk != .ok {
            return .toolkit
        }
        return .ready
    }

    public static func canComplete(with status: RuntimeStatus) -> Bool {
        nextRequirement(for: status) == .ready
    }
}

public struct StarterApplication: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var downloadURL: URL
    public var installerBaseName: String
    public var installerFileExtension: String
    public var trustedDownloadHosts: [String]
    public var maximumDownloadBytes: Int64

    public init(
        id: String,
        displayName: String,
        downloadURL: URL,
        installerBaseName: String,
        installerFileExtension: String = "exe",
        trustedDownloadHosts: [String],
        maximumDownloadBytes: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.installerBaseName = installerBaseName
        self.installerFileExtension = installerFileExtension
        self.trustedDownloadHosts = trustedDownloadHosts
        self.maximumDownloadBytes = maximumDownloadBytes
    }

    public func trustsDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedDownloadHosts.contains(where: { $0.lowercased() == host }),
              url.port == nil || url.port == 443,
              url.path == downloadURL.path else {
            return false
        }
        let expectedName = "\(installerBaseName).\(installerFileExtension)"
        return url.lastPathComponent.caseInsensitiveCompare(expectedName) == .orderedSame
    }

    public func recognizesInstaller(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare(installerFileExtension) == .orderedSame else {
            return false
        }
        let stem = url.deletingPathExtension().lastPathComponent
        guard recognizesInstallerStem(stem) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    public func hasWindowsExecutableHeader(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard recognizesInstaller(at: url, fileManager: fileManager),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data([0x4d, 0x5a])
    }

    private func recognizesInstallerStem(_ stem: String) -> Bool {
        if stem.caseInsensitiveCompare(installerBaseName) == .orderedSame {
            return true
        }

        let lowercasedStem = stem.lowercased()
        let lowercasedBaseName = installerBaseName.lowercased()
        guard lowercasedStem.hasPrefix(lowercasedBaseName) else {
            return false
        }
        let suffixStart = lowercasedStem.index(
            lowercasedStem.startIndex,
            offsetBy: lowercasedBaseName.count
        )
        let suffix = String(lowercasedStem[suffixStart...])
        let numericSuffix: String
        if suffix.hasPrefix(" (") && suffix.hasSuffix(")") {
            numericSuffix = String(suffix.dropFirst(2).dropLast())
        } else if let separator = suffix.first, separator == " " || separator == "-" || separator == "_" {
            numericSuffix = suffix.dropFirst().trimmingCharacters(in: .whitespaces)
        } else {
            return false
        }
        return Int(numericSuffix).map { $0 > 0 } ?? false
    }
}

public enum StarterApplicationCatalog {
    public static let steam = StarterApplication(
        id: "steam",
        displayName: "Steam",
        downloadURL: URL(
            string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"
        )!,
        installerBaseName: "SteamSetup",
        trustedDownloadHosts: [
            "cdn.fastly.steamstatic.com",
            "cdn.akamai.steamstatic.com"
        ],
        maximumDownloadBytes: 100 * 1_024 * 1_024
    )
}
