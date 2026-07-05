import AppCore
import Foundation
import Persistence
import Testing

@Test func librarySnapshotRoundTripsContainersAndLaunchers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = Container(name: "Steam", path: root.appendingPathComponent("Steam.container", isDirectory: true).path, wineBuildID: "wine-a", patchsetID: "patch-a")
    let launcher = Launcher(name: "Steam", kind: .steam, containerID: container.id)
    let snapshot = SwitchyardContainerSnapshot(containers: [container], launchers: [launcher])
    let store = LibraryManifestStore(rootURL: root)

    try store.save(snapshot)
    let loaded = try #require(try store.loadSnapshot())
    let manifest = try String(contentsOf: store.manifestURL, encoding: .utf8)

    #expect(loaded.containers.count == 1)
    #expect(loaded.launchers.count == 1)
    #expect(loaded.containers.first?.id == container.id)
    #expect(loaded.containers.first?.name == "Steam")
    #expect(loaded.launchers.first?.id == launcher.id)
    #expect(loaded.launchers.first?.containerID == container.id)
    #expect(manifest.contains("\"containers\""))
    #expect(!manifest.contains("\"bottles\""))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Steam.container/switchyard-container.json").path))
}

@Test func containerManifestStoreReadsLegacyBottleManifest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let containerID = UUID()
    let legacyContainerURL = root.appendingPathComponent("Steam.bottle", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyContainerURL, withIntermediateDirectories: true)

    let legacyManifest = """
    {
      "id" : "\(containerID.uuidString)",
      "name" : "Steam",
      "path" : "/tmp/OriginalSteam.bottle",
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
    #expect(loadedPath.hasSuffix("/Steam.bottle"))
    #expect(!loadedPath.contains("OriginalSteam.bottle"))
    #expect(FileManager.default.fileExists(atPath: loadedPath))
    #expect(loaded.first?.environmentOverrides == [:])
}

@Test func librarySnapshotReadsLegacyBottleKeysAndLauncherContainerID() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let containerID = UUID()
    let launcherID = UUID()
    let legacyContainerURL = root.appendingPathComponent("Steam.bottle", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let legacySnapshot = """
    {
      "bottles" : [
        {
          "id" : "\(containerID.uuidString)",
          "name" : "Steam",
          "path" : "\(legacyContainerURL.path)",
          "wineBuildID" : "wine-a",
          "patchsetID" : "patch-a",
          "schemaVersion" : 1,
          "lastModified" : "2026-07-05T00:00:00Z"
        }
      ],
      "launchers" : [
        {
          "id" : "\(launcherID.uuidString)",
          "name" : "Steam",
          "kind" : "steam",
          "bottleID" : "\(containerID.uuidString)",
          "status" : "needsSetup"
        }
      ]
    }
    """
    try Data(legacySnapshot.utf8).write(to: root.appendingPathComponent("switchyard-library.json"))

    let loaded = try #require(try LibraryManifestStore(rootURL: root).loadSnapshot())

    #expect(loaded.containers.first?.id == containerID)
    #expect(loaded.launchers.first?.id == launcherID)
    #expect(loaded.launchers.first?.containerID == containerID)
}

@Test func librarySnapshotNormalizesLaunchersToOnePerContainer() throws {
    let steamContainer = Container(name: "Steam", path: "/tmp/Steam.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let epicContainer = Container(name: "Epic Games", path: "/tmp/Epic.container", wineBuildID: "wine-a", patchsetID: "patch-a")
    let primaryLauncher = Launcher(name: "Steam", kind: .steam, containerID: steamContainer.id)
    let duplicateLauncher = Launcher(name: "Steam Duplicate", kind: .steam, containerID: steamContainer.id)

    let snapshot = SwitchyardContainerSnapshot(
        containers: [steamContainer, epicContainer],
        launchers: [primaryLauncher, duplicateLauncher]
    )

    #expect(snapshot.launchers.count == 2)
    #expect(snapshot.launchers.first(where: { $0.containerID == steamContainer.id })?.id == primaryLauncher.id)
    #expect(snapshot.launchers.first(where: { $0.containerID == epicContainer.id })?.kind == .epicGames)
}
