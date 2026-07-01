import AppCore
import Foundation

public enum PersistenceError: Error, Equatable {
    case missingManifest(URL)
}

public struct BottleManifestStore {
    public var rootURL: URL
    public var fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func loadBottles() throws -> [Bottle] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }

        let bottleDirectories = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        return try bottleDirectories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent("switchyard-bottle.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                return nil
            }
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder.switchyard.decode(Bottle.self, from: data)
        }
    }

    public func save(_ bottle: Bottle) throws {
        let directory = URL(fileURLWithPath: bottle.path, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("switchyard-bottle.json")
        let data = try JSONEncoder.switchyard.encode(bottle)
        try data.write(to: manifestURL, options: [.atomic])
    }
}

public struct SwitchyardLibrarySnapshot: Codable, Equatable, Sendable {
    public var bottles: [Bottle]
    public var launchers: [Launcher]

    public init(bottles: [Bottle], launchers: [Launcher]) {
        self.bottles = bottles
        self.launchers = launchers
    }
}

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

    public func loadSnapshot() throws -> SwitchyardLibrarySnapshot? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            let bottles = try BottleManifestStore(rootURL: rootURL, fileManager: fileManager).loadBottles()
            return bottles.isEmpty ? nil : SwitchyardLibrarySnapshot(bottles: bottles, launchers: [])
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder.switchyard.decode(SwitchyardLibrarySnapshot.self, from: data)
    }

    public func save(_ snapshot: SwitchyardLibrarySnapshot) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.switchyard.encode(snapshot)
        try data.write(to: manifestURL, options: [.atomic])

        let bottleStore = BottleManifestStore(rootURL: rootURL, fileManager: fileManager)
        for bottle in snapshot.bottles {
            try bottleStore.save(bottle)
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
