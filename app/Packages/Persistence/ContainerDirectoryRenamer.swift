import AppCore
import Foundation

public enum ContainerDirectoryRenameError: LocalizedError {
    case emptyName
    case sourceOutsideLibrary(URL)
    case sourceMissing(URL)
    case sourceHasNoManifest(URL)
    case directoryMoveFailed(
        source: URL,
        destination: URL,
        recoveryLocations: [URL],
        reason: String
    )
    case directoryStateRecoveryFailed(
        source: URL,
        destination: URL,
        recoveryLocations: [URL],
        moveReason: String,
        recoveryReason: String
    )
    case rollbackFailed(
        source: URL,
        destination: URL,
        recoveryLocations: [URL],
        saveReason: String,
        rollbackReason: String
    )
    case stateRecoveryFailed(
        recoveryLocations: [URL],
        saveReason: String,
        rollbackReason: String?,
        recoveryReason: String
    )

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(
                localized: "Container names cannot be empty.",
                bundle: SwitchyardStrings.bundle
            )
        case .sourceOutsideLibrary(let url):
            return String(
                localized: "The container folder is outside the active Switchyard library: \(url.path)",
                bundle: SwitchyardStrings.bundle
            )
        case .sourceMissing(let url):
            return String(
                localized: "The container folder is missing: \(url.path)",
                bundle: SwitchyardStrings.bundle
            )
        case .sourceHasNoManifest(let url):
            return String(
                localized: "The container folder has no Switchyard manifest: \(url.path)",
                bundle: SwitchyardStrings.bundle
            )
        case let .directoryMoveFailed(
            source,
            destination,
            recoveryLocations,
            reason
        ):
            return String(
                localized: "Could not move the container folder from \(source.path) to \(destination.path). \(recoveryDescription(for: recoveryLocations)) \(reason)",
                bundle: SwitchyardStrings.bundle
            )
        case let .directoryStateRecoveryFailed(
            source,
            destination,
            recoveryLocations,
            moveReason,
            recoveryReason
        ):
            return String(
                localized: "Could not restore a consistent container manifest after moving the folder from \(source.path) to \(destination.path) failed. \(recoveryDescription(for: recoveryLocations)) Move error: \(moveReason) Recovery error: \(recoveryReason)",
                bundle: SwitchyardStrings.bundle
            )
        case let .rollbackFailed(
            source,
            destination,
            recoveryLocations,
            saveReason,
            rollbackReason
        ):
            return String(
                localized: "Could not roll the container folder back from \(destination.path) to \(source.path) after saving failed. \(recoveryDescription(for: recoveryLocations)) Save error: \(saveReason) Rollback error: \(rollbackReason)",
                bundle: SwitchyardStrings.bundle
            )
        case let .stateRecoveryFailed(
            recoveryLocations,
            saveReason,
            rollbackReason,
            recoveryReason
        ):
            let rollbackDetail = rollbackReason.map {
                " Rollback error: \($0)"
            } ?? ""
            return String(
                localized: "Could not restore a consistent container manifest after saving failed. \(recoveryDescription(for: recoveryLocations)) Save error: \(saveReason)\(rollbackDetail) Recovery error: \(recoveryReason)",
                bundle: SwitchyardStrings.bundle
            )
        }
    }

    private func recoveryDescription(for locations: [URL]) -> String {
        guard !locations.isEmpty else {
            return String(
                localized: "Switchyard could not locate the container folder.",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Container data remains at: \(locations.map(\.path).joined(separator: ", ")).",
            bundle: SwitchyardStrings.bundle
        )
    }
}

public struct ContainerDirectoryRenamer {
    public var rootURL: URL
    public var fileManager: FileManager
    private var moveItemOverride: ((URL, URL) throws -> Void)?
    private var saveManifestOverride: ((Container) throws -> Void)?

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.moveItemOverride = nil
        self.saveManifestOverride = nil
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        moveItem: @escaping (URL, URL) throws -> Void,
        saveManifest: @escaping (Container) throws -> Void
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.moveItemOverride = moveItem
        self.saveManifestOverride = saveManifest
    }

    public func rename(
        _ container: Container,
        to requestedName: String,
        occupiedDirectoryNames: Set<String> = []
    ) throws -> Container {
        try rename(
            container,
            to: requestedName,
            occupiedDirectoryNames: occupiedDirectoryNames
        ) { renamedContainer in
            try ContainerManifestStore(rootURL: rootURL, fileManager: fileManager)
                .save(renamedContainer)
        }
    }

    public func rename(
        _ container: Container,
        to requestedName: String,
        occupiedDirectoryNames: Set<String> = [],
        savingWith save: (Container) throws -> Void
    ) throws -> Container {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ContainerDirectoryRenameError.emptyName
        }

        let libraryURL = rootURL.standardizedFileURL
        let sourceURL = URL(
            fileURLWithPath: container.path,
            isDirectory: true
        ).standardizedFileURL
        guard sourceURL.deletingLastPathComponent().path == libraryURL.path,
              sourceURL.resolvingSymlinksInPath().deletingLastPathComponent().path
                == libraryURL.resolvingSymlinksInPath().path else {
            throw ContainerDirectoryRenameError.sourceOutsideLibrary(sourceURL)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ContainerDirectoryRenameError.sourceMissing(sourceURL)
        }
        guard hasContainerManifest(at: sourceURL) else {
            throw ContainerDirectoryRenameError.sourceHasNoManifest(sourceURL)
        }

        let resolvedSourcePath = sourceURL.resolvingSymlinksInPath().path
        let onDiskNames = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).reduce(into: Set<String>()) { names, entry in
            guard entry.resolvingSymlinksInPath().path != resolvedSourcePath,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return
            }
            names.insert(entry.lastPathComponent)
        }
        let destinationName = ContainerPathPolicy.uniqueDirectoryName(
            for: name,
            existingDirectoryNames: onDiskNames.union(occupiedDirectoryNames)
        )
        let destinationURL = libraryURL.appendingPathComponent(destinationName, isDirectory: true)

        var renamedContainer = container
        renamedContainer.name = name
        renamedContainer.path = destinationURL.path
        if let executablePath = container.executablePath {
            renamedContainer.executablePath = ContainerPathPolicy.relocatingPath(
                executablePath,
                from: sourceURL.path,
                to: destinationURL.path
            )
        }
        renamedContainer.lastModified = Date()

        guard sourceURL.path != destinationURL.path else {
            do {
                try save(renamedContainer)
            } catch let saveError {
                do {
                    try recoverManifest(
                        container,
                        at: sourceURL,
                        relocatingFrom: sourceURL
                    )
                } catch let recoveryError {
                    throw ContainerDirectoryRenameError.stateRecoveryFailed(
                        recoveryLocations: [sourceURL],
                        saveReason: Self.describe(saveError),
                        rollbackReason: nil,
                        recoveryReason: Self.describe(recoveryError)
                    )
                }
                throw saveError
            }
            return renamedContainer
        }

        do {
            try moveDirectory(from: sourceURL, to: destinationURL)
        } catch let moveError as DirectoryMoveFailure {
            do {
                try recoverInitialMoveFailure(
                    originalContainer: container,
                    renamedContainer: renamedContainer,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    recoveryLocations: moveError.recoveryLocations
                )
            } catch let recoveryError {
                throw ContainerDirectoryRenameError.directoryStateRecoveryFailed(
                    source: sourceURL,
                    destination: destinationURL,
                    recoveryLocations: moveError.recoveryLocations,
                    moveReason: moveError.reason,
                    recoveryReason: Self.describe(recoveryError)
                )
            }
            throw ContainerDirectoryRenameError.directoryMoveFailed(
                source: sourceURL,
                destination: destinationURL,
                recoveryLocations: moveError.recoveryLocations,
                reason: moveError.reason
            )
        }
        do {
            try save(renamedContainer)
        } catch let saveError {
            do {
                try moveDirectory(from: destinationURL, to: sourceURL)
            } catch let rollbackError as DirectoryMoveFailure {
                do {
                    try recoverSingleManifest(
                        originalContainer: container,
                        renamedContainer: renamedContainer,
                        sourceURL: sourceURL,
                        destinationURL: destinationURL,
                        recoveryLocations: rollbackError.recoveryLocations
                    )
                } catch let recoveryError {
                    throw ContainerDirectoryRenameError.stateRecoveryFailed(
                        recoveryLocations: rollbackError.recoveryLocations,
                        saveReason: Self.describe(saveError),
                        rollbackReason: rollbackError.reason,
                        recoveryReason: Self.describe(recoveryError)
                    )
                }
                throw ContainerDirectoryRenameError.rollbackFailed(
                    source: sourceURL,
                    destination: destinationURL,
                    recoveryLocations: rollbackError.recoveryLocations,
                    saveReason: Self.describe(saveError),
                    rollbackReason: rollbackError.reason
                )
            }

            do {
                try recoverManifest(
                    container,
                    at: sourceURL,
                    relocatingFrom: sourceURL
                )
            } catch let recoveryError {
                throw ContainerDirectoryRenameError.stateRecoveryFailed(
                    recoveryLocations: [sourceURL],
                    saveReason: Self.describe(saveError),
                    rollbackReason: nil,
                    recoveryReason: Self.describe(recoveryError)
                )
            }
            throw saveError
        }
        return renamedContainer
    }

    private func hasContainerManifest(at directoryURL: URL) -> Bool {
        ["switchyard-container.json", "switchyard-bottle.json"].contains { fileName in
            fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent(fileName).path
            )
        }
    }

    private func moveDirectory(from sourceURL: URL, to destinationURL: URL) throws {
        let isCaseOnlyRename = sourceURL.path.caseInsensitiveCompare(destinationURL.path)
            == .orderedSame
        guard isCaseOnlyRename else {
            do {
                try performMoveItem(from: sourceURL, to: destinationURL)
            } catch {
                throw DirectoryMoveFailure(
                    reason: Self.describe(error),
                    recoveryLocations: existingRecoveryLocations(
                        among: [sourceURL, destinationURL]
                    )
                )
            }
            return
        }

        let intermediateURL = rootURL.appendingPathComponent(
            ".switchyard-rename-\(UUID().uuidString).container",
            isDirectory: true
        )
        do {
            try performMoveItem(from: sourceURL, to: intermediateURL)
        } catch {
            throw DirectoryMoveFailure(
                reason: Self.describe(error),
                recoveryLocations: existingRecoveryLocations(
                    among: [sourceURL, intermediateURL, destinationURL]
                )
            )
        }
        do {
            try performMoveItem(from: intermediateURL, to: destinationURL)
        } catch let moveError {
            do {
                try performMoveItem(from: intermediateURL, to: sourceURL)
            } catch let rollbackError {
                throw DirectoryMoveFailure(
                    reason: "\(Self.describe(moveError)) Rollback error: \(Self.describe(rollbackError))",
                    recoveryLocations: existingRecoveryLocations(
                        among: [sourceURL, intermediateURL, destinationURL]
                    )
                )
            }
            throw DirectoryMoveFailure(
                reason: Self.describe(moveError),
                recoveryLocations: existingRecoveryLocations(
                    among: [sourceURL, intermediateURL, destinationURL]
                )
            )
        }
    }

    private func recoverInitialMoveFailure(
        originalContainer: Container,
        renamedContainer: Container,
        sourceURL: URL,
        destinationURL: URL,
        recoveryLocations: [URL]
    ) throws {
        guard recoveryLocations.count == 1,
              let recoveryURL = recoveryLocations.first,
              recoveryURL.standardizedFileURL.path
                != sourceURL.standardizedFileURL.path else {
            return
        }

        if recoveryURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
            try recoverManifest(
                renamedContainer,
                at: recoveryURL,
                relocatingFrom: destinationURL
            )
        } else {
            try recoverManifest(
                originalContainer,
                at: recoveryURL,
                relocatingFrom: sourceURL
            )
        }
    }

    private func recoverSingleManifest(
        originalContainer: Container,
        renamedContainer: Container,
        sourceURL: URL,
        destinationURL: URL,
        recoveryLocations: [URL]
    ) throws {
        guard recoveryLocations.count == 1,
              let recoveryURL = recoveryLocations.first else {
            throw ManifestRecoveryFailure.ambiguousLocations(recoveryLocations)
        }

        if recoveryURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
            try recoverManifest(
                renamedContainer,
                at: recoveryURL,
                relocatingFrom: destinationURL
            )
        } else {
            try recoverManifest(
                originalContainer,
                at: recoveryURL,
                relocatingFrom: sourceURL
            )
        }
    }

    private func recoverManifest(
        _ container: Container,
        at directoryURL: URL,
        relocatingFrom sourceURL: URL
    ) throws {
        let existingLocations = existingRecoveryLocations(among: [directoryURL])
        guard existingLocations.count == 1,
              let existingURL = existingLocations.first else {
            throw ManifestRecoveryFailure.missingDirectory(directoryURL)
        }

        var recoveredContainer = container
        recoveredContainer.path = existingURL.path
        if let executablePath = container.executablePath {
            recoveredContainer.executablePath = ContainerPathPolicy.relocatingPath(
                executablePath,
                from: sourceURL.path,
                to: existingURL.path
            )
        }
        try persistManifest(recoveredContainer)
    }

    private func existingRecoveryLocations(among candidates: [URL]) -> [URL] {
        let candidateNames = Set(candidates.map(\.lastPathComponent))
        if let entries = try? fileManager.contentsOfDirectory(
            at: rootURL.standardizedFileURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            return entries.filter { entry in
                guard candidateNames.contains(entry.lastPathComponent),
                      let values = try? entry.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                      ),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    return false
                }
                return true
            }.sorted { $0.path < $1.path }
        }

        return candidates.filter { candidate in
            guard let values = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.reduce(into: [URL]()) { locations, candidate in
            guard !locations.contains(where: {
                $0.standardizedFileURL.path == candidate.standardizedFileURL.path
            }) else {
                return
            }
            locations.append(candidate)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return (error as NSError).localizedDescription
    }

    private func performMoveItem(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        if let moveItemOverride {
            try moveItemOverride(sourceURL, destinationURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private func persistManifest(_ container: Container) throws {
        if let saveManifestOverride {
            try saveManifestOverride(container)
        } else {
            try ContainerManifestStore(rootURL: rootURL, fileManager: fileManager)
                .save(container)
        }
    }
}

private struct DirectoryMoveFailure: Error {
    var reason: String
    var recoveryLocations: [URL]
}

private enum ManifestRecoveryFailure: LocalizedError {
    case ambiguousLocations([URL])
    case missingDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .ambiguousLocations(let locations):
            "Expected one recoverable container folder, but found \(locations.count)."
        case .missingDirectory(let url):
            "The recoverable container folder is missing: \(url.path)"
        }
    }
}
