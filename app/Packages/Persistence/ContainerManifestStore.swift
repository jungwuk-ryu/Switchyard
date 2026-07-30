import AppCore
import Foundation

public enum PersistenceError: LocalizedError, Equatable {
    case missingManifest(URL)
    case containerOutsideLibrary(URL)
    case unsafeManifest(URL)
    case duplicateContainerID(UUID, [URL])
    case duplicateContainerPath(URL, [UUID])

    public var errorDescription: String? {
        switch self {
        case .missingManifest(let url):
            String(
                localized: "The container folder has no Switchyard manifest: \(url.deletingLastPathComponent().path)",
                bundle: SwitchyardStrings.bundle
            )
        case .containerOutsideLibrary(let url):
            String(
                localized: "The container folder is outside the active Switchyard library: \(url.path)",
                bundle: SwitchyardStrings.bundle
            )
        case .unsafeManifest(let url):
            String(
                localized: "The container folder has no Switchyard manifest: \(url.deletingLastPathComponent().path)",
                bundle: SwitchyardStrings.bundle
            )
        case .duplicateContainerID(let id, let manifestURLs):
            String(
                localized: "Multiple container manifests use the same identifier \(id.uuidString): \(manifestURLs.map(\.path).joined(separator: ", "))",
                bundle: SwitchyardStrings.bundle
            )
        case .duplicateContainerPath(let directoryURL, let containerIDs):
            String(
                localized: "Multiple containers use the same folder \(directoryURL.path): \(containerIDs.map(\.uuidString).joined(separator: ", "))",
                bundle: SwitchyardStrings.bundle
            )
        }
    }
}

fileprivate struct PreparedContainerManifestSave {
    var containerID: UUID
    var directoryURL: URL
    var resolvedDirectoryURL: URL
    var manifestURL: URL
    var data: Data
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

        let containerDirectories = try fileManager.contentsOfDirectory(
            atPath: rootURL.path
        ).map {
            rootURL.appendingPathComponent($0, isDirectory: true)
        }.sorted {
            $0.path < $1.path
        }
        let loadedContainers = try containerDirectories.compactMap { directory
            -> (container: Container, manifestURL: URL)? in
            guard isContainerDirectoryInsideRoot(directory),
                  let readableManifestURL = readableManifestURL(in: directory) else {
                return nil
            }
            let data = try Data(contentsOf: readableManifestURL)
            var container = try JSONDecoder.switchyard.decode(Container.self, from: data)
            container.path = directory.path
            return (container, readableManifestURL)
        }

        let duplicate = Dictionary(grouping: loadedContainers) {
            $0.container.id
        }.filter {
            $0.value.count > 1
        }.min {
            $0.key.uuidString < $1.key.uuidString
        }
        if let duplicate {
            throw PersistenceError.duplicateContainerID(
                duplicate.key,
                duplicate.value.map(\.manifestURL).sorted {
                    $0.path < $1.path
                }
            )
        }

        return loadedContainers.map(\.container)
    }

    public func save(_ container: Container) throws {
        try write(prepareSave(container))
    }

    fileprivate func prepareSave(
        _ container: Container
    ) throws -> PreparedContainerManifestSave {
        let directory = try validatedContainerDirectory(
            URL(fileURLWithPath: container.path, isDirectory: true)
        )
        let manifestURL = directory.appendingPathComponent("switchyard-container.json")
        if fileSystemEntryExists(at: directory) {
            guard let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ),
            values.isDirectory == true,
            values.isSymbolicLink != true else {
                throw PersistenceError.unsafeManifest(manifestURL)
            }
        }
        if fileSystemEntryExists(at: manifestURL),
           !isRegularManifest(manifestURL, inside: directory) {
            throw PersistenceError.unsafeManifest(manifestURL)
        }
        let data = try JSONEncoder.switchyard.encode(container)
        return PreparedContainerManifestSave(
            containerID: container.id,
            directoryURL: directory,
            resolvedDirectoryURL: directory.resolvingSymlinksInPath(),
            manifestURL: manifestURL,
            data: data
        )
    }

    fileprivate func write(
        _ preparedSave: PreparedContainerManifestSave
    ) throws {
        try fileManager.createDirectory(
            at: preparedSave.directoryURL,
            withIntermediateDirectories: true
        )
        try preparedSave.data.write(
            to: preparedSave.manifestURL,
            options: [.atomic]
        )
    }

    private func validatedContainerDirectory(_ directory: URL) throws -> URL {
        let standardizedDirectory = directory.standardizedFileURL
        guard isContainerDirectoryInsideRoot(standardizedDirectory) else {
            throw PersistenceError.containerOutsideLibrary(standardizedDirectory)
        }
        return standardizedDirectory
    }

    private func isContainerDirectoryInsideRoot(_ directory: URL) -> Bool {
        let standardizedRoot = rootURL.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedParent = standardizedDirectory.deletingLastPathComponent()
        guard standardizedParent.path == standardizedRoot.path else {
            return false
        }

        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        guard standardizedParent.resolvingSymlinksInPath().path
                == resolvedRoot.path else {
            return false
        }
        if let values = try? standardizedDirectory.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ),
        values.isSymbolicLink == true {
            return false
        }

        guard fileManager.fileExists(atPath: standardizedDirectory.path) else {
            return true
        }
        let resolvedDirectory = standardizedDirectory.resolvingSymlinksInPath()
        return resolvedDirectory.deletingLastPathComponent().path
            == resolvedRoot.path
    }

    private func readableManifestURL(in directory: URL) -> URL? {
        for fileName in [
            "switchyard-container.json",
            "switchyard-bottle.json",
        ] {
            let manifestURL = directory.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                continue
            }
            if isRegularManifest(manifestURL, inside: directory) {
                return manifestURL
            }
        }
        return nil
    }

    private func isRegularManifest(_ manifestURL: URL, inside directory: URL) -> Bool {
        guard let values = try? manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            return false
        }

        let resolvedDirectory = directory.standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedManifest = manifestURL.standardizedFileURL
            .resolvingSymlinksInPath()
        return resolvedManifest.deletingLastPathComponent().path
            == resolvedDirectory.path
    }

    private func fileSystemEntryExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
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
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? String(localized: "Imported Entry", bundle: SwitchyardStrings.bundle)
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
        let manifestSnapshot = try loadSnapshotFromContainerManifests()

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return manifestSnapshot
        }

        let indexedSnapshot: SwitchyardContainerSnapshot
        do {
            let data = try Data(contentsOf: manifestURL)
            indexedSnapshot = try JSONDecoder.switchyard.decode(
                SwitchyardContainerSnapshot.self,
                from: data
            )
        } catch let indexError {
            if let manifestSnapshot {
                return manifestSnapshot
            }
            throw indexError
        }

        // Per-container manifests are the portable source of truth. The
        // aggregate library file is only a rebuildable index and must never
        // resurrect a missing, moved, nested, or otherwise untrusted path.
        if let manifestSnapshot {
            return manifestSnapshot
        }
        return try trustedLegacySnapshot(from: indexedSnapshot)
    }

    public func save(_ snapshot: SwitchyardContainerSnapshot) throws {
        try throwIfDuplicateContainerIDsBeforeSave(in: snapshot.containers)

        let containerStore = ContainerManifestStore(
            rootURL: rootURL,
            fileManager: fileManager
        )
        let preparedContainerSaves = try snapshot.containers.map {
            try containerStore.prepareSave($0)
        }
        try throwIfDuplicateContainerPaths(
            in: preparedContainerSaves
        )
        let data = try JSONEncoder.switchyard.encode(snapshot)
        try validateLibraryManifestDestination()

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        for preparedSave in preparedContainerSaves {
            try containerStore.write(preparedSave)
        }
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func loadSnapshotFromContainerManifests() throws -> SwitchyardContainerSnapshot? {
        let containers = try ContainerManifestStore(
            rootURL: rootURL,
            fileManager: fileManager
        ).loadContainers()
        guard !containers.isEmpty else {
            return nil
        }

        return SwitchyardContainerSnapshot(
            containers: containers.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return $0.path < $1.path
            }
        )
    }

    private func trustedLegacySnapshot(
        from indexedSnapshot: SwitchyardContainerSnapshot
    ) throws -> SwitchyardContainerSnapshot {
        let containers = indexedSnapshot.containers.compactMap {
            trustedLegacyContainer($0)
        }
        try throwIfDuplicateContainerIDs(in: containers)
        return SwitchyardContainerSnapshot(
            containers: containers.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return $0.path < $1.path
            }
        )
    }

    private func trustedLegacyContainer(_ container: Container) -> Container? {
        let directory = URL(fileURLWithPath: container.path, isDirectory: true)
            .standardizedFileURL
        let standardizedRoot = rootURL.standardizedFileURL
        guard directory.deletingLastPathComponent().path == standardizedRoot.path else {
            return nil
        }
        guard isExistingNonsymlinkDirectory(directory, under: standardizedRoot) else {
            return nil
        }
        var trustedContainer = container
        trustedContainer.path = directory.path
        return trustedContainer
    }

    private func isExistingNonsymlinkDirectory(
        _ directory: URL,
        under standardizedRoot: URL
    ) -> Bool {
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent()
            .resolvingSymlinksInPath().path == resolvedRoot.path else {
            return false
        }
        guard let values = try? directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
            return false
        }
        return directory.resolvingSymlinksInPath()
            .deletingLastPathComponent().path == resolvedRoot.path
    }

    private func throwIfDuplicateContainerIDs(
        in containers: [Container]
    ) throws {
        let duplicate = Dictionary(grouping: containers) {
            $0.id
        }.filter {
            $0.value.count > 1
        }.min {
            $0.key.uuidString < $1.key.uuidString
        }
        if let duplicate {
            throw PersistenceError.duplicateContainerID(
                duplicate.key,
                [manifestURL]
            )
        }
    }

    private func throwIfDuplicateContainerIDsBeforeSave(
        in containers: [Container]
    ) throws {
        let duplicate = Dictionary(grouping: containers) {
            $0.id
        }.filter {
            $0.value.count > 1
        }.min {
            $0.key.uuidString < $1.key.uuidString
        }
        if let duplicate {
            let manifestURLs = duplicate.value.map {
                URL(fileURLWithPath: $0.path, isDirectory: true)
                    .standardizedFileURL
                    .appendingPathComponent("switchyard-container.json")
            }.sorted {
                $0.path < $1.path
            }
            throw PersistenceError.duplicateContainerID(
                duplicate.key,
                manifestURLs
            )
        }
    }

    private func throwIfDuplicateContainerPaths(
        in preparedSaves: [PreparedContainerManifestSave]
    ) throws {
        let volumeSupportsCaseSensitiveNames =
            try volumeSupportsCaseSensitiveNames()
        var pathOwners: [String: Set<UUID>] = [:]
        var displayPaths: [String: String] = [:]
        for preparedSave in preparedSaves {
            let pathKeys = Set([
                preparedSave.directoryURL.path,
                preparedSave.resolvedDirectoryURL.path,
            ].map {
                comparisonKey(
                    for: $0,
                    volumeSupportsCaseSensitiveNames:
                        volumeSupportsCaseSensitiveNames
                )
            })
            for pathKey in pathKeys {
                pathOwners[pathKey, default: []].insert(
                    preparedSave.containerID
                )
                displayPaths[pathKey] = min(
                    displayPaths[pathKey] ?? preparedSave.directoryURL.path,
                    preparedSave.directoryURL.path
                )
            }
        }

        let duplicate = pathOwners.filter {
            $0.value.count > 1
        }.min {
            $0.key < $1.key
        }
        if let duplicate {
            throw PersistenceError.duplicateContainerPath(
                URL(
                    fileURLWithPath: displayPaths[duplicate.key]
                        ?? duplicate.key,
                    isDirectory: true
                ),
                duplicate.value.sorted {
                    $0.uuidString < $1.uuidString
                }
            )
        }
    }

    private func volumeSupportsCaseSensitiveNames() throws -> Bool {
        var candidate = rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw PersistenceError.unsafeManifest(manifestURL)
            }
            candidate = parent
        }

        guard let values = try? candidate.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ),
        let supportsCaseSensitiveNames =
            values.volumeSupportsCaseSensitiveNames else {
            throw PersistenceError.unsafeManifest(manifestURL)
        }
        return supportsCaseSensitiveNames
    }

    private func comparisonKey(
        for path: String,
        volumeSupportsCaseSensitiveNames: Bool
    ) -> String {
        guard !volumeSupportsCaseSensitiveNames else {
            return path
        }
        return path.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func validateLibraryManifestDestination() throws {
        let standardizedRoot = rootURL.standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        if fileSystemEntryExists(at: standardizedRoot) {
            guard let values = try? resolvedRoot.resourceValues(
                forKeys: [.isDirectoryKey]
            ),
            values.isDirectory == true else {
                throw PersistenceError.unsafeManifest(manifestURL)
            }
        }

        let standardizedManifest = manifestURL.standardizedFileURL
        guard standardizedManifest.deletingLastPathComponent().path
                == standardizedRoot.path else {
            throw PersistenceError.unsafeManifest(manifestURL)
        }
        guard fileSystemEntryExists(at: standardizedManifest) else {
            return
        }
        guard let values = try? standardizedManifest.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            throw PersistenceError.unsafeManifest(manifestURL)
        }
        let resolvedManifest = standardizedManifest
            .resolvingSymlinksInPath()
        guard resolvedManifest.deletingLastPathComponent().path
                == resolvedRoot.path else {
            throw PersistenceError.unsafeManifest(manifestURL)
        }
    }

    private func fileSystemEntryExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
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
