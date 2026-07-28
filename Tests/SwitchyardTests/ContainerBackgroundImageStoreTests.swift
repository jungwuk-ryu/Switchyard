import Foundation
import Testing
@testable import Switchyard

@Test func containerBackgroundImageStoreImportsAndAtomicallyReplacesManagedImage() async throws {
    let fixture = try BackgroundImageStoreFixture()
    defer { fixture.remove() }

    let firstSource = fixture.rootURL.appendingPathComponent("first.png")
    let secondSource = fixture.rootURL.appendingPathComponent("second.png")
    try fixture.validPNG.write(to: firstSource)
    try fixture.validPNG.write(to: secondSource)

    let store = ContainerBackgroundImageStore()
    let relativePath = try await store.importImage(
        from: firstSource,
        intoContainerAt: fixture.containerURL
    )
    #expect(relativePath == ContainerBackgroundImageStore.managedRelativePath)

    let managedURL = fixture.containerURL.appendingPathComponent(relativePath)
    #expect(try Data(contentsOf: managedURL) == fixture.validPNG)

    try Data("not an image".utf8).write(to: secondSource)
    do {
        _ = try await store.importImage(
            from: secondSource,
            intoContainerAt: fixture.containerURL
        )
        Issue.record("An invalid replacement should fail.")
    } catch {
        #expect(error as? ContainerBackgroundImageStoreError == .invalidImage)
    }
    #expect(try Data(contentsOf: managedURL) == fixture.validPNG)
}

@Test func containerBackgroundImageStoreRejectsSourceLargerThanItsReadLimit() async throws {
    let fixture = try BackgroundImageStoreFixture()
    defer { fixture.remove() }

    let sourceURL = fixture.rootURL.appendingPathComponent("large.png")
    try (fixture.validPNG + Data(repeating: 0, count: 256)).write(to: sourceURL)

    let store = ContainerBackgroundImageStore(sourceByteLimit: fixture.validPNG.count)
    do {
        _ = try await store.importImage(
            from: sourceURL,
            intoContainerAt: fixture.containerURL
        )
        Issue.record("An oversized source should fail before decoding.")
    } catch {
        #expect(
            error as? ContainerBackgroundImageStoreError
                == .sourceTooLarge(maximumByteCount: fixture.validPNG.count)
        )
    }
}

@Test func containerBackgroundImageStoreNeverRemovesAnUnmanagedPath() async throws {
    let fixture = try BackgroundImageStoreFixture()
    defer { fixture.remove() }

    let sourceURL = fixture.rootURL.appendingPathComponent("background.png")
    try fixture.validPNG.write(to: sourceURL)
    let unrelatedURL = fixture.containerURL.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: unrelatedURL)

    let store = ContainerBackgroundImageStore()
    let relativePath = try await store.importImage(
        from: sourceURL,
        intoContainerAt: fixture.containerURL
    )

    do {
        _ = try await store.removeManagedImage(
            relativePath: "keep.txt",
            fromContainerAt: fixture.containerURL
        )
        Issue.record("An unmanaged relative path should be rejected.")
    } catch {
        #expect(error as? ContainerBackgroundImageStoreError == .unmanagedRelativePath)
    }
    #expect(try String(contentsOf: unrelatedURL, encoding: .utf8) == "keep")

    #expect(
        try await store.removeManagedImage(
            relativePath: relativePath,
            fromContainerAt: fixture.containerURL
        )
    )
    #expect(!FileManager.default.fileExists(
        atPath: fixture.containerURL.appendingPathComponent(relativePath).path
    ))
    #expect(FileManager.default.fileExists(atPath: unrelatedURL.path))
}

@Test func containerBackgroundImageStoreRejectsAStorageSymlink() async throws {
    let fixture = try BackgroundImageStoreFixture()
    defer { fixture.remove() }

    let sourceURL = fixture.rootURL.appendingPathComponent("background.png")
    try fixture.validPNG.write(to: sourceURL)
    let externalURL = fixture.rootURL.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
    let metadataURL = fixture.containerURL.appendingPathComponent(".switchyard")
    try FileManager.default.createSymbolicLink(
        at: metadataURL,
        withDestinationURL: externalURL
    )

    let store = ContainerBackgroundImageStore()
    do {
        _ = try await store.importImage(
            from: sourceURL,
            intoContainerAt: fixture.containerURL
        )
        Issue.record("Managed storage must not traverse a symbolic link.")
    } catch {
        #expect(error as? ContainerBackgroundImageStoreError == .unsafeManagedStorage)
    }
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: externalURL.path).isEmpty
    )
}

private struct BackgroundImageStoreFixture {
    let rootURL: URL
    let containerURL: URL

    var validPNG: Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZsZQAAAAASUVORK5CYII="
        )!
    }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        containerURL = rootURL.appendingPathComponent("Test.container", isDirectory: true)
        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
