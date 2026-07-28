import Foundation
import ImageIO

enum ContainerBackgroundImageStoreError: Error, Equatable, LocalizedError {
    case containerUnavailable
    case sourceIsNotARegularFile
    case sourceTooLarge(maximumByteCount: Int)
    case invalidImage
    case imageDimensionsTooLarge
    case unsafeManagedStorage
    case unmanagedRelativePath

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            "The container is unavailable."
        case .sourceIsNotARegularFile:
            "Choose an image file."
        case let .sourceTooLarge(maximumByteCount):
            "The image must be smaller than \(ByteCountFormatter.string(fromByteCount: Int64(maximumByteCount), countStyle: .file))."
        case .invalidImage:
            "The selected file could not be decoded as an image."
        case .imageDimensionsTooLarge:
            "The image dimensions are too large."
        case .unsafeManagedStorage:
            "The container background folder is not safe to use."
        case .unmanagedRelativePath:
            "Only a background managed by Switchyard can be removed."
        }
    }
}

/// Owns imported session backgrounds inside a container so manifests never retain
/// machine-specific paths to a user's original file.
actor ContainerBackgroundImageStore {
    static let managedRelativePath = ".switchyard/appearance/session-background"
    static let maximumSourceByteCount = 32 * 1_024 * 1_024

    private static let maximumImageCount = 256
    private static let maximumDimension = 8_192
    private static let maximumPixelCount = 50_000_000
    private static let maximumAggregatePixelCount = 100_000_000

    private let fileManager: FileManager
    private let sourceByteLimit: Int

    init(
        fileManager: FileManager = .default,
        sourceByteLimit: Int = ContainerBackgroundImageStore.maximumSourceByteCount
    ) {
        self.fileManager = fileManager
        self.sourceByteLimit = min(max(1, sourceByteLimit), Int.max - 1)
    }

    /// Copies a validated image into the container and atomically replaces the
    /// previous managed background. The returned value is portable across a
    /// container rename or move.
    func importImage(
        from sourceURL: URL,
        intoContainerAt containerURL: URL
    ) throws -> String {
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceValues = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
        ])
        guard sourceValues.isRegularFile == true else {
            throw ContainerBackgroundImageStoreError.sourceIsNotARegularFile
        }
        if let fileSize = sourceValues.fileSize, fileSize > sourceByteLimit {
            throw ContainerBackgroundImageStoreError.sourceTooLarge(
                maximumByteCount: sourceByteLimit
            )
        }

        let data = try readBoundedData(from: sourceURL)
        try validateImage(data)

        let storage = try prepareManagedStorage(in: containerURL)
        let destinationURL = storage.appendingPathComponent(
            Self.managedFileName,
            isDirectory: false
        )
        try validateExistingDestination(destinationURL)

        // Foundation stages `.atomic` writes beside the destination before a
        // rename, so readers see either the previous complete image or the new one.
        try data.write(to: destinationURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        return Self.managedRelativePath
    }

    /// Deletes only the single path owned by this service. A caller cannot use a
    /// manifest value to remove another file from the container or from the host.
    @discardableResult
    func removeManagedImage(
        relativePath: String?,
        fromContainerAt containerURL: URL
    ) throws -> Bool {
        guard let relativePath else { return false }
        guard relativePath == Self.managedRelativePath else {
            throw ContainerBackgroundImageStoreError.unmanagedRelativePath
        }

        let rootURL = try validatedContainerRoot(containerURL)
        let appearanceURL = rootURL
            .appendingPathComponent(Self.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.appearanceDirectoryName, isDirectory: true)
        guard try validatedExistingManagedDirectory(
            appearanceURL,
            inside: rootURL
        ) else {
            return false
        }

        let imageURL = appearanceURL.appendingPathComponent(
            Self.managedFileName,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: imageURL.path) else {
            return false
        }
        try validateExistingDestination(imageURL)
        try fileManager.removeItem(at: imageURL)
        return true
    }

    private static let metadataDirectoryName = ".switchyard"
    private static let appearanceDirectoryName = "appearance"
    private static let managedFileName = "session-background"

    private func readBoundedData(from sourceURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(min(sourceByteLimit, 1_048_576))
        let readLimit = sourceByteLimit + 1
        while data.count < readLimit {
            let requestedByteCount = min(1_048_576, readLimit - data.count)
            guard let chunk = try handle.read(upToCount: requestedByteCount),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= sourceByteLimit else {
            throw ContainerBackgroundImageStoreError.sourceTooLarge(
                maximumByteCount: sourceByteLimit
            )
        }
        return data
    }

    private func validateImage(_ data: Data) throws {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ContainerBackgroundImageStoreError.invalidImage
        }

        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0, imageCount <= Self.maximumImageCount else {
            throw ContainerBackgroundImageStoreError.invalidImage
        }

        var aggregatePixelCount = 0
        for index in 0..<imageCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any],
                let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else {
                throw ContainerBackgroundImageStoreError.invalidImage
            }

            let width = widthNumber.intValue
            let height = heightNumber.intValue
            let (pixelCount, didOverflow) = width.multipliedReportingOverflow(by: height)
            guard !didOverflow,
                  width > 0,
                  height > 0,
                  width <= Self.maximumDimension,
                  height <= Self.maximumDimension,
                  pixelCount <= Self.maximumPixelCount else {
                throw ContainerBackgroundImageStoreError.imageDimensionsTooLarge
            }

            let (nextAggregatePixelCount, aggregateDidOverflow) =
                aggregatePixelCount.addingReportingOverflow(pixelCount)
            guard !aggregateDidOverflow,
                  nextAggregatePixelCount <= Self.maximumAggregatePixelCount else {
                throw ContainerBackgroundImageStoreError.imageDimensionsTooLarge
            }
            aggregatePixelCount = nextAggregatePixelCount
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) != nil else {
            throw ContainerBackgroundImageStoreError.invalidImage
        }
    }

    private func prepareManagedStorage(in containerURL: URL) throws -> URL {
        let rootURL = try validatedContainerRoot(containerURL)
        let metadataURL = rootURL.appendingPathComponent(
            Self.metadataDirectoryName,
            isDirectory: true
        )
        try ensureManagedDirectory(metadataURL, inside: rootURL)

        let appearanceURL = metadataURL.appendingPathComponent(
            Self.appearanceDirectoryName,
            isDirectory: true
        )
        try ensureManagedDirectory(appearanceURL, inside: rootURL)
        return appearanceURL
    }

    private func validatedContainerRoot(_ containerURL: URL) throws -> URL {
        let standardizedURL = containerURL.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            throw ContainerBackgroundImageStoreError.containerUnavailable
        }
        return standardizedURL.resolvingSymlinksInPath()
    }

    private func ensureManagedDirectory(
        _ directoryURL: URL,
        inside rootURL: URL
    ) throws {
        if fileManager.fileExists(atPath: directoryURL.path) {
            guard try validatedExistingManagedDirectory(
                directoryURL,
                inside: rootURL
            ) else {
                throw ContainerBackgroundImageStoreError.unsafeManagedStorage
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            guard try validatedExistingManagedDirectory(
                directoryURL,
                inside: rootURL
            ) else {
                throw ContainerBackgroundImageStoreError.unsafeManagedStorage
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func validatedExistingManagedDirectory(
        _ directoryURL: URL,
        inside rootURL: URL
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return false
        }
        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ContainerBackgroundImageStoreError.unsafeManagedStorage
        }
        guard isDescendant(
            directoryURL.resolvingSymlinksInPath(),
            of: rootURL
        ) else {
            throw ContainerBackgroundImageStoreError.unsafeManagedStorage
        }
        return true
    }

    private func validateExistingDestination(_ destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: destinationURL.path) else { return }
        let values = try destinationURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ContainerBackgroundImageStoreError.unsafeManagedStorage
        }
    }

    private func isDescendant(_ candidateURL: URL, of rootURL: URL) -> Bool {
        let candidatePath = candidateURL.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
