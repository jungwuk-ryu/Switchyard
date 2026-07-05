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
        executableArguments: ["-safe-mode"],
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
    #expect(loaded.containers.first?.executableArguments == ["-safe-mode"])
    #expect(loaded.containers.first?.status == .ready)
    #expect(manifest.contains("\"containers\""))
    #expect(manifest.contains("\"executableArguments\""))
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
    #expect(loaded.first?.executableArguments == [])
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

@Test func legacySteamContainerKeepsEmptyExecutableArguments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let containerID = UUID()
    let steamPath = "C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe"
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let legacySnapshot = """
    {
      "containers" : [
        {
          "id" : "\(containerID.uuidString)",
          "name" : "Steam",
          "path" : "\(root.appendingPathComponent("Steam.container").path)",
          "wineBuildID" : "wine-a",
          "patchsetID" : "patch-a",
          "executablePath" : "\(steamPath)",
          "schemaVersion" : 1,
          "lastModified" : "2026-07-05T00:00:00Z"
        }
      ]
    }
    """
    try Data(legacySnapshot.utf8).write(to: root.appendingPathComponent("switchyard-library.json"))

    let loaded = try #require(try LibraryManifestStore(rootURL: root).loadSnapshot())

    #expect(loaded.containers.first?.schemaVersion == 3)
    #expect(loaded.containers.first?.executableArguments == [])
}

@Test func schemaTwoSteamContainerWithEmptyArgumentsKeepsEmptyArguments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let containerID = UUID()
    let steamPath = "C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe"
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let snapshot = """
    {
      "containers" : [
        {
          "id" : "\(containerID.uuidString)",
          "name" : "Steam",
          "path" : "\(root.appendingPathComponent("Steam.container").path)",
          "wineBuildID" : "wine-a",
          "patchsetID" : "patch-a",
          "executablePath" : "\(steamPath)",
          "executableArguments" : [],
          "schemaVersion" : 2,
          "lastModified" : "2026-07-05T00:00:00Z"
        }
      ]
    }
    """
    try Data(snapshot.utf8).write(to: root.appendingPathComponent("switchyard-library.json"))

    let loaded = try #require(try LibraryManifestStore(rootURL: root).loadSnapshot())

    #expect(loaded.containers.first?.schemaVersion == 3)
    #expect(loaded.containers.first?.executableArguments == [])
}

@Test func installedProgramCatalogFindsProgramFilesExecutables() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let containerURL = root.appendingPathComponent("Games.container", isDirectory: true)
    let steam = containerURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    let steamHelper = containerURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/bin/cef/steamwebhelper.exe")
    let battleNet = containerURL.appendingPathComponent("drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe")
    let battleNetUpdater = containerURL.appendingPathComponent("drive_c/Program Files (x86)/Battle.net/Battle.net Update Agent.exe")
    for executable in [steam, steamHelper, battleNet, battleNetUpdater] {
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
    }

    let container = Container(
        name: "Games",
        path: containerURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )

    let programs = InstalledProgramCatalog().installedPrograms(in: container)

    #expect(programs.map(\.name) == ["Battle.net Launcher", "Steam"])
    let expectedPaths = [battleNet, steam].map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    let discoveredPaths = programs.map { URL(fileURLWithPath: $0.executablePath).standardizedFileURL.resolvingSymlinksInPath().path }
    #expect(discoveredPaths == expectedPaths)
}

@Test func installedProgramCatalogIncludesDefaultExecutableInsideContainer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let containerURL = root.appendingPathComponent("Tools.container", isDirectory: true)
    let executable = containerURL.appendingPathComponent("drive_c/Tools/Toolbox.exe")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: executable)

    let container = Container(
        name: "Tools",
        path: containerURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: executable.path
    )

    let programs = InstalledProgramCatalog().installedPrograms(in: container)

    #expect(programs.count == 1)
    #expect(programs.first?.name == "Toolbox")
    #expect(programs.first?.source == .defaultExecutable)
}

@Test func installedProgramCatalogIgnoresExeDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let containerURL = root.appendingPathComponent("Broken.container", isDirectory: true)
    let programFilesDirectory = containerURL.appendingPathComponent("drive_c/Program Files/Fake/Fake.exe", isDirectory: true)
    let defaultDirectory = containerURL.appendingPathComponent("drive_c/Tools/Toolbox.exe", isDirectory: true)
    try FileManager.default.createDirectory(at: programFilesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)

    let container = Container(
        name: "Broken",
        path: containerURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: defaultDirectory.path
    )

    let programs = InstalledProgramCatalog().installedPrograms(in: container)

    #expect(programs.isEmpty)
}
