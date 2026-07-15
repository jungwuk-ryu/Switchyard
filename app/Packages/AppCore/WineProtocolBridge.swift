import Foundation

public enum WineProtocolAssociationFormat {
    public static let manifestHeader = "# switchyard-wine-protocols-v1"
    public static let manifestEnvironmentKey = "SWITCHYARD_PROTOCOL_ASSOCIATIONS_FILE"
    public static let windowsManifestPath = #"C:\windows\temp\switchyard-protocols-v1.txt"#

    private static let reservedSchemes: Set<String> = [
        "about", "blob", "data", "facetime", "file", "ftp", "http", "https",
        "javascript", "mailto", "sms", "tel"
    ]

    public static func manifestURL(prefixPath: String) -> URL {
        URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c/windows/temp", isDirectory: true)
            .appendingPathComponent("switchyard-protocols-v1.txt")
    }

    public static func normalizedScheme(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128 else { return nil }
        let scalars = rawValue.unicodeScalars
        guard let first = scalars.first, isASCIILetter(first) else { return nil }
        guard scalars.dropFirst().allSatisfy({ scalar in
            isASCIILetter(scalar) || isASCIIDigit(scalar) || scalar == "+" || scalar == "-" || scalar == "."
        }) else {
            return nil
        }

        let normalized = rawValue.lowercased()
        return reservedSchemes.contains(normalized) ? nil : normalized
    }

    public static func scheme(inRawURL rawURL: String) -> String? {
        guard rawURL.utf8.count <= 65_536 else { return nil }
        guard let separator = rawURL.firstIndex(of: ":") else { return nil }
        return normalizedScheme(String(rawURL[..<separator]))
    }

    public static func schemes(inManifest contents: String) -> Set<String> {
        let lines = contents.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.first == manifestHeader else { return [] }
        return Set(lines.dropFirst().compactMap(normalizedScheme))
    }

    public static func normalizedWindowsExecutablePath(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: "/", with: #"\"#)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 32_768,
              normalized.count >= 4,
              normalized.lowercased().hasSuffix(".exe"),
              !trimmed.contains("\""),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            return nil
        }
        let prefixScalars = normalized.unicodeScalars.prefix(3)
        guard prefixScalars.count == 3,
              let driveLetter = prefixScalars.first,
              isASCIILetter(driveLetter),
              prefixScalars[prefixScalars.index(after: prefixScalars.startIndex)] == ":",
              prefixScalars[prefixScalars.index(prefixScalars.startIndex, offsetBy: 2)] == "\\" else {
            return nil
        }

        let components = normalized.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return normalized
    }

    public static func windowsExecutablePath(hostPath: String, prefixPath: String) -> String? {
        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true).standardizedFileURL
        let driveCURL = prefixURL
            .appendingPathComponent("drive_c", isDirectory: true)
            .standardizedFileURL
        let executableURL = URL(fileURLWithPath: hostPath).standardizedFileURL
        var mappings: [(letter: String, rootURL: URL)] = [("C", driveCURL)]

        let dosDevicesURL = prefixURL.appendingPathComponent("dosdevices", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dosDevicesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.count == 2,
                      name.last == ":",
                      let scalar = name.unicodeScalars.first,
                      isASCIILetter(scalar) else {
                    continue
                }
                mappings.append((String(name.prefix(1)).uppercased(), entry.resolvingSymlinksInPath()))
            }
        }

        mappings.sort { $0.rootURL.path.count > $1.rootURL.path.count }
        for mapping in mappings {
            let rootPath = mapping.rootURL.path
            let relativePath: String
            if rootPath == "/", executableURL.path.hasPrefix("/") {
                relativePath = String(executableURL.path.dropFirst())
            } else if executableURL.path.hasPrefix(rootPath + "/") {
                relativePath = String(executableURL.path.dropFirst(rootPath.count + 1))
            } else {
                continue
            }

            if let result = normalizedWindowsExecutablePath(
                mapping.letter + #":\"# + relativePath.replacingOccurrences(of: "/", with: #"\"#)
            ) {
                return result
            }
        }
        return nil
    }

    public static func callbackTargetCandidates(
        from runningExecutablePaths: [String],
        excluding excludedPaths: Set<String> = []
    ) -> [String] {
        let excluded = Set(excludedPaths.compactMap(normalizedWindowsExecutablePath).map { $0.lowercased() })
        let ignoredNames: Set<String> = [
            "explorer", "plugplay", "rpcss", "services", "start", "svchost",
            "winedevice", "winemenubuilder", "wmic"
        ]
        let ignoredNameFragments = [
            "bootstrap", "crash", "helper", "installer", "reporter", "service",
            "setup", "unins", "update", "updater"
        ]

        var uniquePaths: [String: String] = [:]
        for rawPath in runningExecutablePaths {
            guard let path = normalizedWindowsExecutablePath(rawPath) else { continue }
            let lowercasePath = path.lowercased()
            guard !lowercasePath.dropFirst(1).hasPrefix(#":\windows\"#),
                  !excluded.contains(lowercasePath) else {
                continue
            }
            let executableName = URL(fileURLWithPath: path.replacingOccurrences(of: #"\"#, with: "/"))
                .deletingPathExtension()
                .lastPathComponent
                .lowercased()
            guard !ignoredNames.contains(executableName),
                  !ignoredNameFragments.contains(where: executableName.contains) else {
                continue
            }
            uniquePaths[lowercasePath] = path
        }
        return uniquePaths.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(Int(scalar.value))
    }
}

public struct WineProtocolRoute: Codable, Equatable, Sendable {
    public var scheme: String
    public var containerID: UUID
    public var prefixPath: String
    public var winePath: String
    public var runnerPath: String
    public var handlerExecutablePath: String?
    public var lastActivatedAt: Date

    public init(
        scheme: String,
        containerID: UUID,
        prefixPath: String,
        winePath: String,
        runnerPath: String,
        handlerExecutablePath: String? = nil,
        lastActivatedAt: Date
    ) {
        self.scheme = scheme
        self.containerID = containerID
        self.prefixPath = prefixPath
        self.winePath = winePath
        self.runnerPath = runnerPath
        self.handlerExecutablePath = handlerExecutablePath
        self.lastActivatedAt = lastActivatedAt
    }
}

public struct WineProtocolRouteIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var routes: [WineProtocolRoute]

    public init(version: Int = currentVersion, routes: [WineProtocolRoute]) {
        self.version = version
        self.routes = routes
    }

    public func route(forScheme rawScheme: String) -> WineProtocolRoute? {
        guard version == Self.currentVersion,
              let scheme = WineProtocolAssociationFormat.normalizedScheme(rawScheme) else {
            return nil
        }

        return routes
            .filter { $0.scheme == scheme }
            .max { lhs, rhs in
                if lhs.lastActivatedAt == rhs.lastActivatedAt {
                    return lhs.containerID.uuidString < rhs.containerID.uuidString
                }
                return lhs.lastActivatedAt < rhs.lastActivatedAt
            }
    }
}

public struct WineProtocolLearnedAssociation: Codable, Equatable, Sendable {
    public var scheme: String
    public var containerID: UUID
    public var handlerExecutablePath: String?
    public var learnedAt: Date

    public init(
        scheme: String,
        containerID: UUID,
        handlerExecutablePath: String? = nil,
        learnedAt: Date
    ) {
        self.scheme = scheme
        self.containerID = containerID
        self.handlerExecutablePath = handlerExecutablePath
        self.learnedAt = learnedAt
    }
}

public struct WineProtocolLearnedAssociationIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var associations: [WineProtocolLearnedAssociation]

    public init(
        version: Int = currentVersion,
        associations: [WineProtocolLearnedAssociation] = []
    ) {
        self.version = version
        self.associations = associations
    }

    @discardableResult
    public mutating func learn(
        scheme rawScheme: String,
        for containerID: UUID,
        handlerExecutablePath: String? = nil,
        at date: Date = Date()
    ) -> String? {
        guard version == Self.currentVersion,
              let scheme = WineProtocolAssociationFormat.normalizedScheme(rawScheme) else {
            return nil
        }
        let normalizedHandlerPath = handlerExecutablePath.flatMap(
            WineProtocolAssociationFormat.normalizedWindowsExecutablePath
        )
        guard handlerExecutablePath == nil || normalizedHandlerPath != nil else { return nil }

        associations.removeAll {
            $0.containerID == containerID
                && WineProtocolAssociationFormat.normalizedScheme($0.scheme) == scheme
        }
        associations.append(
            WineProtocolLearnedAssociation(
                scheme: scheme,
                containerID: containerID,
                handlerExecutablePath: normalizedHandlerPath,
                learnedAt: date
            )
        )
        return scheme
    }

    public func associations(
        for containerID: UUID
    ) -> [WineProtocolLearnedAssociation] {
        guard version == Self.currentVersion else { return [] }

        return associations.compactMap { association in
            guard association.containerID == containerID,
                  let scheme = WineProtocolAssociationFormat.normalizedScheme(association.scheme) else {
                return nil
            }
            return WineProtocolLearnedAssociation(
                scheme: scheme,
                containerID: association.containerID,
                handlerExecutablePath: association.handlerExecutablePath
                    .flatMap(WineProtocolAssociationFormat.normalizedWindowsExecutablePath),
                learnedAt: association.learnedAt
            )
        }
    }

    public func pruning(to validContainerIDs: Set<UUID>) -> Self {
        guard version == Self.currentVersion else { return Self() }

        var result = Self()
        for association in associations where validContainerIDs.contains(association.containerID) {
            _ = result.learn(
                scheme: association.scheme,
                for: association.containerID,
                handlerExecutablePath: association.handlerExecutablePath,
                at: association.learnedAt
            )
        }
        return result
    }
}

public struct WineURLCallbackRequest: Codable, Equatable, Sendable {
    public var scheme: String
    public var rawURL: String
    public var prefixPath: String
    public var winePath: String
    public var handlerExecutablePath: String?

    public init(
        scheme: String,
        rawURL: String,
        prefixPath: String,
        winePath: String,
        handlerExecutablePath: String? = nil
    ) {
        self.scheme = scheme
        self.rawURL = rawURL
        self.prefixPath = prefixPath
        self.winePath = winePath
        self.handlerExecutablePath = handlerExecutablePath
    }
}
