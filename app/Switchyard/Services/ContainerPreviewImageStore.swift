import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ContainerPreviewImage: @unchecked Sendable {
    let image: CGImage
    let modifiedAt: Date?

    init(image: CGImage, modifiedAt: Date? = nil) {
        self.image = image
        self.modifiedAt = modifiedAt
    }
}

enum ContainerPreviewImageStoreError: Error, Equatable {
    case containerUnavailable
    case imageEncodingFailed
    case unsafeManagedStorage
}

actor ContainerPreviewImageStore {
    static let shared = ContainerPreviewImageStore()
    static let managedRelativePath = ".switchyard/previews/last-window.jpg"

    private static let metadataDirectoryName = ".switchyard"
    private static let previewsDirectoryName = "previews"
    private static let managedFileName = "last-window.jpg"
    private static let maximumLoadedPixelSize = 1_120

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func save(
        _ preview: ContainerPreviewImage,
        intoContainerAt containerURL: URL
    ) throws -> Date {
        let storageURL = try prepareManagedStorage(in: containerURL)
        let destinationURL = storageURL.appendingPathComponent(
            Self.managedFileName,
            isDirectory: false
        )
        try validateExistingDestination(destinationURL)

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ContainerPreviewImageStoreError.imageEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            preview.image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.82,
                kCGImageDestinationEmbedThumbnail: true,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ContainerPreviewImageStoreError.imageEncodingFailed
        }

        try (data as Data).write(to: destinationURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
        return (try? destinationURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()
    }

    func load(fromContainerAt containerURL: URL) throws -> ContainerPreviewImage? {
        let rootURL = try validatedContainerRoot(containerURL)
        let metadataURL = rootURL.appendingPathComponent(
            Self.metadataDirectoryName,
            isDirectory: true
        )
        guard try validatedExistingManagedDirectory(metadataURL, inside: rootURL) else {
            return nil
        }
        let previewsURL = metadataURL.appendingPathComponent(
            Self.previewsDirectoryName,
            isDirectory: true
        )
        guard try validatedExistingManagedDirectory(previewsURL, inside: rootURL) else {
            return nil
        }

        let imageURL = previewsURL.appendingPathComponent(
            Self.managedFileName,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: imageURL.path) else {
            return nil
        }
        try validateExistingDestination(imageURL)

        guard let source = CGImageSourceCreateWithURL(
            imageURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumLoadedPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        let modifiedAt = try? imageURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        return ContainerPreviewImage(image: image, modifiedAt: modifiedAt)
    }

    private func prepareManagedStorage(in containerURL: URL) throws -> URL {
        let rootURL = try validatedContainerRoot(containerURL)
        let metadataURL = rootURL.appendingPathComponent(
            Self.metadataDirectoryName,
            isDirectory: true
        )
        try ensureManagedDirectory(metadataURL, inside: rootURL)

        let previewsURL = metadataURL.appendingPathComponent(
            Self.previewsDirectoryName,
            isDirectory: true
        )
        try ensureManagedDirectory(previewsURL, inside: rootURL)
        return previewsURL
    }

    private func validatedContainerRoot(_ containerURL: URL) throws -> URL {
        let standardizedURL = containerURL.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            throw ContainerPreviewImageStoreError.containerUnavailable
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
                throw ContainerPreviewImageStoreError.unsafeManagedStorage
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
                throw ContainerPreviewImageStoreError.unsafeManagedStorage
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
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              isDescendant(
                directoryURL.resolvingSymlinksInPath(),
                of: rootURL
              ) else {
            throw ContainerPreviewImageStoreError.unsafeManagedStorage
        }
        return true
    }

    private func validateExistingDestination(_ destinationURL: URL) throws {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return
        }
        let values = try destinationURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ContainerPreviewImageStoreError.unsafeManagedStorage
        }
    }

    private func isDescendant(_ candidateURL: URL, of rootURL: URL) -> Bool {
        candidateURL.path == rootURL.path
            || candidateURL.path.hasPrefix(rootURL.path + "/")
    }
}
