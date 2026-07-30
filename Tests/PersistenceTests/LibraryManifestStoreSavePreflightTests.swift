import AppCore
import Foundation
import Persistence
import Testing

@Test
func libraryManifestSavePreflightRejectsDuplicateIDsBeforeWriting() throws {
    let root = preflightTemporaryLibraryURL()
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
    let first = Container(
        id: duplicateID,
        name: "First",
        path: firstURL.path
    )
    let second = Container(
        id: duplicateID,
        name: "Second",
        path: secondURL.path
    )

    #expect(
        throws: PersistenceError.duplicateContainerID(
            duplicateID,
            [firstURL, secondURL].map {
                $0.appendingPathComponent("switchyard-container.json")
            }
        )
    ) {
        try LibraryManifestStore(rootURL: root).save(
            SwitchyardContainerSnapshot(containers: [first, second])
        )
    }
    #expect(!FileManager.default.fileExists(atPath: firstURL.path))
    #expect(!FileManager.default.fileExists(atPath: secondURL.path))
}

@Test
func libraryManifestSavePreflightRejectsDuplicateNormalizedPaths() throws {
    let root = preflightTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: root) }

    let sharedURL = root.appendingPathComponent(
        "Shared.container",
        isDirectory: true
    )
    let first = Container(name: "First", path: sharedURL.path)
    let second = Container(
        name: "Second",
        path: root.appendingPathComponent(
            "Unused/../Shared.container",
            isDirectory: true
        ).path
    )
    let expectedIDs = [first.id, second.id].sorted {
        $0.uuidString < $1.uuidString
    }

    #expect(
        throws: PersistenceError.duplicateContainerPath(
            sharedURL.standardizedFileURL,
            expectedIDs
        )
    ) {
        try LibraryManifestStore(rootURL: root).save(
            SwitchyardContainerSnapshot(containers: [first, second])
        )
    }
    #expect(!FileManager.default.fileExists(atPath: sharedURL.path))
}

@Test
func libraryManifestSavePreflightRejectsCaseAliasesOnInsensitiveVolumes() throws {
    let root = preflightTemporaryLibraryURL()
    defer { try? FileManager.default.removeItem(at: root) }

    let volumeValues = try root.deletingLastPathComponent().resourceValues(
        forKeys: [.volumeSupportsCaseSensitiveNamesKey]
    )
    guard volumeValues.volumeSupportsCaseSensitiveNames == false else {
        return
    }

    let uppercaseURL = root.appendingPathComponent(
        "Games.container",
        isDirectory: true
    )
    let lowercaseURL = root.appendingPathComponent(
        "games.container",
        isDirectory: true
    )
    let uppercase = Container(name: "Uppercase", path: uppercaseURL.path)
    let lowercase = Container(name: "Lowercase", path: lowercaseURL.path)
    let expectedIDs = [uppercase.id, lowercase.id].sorted {
        $0.uuidString < $1.uuidString
    }

    #expect(
        throws: PersistenceError.duplicateContainerPath(
            uppercaseURL,
            expectedIDs
        )
    ) {
        try LibraryManifestStore(rootURL: root).save(
            SwitchyardContainerSnapshot(
                containers: [uppercase, lowercase]
            )
        )
    }
    #expect(!FileManager.default.fileExists(atPath: uppercaseURL.path))
}

@Test
func libraryManifestSavePreflightLeavesEarlierManifestUntouchedWhenLaterManifestIsUnsafe() throws {
    let testRoot = preflightTemporaryLibraryURL()
    let root = testRoot.appendingPathComponent("Library", isDirectory: true)
    let outsideManifestURL = testRoot.appendingPathComponent(
        "outside-manifest.json"
    )
    defer { try? FileManager.default.removeItem(at: testRoot) }

    let firstURL = root.appendingPathComponent(
        "First.container",
        isDirectory: true
    )
    let secondURL = root.appendingPathComponent(
        "Second.container",
        isDirectory: true
    )
    let store = LibraryManifestStore(rootURL: root)
    let first = Container(name: "Original", path: firstURL.path)
    try store.save(SwitchyardContainerSnapshot(containers: [first]))
    let firstManifestURL = firstURL.appendingPathComponent(
        "switchyard-container.json"
    )
    let originalFirstBytes = try Data(contentsOf: firstManifestURL)
    let originalLibraryBytes = try Data(contentsOf: store.manifestURL)

    try FileManager.default.createDirectory(
        at: secondURL,
        withIntermediateDirectories: true
    )
    try Data("outside".utf8).write(to: outsideManifestURL)
    let unsafeManifestURL = secondURL.appendingPathComponent(
        "switchyard-container.json"
    )
    try FileManager.default.createSymbolicLink(
        at: unsafeManifestURL,
        withDestinationURL: outsideManifestURL
    )

    var updatedFirst = first
    updatedFirst.name = "Updated"
    let second = Container(name: "Second", path: secondURL.path)

    #expect(throws: PersistenceError.unsafeManifest(unsafeManifestURL)) {
        try store.save(
            SwitchyardContainerSnapshot(
                containers: [updatedFirst, second]
            )
        )
    }
    #expect(try Data(contentsOf: firstManifestURL) == originalFirstBytes)
    #expect(try Data(contentsOf: store.manifestURL) == originalLibraryBytes)
}

private func preflightTemporaryLibraryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}
