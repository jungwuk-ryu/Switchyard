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
    public var lastActivatedAt: Date

    public init(
        scheme: String,
        containerID: UUID,
        prefixPath: String,
        winePath: String,
        runnerPath: String,
        lastActivatedAt: Date
    ) {
        self.scheme = scheme
        self.containerID = containerID
        self.prefixPath = prefixPath
        self.winePath = winePath
        self.runnerPath = runnerPath
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

public struct WineURLCallbackRequest: Codable, Equatable, Sendable {
    public var scheme: String
    public var rawURL: String
    public var prefixPath: String
    public var winePath: String

    public init(scheme: String, rawURL: String, prefixPath: String, winePath: String) {
        self.scheme = scheme
        self.rawURL = rawURL
        self.prefixPath = prefixPath
        self.winePath = winePath
    }
}
