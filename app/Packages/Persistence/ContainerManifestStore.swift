import AppCore
import Foundation

public enum PersistenceError: Error, Equatable {
    case missingManifest(URL)
}

public struct ContainerManifestStore {
    public var rootURL: URL
    public var fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func loadContainers() throws -> [Container] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }

        let containerDirectories = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        return try containerDirectories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent("switchyard-container.json")
            let legacyManifestURL = directory.appendingPathComponent("switchyard-bottle.json")
            let readableManifestURL: URL
            if fileManager.fileExists(atPath: manifestURL.path) {
                readableManifestURL = manifestURL
            } else if fileManager.fileExists(atPath: legacyManifestURL.path) {
                readableManifestURL = legacyManifestURL
            } else {
                return nil
            }
            let data = try Data(contentsOf: readableManifestURL)
            var container = try JSONDecoder.switchyard.decode(Container.self, from: data)
            container.path = directory.path
            return container
        }
    }

    public func save(_ container: Container) throws {
        let directory = URL(fileURLWithPath: container.path, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("switchyard-container.json")
        let data = try JSONEncoder.switchyard.encode(container)
        try data.write(to: manifestURL, options: [.atomic])
    }
}

public struct SwitchyardContainerSnapshot: Codable, Equatable, Sendable {
    public var containers: [Container]
    public var launchers: [Launcher]

    public init(containers: [Container], launchers: [Launcher]) {
        self.containers = containers
        self.launchers = Self.normalizedLaunchers(containers: containers, launchers: launchers)
    }

    private enum CodingKeys: String, CodingKey {
        case containers
        case bottles
        case launchers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedContainers = try container.decodeIfPresent([Container].self, forKey: .containers) {
            containers = decodedContainers
        } else {
            containers = try container.decodeIfPresent([Container].self, forKey: .bottles) ?? []
        }
        launchers = Self.normalizedLaunchers(
            containers: containers,
            launchers: try container.decodeIfPresent([Launcher].self, forKey: .launchers) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(containers, forKey: .containers)
        try container.encode(launchers, forKey: .launchers)
    }

    private static func normalizedLaunchers(containers: [Container], launchers: [Launcher]) -> [Launcher] {
        containers.map { container in
            if let launcher = launchers.first(where: { $0.containerID == container.id }) {
                return launcher
            }
            return Launcher(
                name: container.name,
                kind: inferredLauncherKind(for: container.name),
                containerID: container.id,
                status: .needsSetup
            )
        }
    }

    private static func inferredLauncherKind(for name: String) -> LauncherKind {
        let lowercasedName = name.lowercased()
        if lowercasedName.contains("epic") {
            return .epicGames
        }
        if lowercasedName.contains("gog") {
            return .gogGalaxy
        }
        return .steam
    }
}

@available(*, deprecated, renamed: "SwitchyardContainerSnapshot")
public typealias SwitchyardLibrarySnapshot = SwitchyardContainerSnapshot

public struct LibraryManifestStore {
    public var rootURL: URL
    public var fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public var manifestURL: URL {
        rootURL.appendingPathComponent("switchyard-library.json")
    }

    public func loadSnapshot() throws -> SwitchyardContainerSnapshot? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            let containers = try ContainerManifestStore(rootURL: rootURL, fileManager: fileManager).loadContainers()
            return containers.isEmpty ? nil : SwitchyardContainerSnapshot(containers: containers, launchers: [])
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder.switchyard.decode(SwitchyardContainerSnapshot.self, from: data)
    }

    public func save(_ snapshot: SwitchyardContainerSnapshot) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.switchyard.encode(snapshot)
        try data.write(to: manifestURL, options: [.atomic])

        let containerStore = ContainerManifestStore(rootURL: rootURL, fileManager: fileManager)
        for container in snapshot.containers {
            try containerStore.save(container)
        }
    }
}

extension JSONEncoder {
    public static var switchyard: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var switchyard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
