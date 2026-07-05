import AppCore
import Foundation
import Persistence
import Testing

@Test func librarySnapshotRoundTripsContainers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = Container(
        name: "Toolbox",
        path: root.appendingPathComponent("Toolbox.container", isDirectory: true).path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: "C:\\Tools\\Toolbox.exe",
        status: .ready
    )
    let snapshot = SwitchyardContainerSnapshot(containers: [container])
    let store = LibraryManifestStore(rootURL: root)

    try store.save(snapshot)
    let loaded = try #require(try store.loadSnapshot())
    let manifest = try String(contentsOf: store.manifestURL, encoding: .utf8)

    #expect(loaded.containers.count == 1)
    #expect(loaded.containers.first?.id == container.id)
    #expect(loaded.containers.first?.name == "Toolbox")
    #expect(loaded.containers.first?.executablePath == "C:\\Tools\\Toolbox.exe")
    #expect(loaded.containers.first?.status == .ready)
    #expect(manifest.contains("\"containers\""))
    #expect(!manifest.contains("\"bottles\""))
    #expect(!manifest.contains("\"launchers\""))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Toolbox.container/switchyard-container.json").path))
}

@Test func containerManifestStoreReadsLegacyBottleManifest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let containerID = UUID()
    let legacyContainerURL = root.appendingPathComponent("Toolbox.bottle", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyContainerURL, withIntermediateDirectories: true)

    let legacyManifest = """
    {
      "id" : "\(containerID.uuidString)",
      "name" : "Toolbox",
      "path" : "/tmp/OriginalToolbox.bottle",
      "wineBuildID" : "wine-a",
      "patchsetID" : "patch-a",
      "schemaVersion" : 1,
      "lastModified" : "2026-07-05T00:00:00Z"
    }
    """
    try Data(legacyManifest.utf8).write(to: legacyContainerURL.appendingPathComponent("switchyard-bottle.json"))

    let loaded = try ContainerManifestStore(rootURL: root).loadContainers()

    #expect(loaded.count == 1)
    #expect(loaded.first?.id == containerID)
    let loadedPath = try #require(loaded.first?.path)
    #expect(loadedPath.hasSuffix("/Toolbox.bottle"))
    #expect(!loadedPath.contains("OriginalToolbox.bottle"))
    #expect(FileManager.default.fileExists(atPath: loadedPath))
    #expect(loaded.first?.environmentOverrides == [:])
}

@Test func librarySnapshotReadsLegacyBottleKeysAndMigratesRunTargetFields() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let containerID = UUID()
    let legacyRunTargetID = UUID()
    let legacyContainerURL = root.appendingPathComponent("Toolbox.bottle", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let legacySnapshot = """
    {
      "bottles" : [
        {
          "id" : "\(containerID.uuidString)",
          "name" : "Toolbox",
          "path" : "\(legacyContainerURL.path)",
          "wineBuildID" : "wine-a",
          "patchsetID" : "patch-a",
          "schemaVersion" : 1,
          "lastModified" : "2026-07-05T00:00:00Z"
        }
      ],
      "launchers" : [
        {
          "id" : "\(legacyRunTargetID.uuidString)",
          "name" : "Toolbox",
          "kind" : "steam",
          "bottleID" : "\(containerID.uuidString)",
          "executablePath" : "C:\\\\Tools\\\\Toolbox.exe",
          "lastRun" : "2026-07-05T01:02:03Z",
          "status" : "ready"
        }
      ]
    }
    """
    try Data(legacySnapshot.utf8).write(to: root.appendingPathComponent("switchyard-library.json"))

    let loaded = try #require(try LibraryManifestStore(rootURL: root).loadSnapshot())

    #expect(loaded.containers.first?.id == containerID)
    #expect(loaded.containers.first?.executablePath == "C:\\Tools\\Toolbox.exe")
    #expect(loaded.containers.first?.lastRun != nil)
    #expect(loaded.containers.first?.status == .ready)
}
