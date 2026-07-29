import CoreGraphics
import Foundation
import Testing
@testable import Switchyard

@Test func containerPreviewImageStoreSavesAndLoadsManagedPreview() async throws {
    let fixture = try ContainerPreviewStoreFixture()
    defer { fixture.remove() }

    let store = ContainerPreviewImageStore()
    let image = try fixture.makeImage(width: 160, height: 90)
    _ = try await store.save(
        ContainerPreviewImage(image: image),
        intoContainerAt: fixture.containerURL
    )

    let managedURL = fixture.containerURL.appendingPathComponent(
        ContainerPreviewImageStore.managedRelativePath
    )
    #expect(FileManager.default.fileExists(atPath: managedURL.path))

    let loadedPreview = try await store.load(
        fromContainerAt: fixture.containerURL
    )
    #expect(loadedPreview != nil)
    #expect(loadedPreview?.image.width == 160)
    #expect(loadedPreview?.image.height == 90)
    #expect(loadedPreview?.modifiedAt != nil)
}

@Test func containerPreviewImageStoreRejectsManagedStorageSymlink() async throws {
    let fixture = try ContainerPreviewStoreFixture()
    defer { fixture.remove() }

    let externalURL = fixture.rootURL.appendingPathComponent(
        "external",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: externalURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: fixture.containerURL.appendingPathComponent(".switchyard"),
        withDestinationURL: externalURL
    )

    let store = ContainerPreviewImageStore()
    let image = try fixture.makeImage(width: 32, height: 18)
    do {
        _ = try await store.save(
            ContainerPreviewImage(image: image),
            intoContainerAt: fixture.containerURL
        )
        Issue.record("Managed preview storage must not traverse a symbolic link.")
    } catch {
        #expect(
            error as? ContainerPreviewImageStoreError
                == .unsafeManagedStorage
        )
    }
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: externalURL.path)
            .isEmpty
    )
}

private struct ContainerPreviewStoreFixture {
    let rootURL: URL
    let containerURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        containerURL = rootURL.appendingPathComponent(
            "Test.container",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
    }

    func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ContainerPreviewStoreFixtureError.contextUnavailable
        }
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [0.1, 0.45, 0.9, 1]
            )!
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ContainerPreviewStoreFixtureError.imageUnavailable
        }
        return image
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private enum ContainerPreviewStoreFixtureError: Error {
    case contextUnavailable
    case imageUnavailable
}
