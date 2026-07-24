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
        if status.wine == .unknown || status.wineSource == .unknown {
            return .checking
        }
        if status.wine != .ok || status.wineSource != .ok {
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

public enum StarterApplicationInstallerFormat: String, Equatable, Sendable {
    case executable = "exe"
    case windowsInstaller = "msi"

    fileprivate var header: Data {
        switch self {
        case .executable:
            Data([0x4d, 0x5a])
        case .windowsInstaller:
            Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
        }
    }
}

public enum StarterApplicationInstallerFilenameRule: Equatable, Sendable {
    case exact(String)
    case prefixed(String, fileExtension: String)

    fileprivate func matches(_ filename: String) -> Bool {
        switch self {
        case .exact(let expected):
            return filename.caseInsensitiveCompare(expected) == .orderedSame
        case .prefixed(let prefix, let fileExtension):
            let url = URL(fileURLWithPath: filename)
            let stem = url.deletingPathExtension().lastPathComponent
            return url.pathExtension.caseInsensitiveCompare(fileExtension) == .orderedSame
                && stem.lowercased().hasPrefix(prefix.lowercased())
                && stem.count > prefix.count
        }
    }
}

public struct StarterApplicationDownloadRule: Equatable, Sendable {
    public var host: String
    public var pathPrefix: String
    public var filenameRule: StarterApplicationInstallerFilenameRule
    public var allowedQueryItemNames: Set<String>

    public init(
        host: String,
        pathPrefix: String,
        filenameRule: StarterApplicationInstallerFilenameRule,
        allowedQueryItemNames: Set<String> = []
    ) {
        self.host = host
        self.pathPrefix = pathPrefix
        self.filenameRule = filenameRule
        self.allowedQueryItemNames = allowedQueryItemNames
    }

    fileprivate func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.caseInsensitiveCompare(host) == .orderedSame,
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.path.hasPrefix(pathPrefix),
              filenameRule.matches(url.lastPathComponent),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return (components.queryItems ?? []).allSatisfy {
            allowedQueryItemNames.contains($0.name)
        }
    }
}

public struct StarterApplicationExecutableRule: Equatable, Sendable {
    public var executableName: String
    public var requiredPathComponents: [String]

    public init(executableName: String, requiredPathComponents: [String]) {
        self.executableName = executableName
        self.requiredPathComponents = requiredPathComponents
    }

    fileprivate func matches(_ program: InstalledProgram) -> Bool {
        let components = URL(fileURLWithPath: program.executablePath).pathComponents
        guard components.last?.caseInsensitiveCompare(executableName) == .orderedSame else {
            return false
        }

        var requiredIndex = requiredPathComponents.startIndex
        for component in components.dropLast() where requiredIndex < requiredPathComponents.endIndex {
            if component.caseInsensitiveCompare(requiredPathComponents[requiredIndex]) == .orderedSame {
                requiredIndex = requiredPathComponents.index(after: requiredIndex)
            }
        }
        return requiredIndex == requiredPathComponents.endIndex
    }
}

public struct StarterApplication: Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var publisherName: String
    public var systemImage: String
    public var downloadURL: URL
    public var officialDownloadPageURL: URL
    public var installerBaseName: String
    public var installerFormat: StarterApplicationInstallerFormat
    public var trustedDownloadRules: [StarterApplicationDownloadRule]
    public var installedExecutableRules: [StarterApplicationExecutableRule]
    public var maximumDownloadBytes: Int64

    public var installerFileExtension: String {
        installerFormat.rawValue
    }

    public init(
        id: String,
        displayName: String,
        publisherName: String,
        systemImage: String,
        downloadURL: URL,
        officialDownloadPageURL: URL,
        installerBaseName: String,
        installerFormat: StarterApplicationInstallerFormat = .executable,
        trustedDownloadRules: [StarterApplicationDownloadRule],
        installedExecutableRules: [StarterApplicationExecutableRule],
        maximumDownloadBytes: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.publisherName = publisherName
        self.systemImage = systemImage
        self.downloadURL = downloadURL
        self.officialDownloadPageURL = officialDownloadPageURL
        self.installerBaseName = installerBaseName
        self.installerFormat = installerFormat
        self.trustedDownloadRules = trustedDownloadRules
        self.installedExecutableRules = installedExecutableRules
        self.maximumDownloadBytes = maximumDownloadBytes
    }

    public func trustsDownloadURL(_ url: URL) -> Bool {
        matchesOfficialDownloadURL(url)
            || trustedDownloadRules.contains(where: { $0.allows(url) })
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

    public func hasExpectedInstallerHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: installerFormat.header.count))
            == installerFormat.header
    }

    public func hasWindowsExecutableHeader(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard installerFormat == .executable,
              recognizesInstaller(at: url, fileManager: fileManager) else {
            return false
        }
        return hasExpectedInstallerHeader(at: url)
    }

    public func installedProgram(in programs: [InstalledProgram]) -> InstalledProgram? {
        programs.first(where: { program in
            installedExecutableRules.contains(where: { $0.matches(program) })
        })
    }

    public func recognizesInstalledProgram(_ program: InstalledProgram) -> Bool {
        installedExecutableRules.contains(where: { $0.matches(program) })
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

    private func matchesOfficialDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.caseInsensitiveCompare(downloadURL.host ?? "") == .orderedSame,
              (url.port ?? 443) == (downloadURL.port ?? 443),
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.path == downloadURL.path,
              let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(
                  url: downloadURL,
                  resolvingAgainstBaseURL: false
              ) else {
            return false
        }
        let candidateQuery = (candidate.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
        let expectedQuery = (expected.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
        return candidateQuery == expectedQuery
    }
}

public enum StarterApplicationCatalog {
    public static let steam = StarterApplication(
        id: "steam",
        displayName: "Steam",
        publisherName: "Valve",
        systemImage: "gamecontroller.fill",
        downloadURL: URL(
            string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"
        )!,
        officialDownloadPageURL: URL(string: "https://store.steampowered.com/about/")!,
        installerBaseName: "SteamSetup",
        trustedDownloadRules: [
            StarterApplicationDownloadRule(
                host: "cdn.fastly.steamstatic.com",
                pathPrefix: "/client/installer/",
                filenameRule: .exact("SteamSetup.exe")
            ),
            StarterApplicationDownloadRule(
                host: "cdn.akamai.steamstatic.com",
                pathPrefix: "/client/installer/",
                filenameRule: .exact("SteamSetup.exe")
            )
        ],
        installedExecutableRules: [
            StarterApplicationExecutableRule(
                executableName: "steam.exe",
                requiredPathComponents: ["Steam"]
            )
        ],
        maximumDownloadBytes: 100 * 1_024 * 1_024
    )

    public static let battleNet = StarterApplication(
        id: "battle-net",
        displayName: "Battle.net",
        publisherName: "Blizzard Entertainment",
        systemImage: "bolt.horizontal.circle.fill",
        downloadURL: URL(
            string: "https://downloader.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live"
        )!,
        officialDownloadPageURL: URL(string: "https://download.battle.net/en-us/desktop")!,
        installerBaseName: "Battle.net-Setup",
        trustedDownloadRules: [
            StarterApplicationDownloadRule(
                host: "downloader.battle.net",
                pathPrefix: "/download/installer/win/",
                filenameRule: .exact("Battle.net-Setup.exe")
            )
        ],
        installedExecutableRules: [
            StarterApplicationExecutableRule(
                executableName: "Battle.net Launcher.exe",
                requiredPathComponents: ["Battle.net"]
            ),
            StarterApplicationExecutableRule(
                executableName: "Battle.net.exe",
                requiredPathComponents: ["Battle.net"]
            )
        ],
        maximumDownloadBytes: 32 * 1_024 * 1_024
    )

    public static let epicGames = StarterApplication(
        id: "epic-games",
        displayName: "Epic Games Launcher",
        publisherName: "Epic Games",
        systemImage: "building.columns.fill",
        downloadURL: URL(
            string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi"
        )!,
        officialDownloadPageURL: URL(string: "https://store.epicgames.com/download")!,
        installerBaseName: "EpicGamesLauncherInstaller",
        installerFormat: .windowsInstaller,
        trustedDownloadRules: [
            StarterApplicationDownloadRule(
                host: "epicgames-download1.akamaized.net",
                pathPrefix: "/Builds/UnrealEngineLauncher/Installers/Windows/",
                filenameRule: .prefixed("EpicInstaller-", fileExtension: "msi"),
                allowedQueryItemNames: ["launcherfilename"]
            )
        ],
        installedExecutableRules: [
            StarterApplicationExecutableRule(
                executableName: "EpicGamesLauncher.exe",
                requiredPathComponents: ["Epic Games", "Launcher"]
            )
        ],
        maximumDownloadBytes: 256 * 1_024 * 1_024
    )

    public static let rockstarGames = StarterApplication(
        id: "rockstar-games",
        displayName: "Rockstar Games Launcher",
        publisherName: "Rockstar Games",
        systemImage: "star.fill",
        downloadURL: URL(
            string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe"
        )!,
        officialDownloadPageURL: URL(
            string: "https://support.rockstargames.com/articles/4extB4aITvMKdDEZzsFAwE/rockstar-games-launcher-download"
        )!,
        installerBaseName: "Rockstar-Games-Launcher",
        trustedDownloadRules: [
            StarterApplicationDownloadRule(
                host: "gamedownloads.rockstargames.com",
                pathPrefix: "/public/installer/",
                filenameRule: .exact("Rockstar-Games-Launcher.exe")
            )
        ],
        installedExecutableRules: [
            StarterApplicationExecutableRule(
                executableName: "Launcher.exe",
                requiredPathComponents: ["Rockstar Games", "Launcher"]
            ),
            StarterApplicationExecutableRule(
                executableName: "Rockstar Games Launcher.exe",
                requiredPathComponents: ["Rockstar Games"]
            )
        ],
        maximumDownloadBytes: 256 * 1_024 * 1_024
    )

    public static let all = [
        steam,
        battleNet,
        epicGames,
        rockstarGames
    ]

    public static func application(id: String) -> StarterApplication? {
        all.first(where: { $0.id == id })
    }
}
