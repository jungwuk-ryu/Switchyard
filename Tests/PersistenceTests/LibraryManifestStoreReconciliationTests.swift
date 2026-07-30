import AppCore
import Foundation
import Persistence
import Testing

@Test
func librarySnapshotPrefersPortableManifestOverStaleIndex() throws {
    let root = temporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: root) }

    let containerURL = root.appendingPathComponent(
        "Games.container",
        isDirectory: true
    )
    let oldContainer = Container(
        name: "Old Name",
        path: containerURL.path
    )
    let store = LibraryManifestStore(rootURL: root)
    try store.save(SwitchyardContainerSnapshot(containers: [oldContainer]))

    var updatedContainer = oldContainer
    updatedContainer.name = "New Name"
    try JSONEncoder.switchyard.encode(updatedContainer).write(
        to: containerURL.appendingPathComponent("switchyard-container.json"),
        options: [.atomic]
    )

    let loaded = try #require(try store.loadSnapshot())

    #expect(loaded.containers.map(\.id) == [oldContainer.id])
    #expect(loaded.containers.map(\.name) == ["New Name"])
}

@Test
func librarySnapshotRebindsPortableManifestAfterLibraryMoves() throws {
    let testRoot = temporaryLibraryURL()
    let originalRoot = testRoot.appendingPathComponent(
        "Original",
        isDirectory: true
    )
    let movedRoot = testRoot.appendingPathComponent(
        "Moved",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: testRoot) }

    let originalContainerURL = originalRoot.appendingPathComponent(
        "Games.container",
        isDirectory: true
    )
    let container = Container(
        name: "Games",
        path: originalContainerURL.path
    )
    try LibraryManifestStore(rootURL: originalRoot).save(
        SwitchyardContainerSnapshot(containers: [container])
    )
    try FileManager.default.moveItem(at: originalRoot, to: movedRoot)

    let loaded = try #require(
        try LibraryManifestStore(rootURL: movedRoot).loadSnapshot()
    )

    #expect(loaded.containers.map(\.id) == [container.id])
    #expect(
        loaded.containers.map(\.path)
            == [
                movedRoot.appendingPathComponent(
                    "Games.container",
                    isDirectory: true
                ).path
            ]
    )
}

@Test
func librarySnapshotDoesNotResurrectMissingIndexedFolderOnSave() throws {
    let root = temporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: root) }

    let containerURL = root.appendingPathComponent(
        "Removed.container",
        isDirectory: true
    )
    let store = LibraryManifestStore(rootURL: root)
    try store.save(
        SwitchyardContainerSnapshot(
            containers: [
                Container(name: "Removed", path: containerURL.path)
            ]
        )
    )
    try FileManager.default.removeItem(at: containerURL)

    let loaded = try #require(try store.loadSnapshot())
    #expect(loaded.containers.isEmpty)

    try store.save(loaded)
    #expect(!FileManager.default.fileExists(atPath: containerURL.path))
}

@Test
func librarySnapshotDiscoversPortableManifestMissingFromIndex() throws {
    let root = temporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: root) }

    let indexed = Container(
        name: "Indexed",
        path: root.appendingPathComponent(
            "Indexed.container",
            isDirectory: true
        ).path
    )
    let copied = Container(
        name: "Copied",
        path: root.appendingPathComponent(
            "Copied.container",
            isDirectory: true
        ).path
    )
    let store = LibraryManifestStore(rootURL: root)
    try store.save(SwitchyardContainerSnapshot(containers: [indexed]))
    try ContainerManifestStore(rootURL: root).save(copied)

    let loaded = try #require(try store.loadSnapshot())

    #expect(loaded.containers.map(\.id) == [copied.id, indexed.id])
    #expect(loaded.containers.map(\.name) == ["Copied", "Indexed"])
}

@Test
func librarySnapshotIgnoresOutsideAndNestedIndexedPaths() throws {
    let testRoot = temporaryLibraryURL()
    let libraryRoot = testRoot.appendingPathComponent(
        "Library",
        isDirectory: true
    )
    let outsideContainerURL = testRoot.appendingPathComponent(
        "Outside.container",
        isDirectory: true
    )
    let nestedContainerURL = libraryRoot
        .appendingPathComponent("Group", isDirectory: true)
        .appendingPathComponent("Nested.container", isDirectory: true)
    let validContainer = Container(
        name: "Valid",
        path: libraryRoot.appendingPathComponent(
            "Valid.container",
            isDirectory: true
        ).path
    )
    defer { try? FileManager.default.removeItem(at: testRoot) }

    try ContainerManifestStore(rootURL: libraryRoot).save(validContainer)
    let outsideContainer = Container(
        name: "Outside",
        path: outsideContainerURL.path
    )
    let nestedContainer = Container(
        name: "Nested",
        path: nestedContainerURL.path
    )
    try writePortableManifest(
        outsideContainer,
        to: outsideContainerURL
    )
    try writePortableManifest(
        nestedContainer,
        to: nestedContainerURL
    )
    try JSONEncoder.switchyard.encode(
        SwitchyardContainerSnapshot(
            containers: [outsideContainer, nestedContainer]
        )
    ).write(
        to: libraryRoot.appendingPathComponent("switchyard-library.json"),
        options: [.atomic]
    )

    let loaded = try #require(
        try LibraryManifestStore(rootURL: libraryRoot).loadSnapshot()
    )

    #expect(loaded.containers.map(\.id) == [validContainer.id])
    #expect(loaded.containers.map(\.path) == [validContainer.path])
}

@Test
func librarySnapshotFailsClosedForDuplicatePortableManifestIDs() throws {
    let root = temporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: root) }

    let duplicateID = UUID()
    let firstURL = root.appendingPathComponent(
        "First.container",
        isDirectory: true
    )
    let secondURL = root.appendingPathComponent(
        "Second.container",
        isDirectory: true
    )
    try ContainerManifestStore(rootURL: root).save(
        Container(id: duplicateID, name: "First", path: firstURL.path)
    )
    try ContainerManifestStore(rootURL: root).save(
        Container(id: duplicateID, name: "Second", path: secondURL.path)
    )

    let expectedManifestURLs = [firstURL, secondURL].map {
        $0.appendingPathComponent("switchyard-container.json")
    }
    #expect(
        throws: PersistenceError.duplicateContainerID(
            duplicateID,
            expectedManifestURLs
        )
    ) {
        _ = try LibraryManifestStore(rootURL: root).loadSnapshot()
    }
}

private func temporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func writePortableManifest(
    _ container: Container,
    to directory: URL
) throws {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try JSONEncoder.switchyard.encode(container).write(
        to: directory.appendingPathComponent("switchyard-container.json"),
        options: [.atomic]
    )
}
