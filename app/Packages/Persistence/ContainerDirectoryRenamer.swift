import AppCore
import Foundation

public enum ContainerDirectoryRenameError: LocalizedError {
    case emptyName
    case sourceOutsideLibrary(URL)
    case sourceMissing(URL)
    case sourceHasNoManifest(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            "Container names cannot be empty."
        case .sourceOutsideLibrary(let url):
            "The container folder is outside the active Switchyard library: \(url.path)"
        case .sourceMissing(let url):
            "The container folder is missing: \(url.path)"
        case .sourceHasNoManifest(let url):
            "The container folder has no Switchyard manifest: \(url.path)"
        }
    }
}

public struct ContainerDirectoryRenamer {
    public var rootURL: URL
    public var fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
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
            } catch {
                try? ContainerManifestStore(rootURL: libraryURL, fileManager: fileManager)
                    .save(container)
                throw error
            }
            return renamedContainer
        }

        try moveDirectory(from: sourceURL, to: destinationURL)
        do {
            try save(renamedContainer)
        } catch {
            try? moveDirectory(from: destinationURL, to: sourceURL)
            try? ContainerManifestStore(rootURL: libraryURL, fileManager: fileManager)
                .save(container)
            throw error
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
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return
        }

        let intermediateURL = rootURL.appendingPathComponent(
            ".switchyard-rename-\(UUID().uuidString).container",
            isDirectory: true
        )
        try fileManager.moveItem(at: sourceURL, to: intermediateURL)
        do {
            try fileManager.moveItem(at: intermediateURL, to: destinationURL)
        } catch {
            try? fileManager.moveItem(at: intermediateURL, to: sourceURL)
            throw error
        }
    }
}
