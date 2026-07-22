import AppCore
import Foundation
import Persistence
import Testing

private enum TestContainerRenameError: Error, Equatable {
    case saveFailed
}

@Test func containerDirectoryRenamerMovesFolderAndRebasesExecutable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("NewContainer.container", isDirectory: true)
    let executableURL = sourceURL.appendingPathComponent(
        "drive_c/Program Files/Epic Games/Launcher.exe"
    )
    try FileManager.default.createDirectory(
        at: executableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: executableURL)

    let container = Container(
        name: "New Container",
        path: sourceURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        executablePath: executableURL.path
    )
    try ContainerManifestStore(rootURL: root).save(container)

    let renamed = try ContainerDirectoryRenamer(rootURL: root)
        .rename(container, to: "Epic Games")
    let destinationURL = root.appendingPathComponent("EpicGames.container", isDirectory: true)

    #expect(renamed.name == "Epic Games")
    #expect(renamed.path == destinationURL.path)
    #expect(
        renamed.executablePath
            == destinationURL.appendingPathComponent(
                "drive_c/Program Files/Epic Games/Launcher.exe"
            ).path
    )
    #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(FileManager.default.fileExists(atPath: renamed.executablePath ?? ""))

    let loaded = try #require(
        ContainerManifestStore(rootURL: root).loadContainers().first
    )
    #expect(loaded.id == renamed.id)
    #expect(loaded.name == renamed.name)
    #expect(
        URL(fileURLWithPath: loaded.path).resolvingSymlinksInPath()
            == destinationURL.resolvingSymlinksInPath()
    )
    #expect(
        loaded.executablePath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath()
        } == renamed.executablePath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath()
        }
    )
}

@Test func containerDirectoryRenamerAvoidsExistingFolderName() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("NewContainer.container", isDirectory: true)
    let occupiedURL = root.appendingPathComponent("EpicGames.container", isDirectory: true)
    let container = Container(
        name: "New Container",
        path: sourceURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )
    try ContainerManifestStore(rootURL: root).save(container)
    try FileManager.default.createDirectory(at: occupiedURL, withIntermediateDirectories: true)

    let renamed = try ContainerDirectoryRenamer(rootURL: root)
        .rename(container, to: "Epic Games")

    #expect(renamed.path == root.appendingPathComponent("EpicGames2.container").path)
    #expect(FileManager.default.fileExists(atPath: occupiedURL.path))
}

@Test func containerDirectoryRenamerHonorsReservedInMemoryFolderNames() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("NewContainer.container", isDirectory: true)
    let container = Container(
        name: "New Container",
        path: sourceURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )
    try ContainerManifestStore(rootURL: root).save(container)

    let renamed = try ContainerDirectoryRenamer(rootURL: root).rename(
        container,
        to: "Epic Games",
        occupiedDirectoryNames: ["EpicGames.container"]
    )

    #expect(renamed.path == root.appendingPathComponent("EpicGames2.container").path)
}

@Test func containerDirectoryRenamerRollsBackWhenLibrarySaveFails() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("NewContainer.container", isDirectory: true)
    let container = Container(
        name: "New Container",
        path: sourceURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )
    try ContainerManifestStore(rootURL: root).save(container)

    #expect(throws: TestContainerRenameError.saveFailed) {
        _ = try ContainerDirectoryRenamer(rootURL: root).rename(
            container,
            to: "Epic Games"
        ) { _ in
            throw TestContainerRenameError.saveFailed
        }
    }

    #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(
        !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("EpicGames.container").path
        )
    )
    let restored = try #require(
        ContainerManifestStore(rootURL: root).loadContainers().first
    )
    #expect(restored.name == container.name)
}

@Test func librarySnapshotRoundTripsContainers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let container = Container(
        name: "Toolbox",
        path: root.appendingPathComponent("Toolbox.container", isDirectory: true).path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a",
        starterApplicationID: "steam",
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
    #expect(loaded.containers.first?.starterApplicationID == "steam")
    #expect(loaded.containers.first?.executablePath == "C:\\Tools\\Toolbox.exe")
    #expect(loaded.containers.first?.executableArguments == ["-safe-mode"])
    #expect(loaded.containers.first?.status == .ready)
    #expect(manifest.contains("\"containers\""))
    #expect(manifest.contains("\"executableArguments\""))
    #expect(manifest.contains("\"starterApplicationID\""))
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

    #expect(loaded.containers.first?.schemaVersion == 4)
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

    #expect(loaded.containers.first?.schemaVersion == 4)
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

@Test func containerDirectoryCatalogListsFoldersBeforeFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let containerURL = root.appendingPathComponent("Games.container", isDirectory: true)
    let driveCURL = containerURL.appendingPathComponent("drive_c", isDirectory: true)
    let programFilesURL = driveCURL.appendingPathComponent("Program Files", isDirectory: true)
    try FileManager.default.createDirectory(at: programFilesURL, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: driveCURL.appendingPathComponent("readme.txt"))
    try Data("hidden".utf8).write(to: driveCURL.appendingPathComponent(".hidden"))

    let container = Container(
        name: "Games",
        path: containerURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )
    let catalog = ContainerDirectoryCatalog()

    #expect(catalog.defaultDirectory(for: container) == driveCURL.standardizedFileURL)
    let entries = try catalog.contents(of: driveCURL, in: container)
    #expect(entries.map(\.name) == ["Program Files", "readme.txt"])
    #expect(entries.first?.isDirectory == true)
    #expect(entries.first?.isNavigable == true)
    #expect(entries.last?.byteCount == 5)
}

@Test func containerDirectoryCatalogBlocksSymlinksOutsideContainer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let containerURL = root.appendingPathComponent("Games.container", isDirectory: true)
    let driveCURL = containerURL.appendingPathComponent("drive_c", isDirectory: true)
    let outsideURL = root.appendingPathComponent("Outside", isDirectory: true)
    let linkedURL = driveCURL.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createDirectory(at: driveCURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outsideURL)

    let container = Container(
        name: "Games",
        path: containerURL.path,
        wineBuildID: "wine-a",
        patchsetID: "patch-a"
    )
    let catalog = ContainerDirectoryCatalog()
    let entries = try catalog.contents(of: driveCURL, in: container)
    let externalEntry = try #require(entries.first(where: { $0.name == "External" }))

    #expect(externalEntry.isNavigable == false)
    #expect(catalog.contains(linkedURL, in: container) == false)
    do {
        _ = try catalog.contents(of: linkedURL, in: container)
        Issue.record("Expected browsing an external symlink to fail")
    } catch let error as ContainerDirectoryCatalogError {
        #expect(error == .outsideContainer)
    }
}

@Test func windowsExecutableIconExtractorBuildsICOFromPEResources() throws {
    let iconImage = Data([0x11, 0x22, 0x33, 0x44])
    let executable = makePEExecutableWithIconResource(iconImage: iconImage)

    let icon = try #require(WindowsExecutableIconExtractor.iconData(from: executable))

    #expect(icon.count == 26)
    #expect(Array(icon.prefix(6)) == [0, 0, 1, 0, 1, 0])
    #expect(Array(icon[6..<10]) == [32, 32, 0, 0])
    #expect(Array(icon.suffix(iconImage.count)) == Array(iconImage))
}

@Test func windowsExecutableIconExtractorRejectsTruncatedAndOutOfBoundsResources() {
    #expect(WindowsExecutableIconExtractor.iconData(from: Data([0x4D, 0x5A])) == nil)

    var executable = makePEExecutableWithIconResource(iconImage: Data([0x11, 0x22]))
    writeLittleEndian(UInt32.max, to: &executable, at: 0x250)
    #expect(WindowsExecutableIconExtractor.iconData(from: executable) == nil)
}

private func makePEExecutableWithIconResource(iconImage: Data) -> Data {
    var data = Data(repeating: 0, count: 0x600)
    data[0] = 0x4D
    data[1] = 0x5A
    writeLittleEndian(UInt32(0x80), to: &data, at: 0x3C)

    data.replaceSubrange(0x80..<0x84, with: [0x50, 0x45, 0, 0])
    writeLittleEndian(UInt16(1), to: &data, at: 0x86)
    writeLittleEndian(UInt16(224), to: &data, at: 0x94)

    let optionalHeader = 0x98
    writeLittleEndian(UInt16(0x10B), to: &data, at: optionalHeader)
    writeLittleEndian(UInt32(0x1_000), to: &data, at: optionalHeader + 112)
    writeLittleEndian(UInt32(0x200), to: &data, at: optionalHeader + 116)

    let section = optionalHeader + 224
    writeLittleEndian(UInt32(0x400), to: &data, at: section + 8)
    writeLittleEndian(UInt32(0x1_000), to: &data, at: section + 12)
    writeLittleEndian(UInt32(0x400), to: &data, at: section + 16)
    writeLittleEndian(UInt32(0x200), to: &data, at: section + 20)

    let resources = 0x200
    writeLittleEndian(UInt16(2), to: &data, at: resources + 14)
    writeLittleEndian(UInt32(3), to: &data, at: resources + 0x10)
    writeLittleEndian(UInt32(0x8000_0020), to: &data, at: resources + 0x14)
    writeLittleEndian(UInt32(14), to: &data, at: resources + 0x18)
    writeLittleEndian(UInt32(0x8000_0060), to: &data, at: resources + 0x1C)

    writeLittleEndian(UInt16(1), to: &data, at: resources + 0x20 + 14)
    writeLittleEndian(UInt32(1), to: &data, at: resources + 0x30)
    writeLittleEndian(UInt32(0x8000_0038), to: &data, at: resources + 0x34)
    writeLittleEndian(UInt16(1), to: &data, at: resources + 0x38 + 14)
    writeLittleEndian(UInt32(1_033), to: &data, at: resources + 0x48)
    writeLittleEndian(UInt32(0x50), to: &data, at: resources + 0x4C)
    writeLittleEndian(UInt32(0x1_100), to: &data, at: resources + 0x50)
    writeLittleEndian(UInt32(iconImage.count), to: &data, at: resources + 0x54)

    writeLittleEndian(UInt16(1), to: &data, at: resources + 0x60 + 14)
    writeLittleEndian(UInt32(101), to: &data, at: resources + 0x70)
    writeLittleEndian(UInt32(0x8000_0078), to: &data, at: resources + 0x74)
    writeLittleEndian(UInt16(1), to: &data, at: resources + 0x78 + 14)
    writeLittleEndian(UInt32(1_033), to: &data, at: resources + 0x88)
    writeLittleEndian(UInt32(0x90), to: &data, at: resources + 0x8C)
    writeLittleEndian(UInt32(0x1_120), to: &data, at: resources + 0x90)
    writeLittleEndian(UInt32(20), to: &data, at: resources + 0x94)

    data.replaceSubrange(0x300..<(0x300 + iconImage.count), with: iconImage)
    writeLittleEndian(UInt16(1), to: &data, at: 0x322)
    writeLittleEndian(UInt16(1), to: &data, at: 0x324)
    data[0x326] = 32
    data[0x327] = 32
    writeLittleEndian(UInt16(1), to: &data, at: 0x32A)
    writeLittleEndian(UInt16(32), to: &data, at: 0x32C)
    writeLittleEndian(UInt32(iconImage.count), to: &data, at: 0x32E)
    writeLittleEndian(UInt16(1), to: &data, at: 0x332)
    return data
}

private func writeLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
