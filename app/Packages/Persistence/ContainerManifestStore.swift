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

    public init(containers: [Container]) {
        self.containers = containers
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
        containers = Self.migratingLegacyRunTargets(
            into: containers,
            legacyRunTargets: try container.decodeIfPresent([LegacyRunTarget].self, forKey: .launchers) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(containers, forKey: .containers)
    }

    private static func migratingLegacyRunTargets(into containers: [Container], legacyRunTargets: [LegacyRunTarget]) -> [Container] {
        containers.map { container in
            guard let legacyRunTarget = legacyRunTargets.first(where: { $0.containerID == container.id }) else {
                return container
            }

            var migratedContainer = container
            if migratedContainer.executablePath == nil {
                migratedContainer.executablePath = legacyRunTarget.executablePath
            }
            if migratedContainer.lastRun == nil {
                migratedContainer.lastRun = legacyRunTarget.lastRun
            }
            if migratedContainer.status == .needsSetup {
                migratedContainer.status = legacyRunTarget.status
            }
            return migratedContainer
        }
    }
}

private struct LegacyRunTarget: Decodable, Equatable, Sendable {
    var id: UUID
    var name: String
    var containerID: UUID
    var executablePath: String?
    var lastRun: Date?
    var status: ContainerStatus

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case containerID
        case bottleID
        case executablePath
        case lastRun
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Imported Entry"
        if let decodedContainerID = try container.decodeIfPresent(UUID.self, forKey: .containerID) {
            containerID = decodedContainerID
        } else {
            containerID = try container.decode(UUID.self, forKey: .bottleID)
        }
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
        status = try container.decodeIfPresent(ContainerStatus.self, forKey: .status) ?? .needsSetup
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
            return containers.isEmpty ? nil : SwitchyardContainerSnapshot(containers: containers)
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
