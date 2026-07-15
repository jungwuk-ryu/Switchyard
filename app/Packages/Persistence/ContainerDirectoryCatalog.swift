import AppCore
import Foundation

public enum ContainerDirectoryCatalogError: Error, Equatable, LocalizedError, Sendable {
    case outsideContainer
    case notDirectory

    public var errorDescription: String? {
        switch self {
        case .outsideContainer:
            "Switchyard will not browse a path outside this container."
        case .notDirectory:
            "The selected path is not a folder."
        }
    }
}

public struct ContainerFileEntry: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isNavigable: Bool
    public let byteCount: Int?
    public let modifiedAt: Date?

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isNavigable: Bool,
        byteCount: Int?,
        modifiedAt: Date?
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isNavigable = isNavigable
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct ContainerDirectoryCatalog {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func defaultDirectory(for container: Container) -> URL {
        let rootURL = containerRootURL(for: container)
        let driveCURL = rootURL.appendingPathComponent("drive_c", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: driveCURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return driveCURL
        }
        return rootURL
    }

    public func contains(_ url: URL, in container: Container) -> Bool {
        isContained(resolvedURL(url), in: resolvedURL(containerRootURL(for: container)))
    }

    public func contents(of directoryURL: URL, in container: Container) throws -> [ContainerFileEntry] {
        let rootURL = resolvedURL(containerRootURL(for: container))
        let resolvedDirectoryURL = resolvedURL(directoryURL)
        guard isContained(resolvedDirectoryURL, in: rootURL) else {
            throw ContainerDirectoryCatalogError.outsideContainer
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ContainerDirectoryCatalogError.notDirectory
        }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let entryIsDirectory = values.isDirectory == true
            let navigable = entryIsDirectory && isContained(resolvedURL(url), in: rootURL)
            return ContainerFileEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: entryIsDirectory,
                isNavigable: navigable,
                byteCount: entryIsDirectory ? nil : values.fileSize,
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func containerRootURL(for container: Container) -> URL {
        URL(fileURLWithPath: container.path, isDirectory: true).standardizedFileURL
    }

    private func resolvedURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isContained(_ candidateURL: URL, in rootURL: URL) -> Bool {
        let candidatePath = candidateURL.path
        let rootPath = rootURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
