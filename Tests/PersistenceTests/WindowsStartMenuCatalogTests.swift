import AppCore
import Foundation
import Persistence
import Testing

@Test func windowsStartMenuCatalogFindsSystemAndUserShortcutsWithGroups() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchyard-start-menu-catalog-\(UUID().uuidString)", isDirectory: true)
    let prefix = root.appendingPathComponent("Games.container", isDirectory: true)
    let systemPrograms = prefix.appendingPathComponent(
        "drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs",
        isDirectory: true
    )
    let alicePrograms = prefix.appendingPathComponent(
        "drive_c/users/alice/AppData/Roaming/Microsoft/Windows/Start Menu/Programs",
        isDirectory: true
    )
    let bobPrograms = prefix.appendingPathComponent(
        "drive_c/users/bob/AppData/Roaming/Microsoft/Windows/Start Menu/Programs",
        isDirectory: true
    )
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStartMenuTestFile(
        systemPrograms.appendingPathComponent("Games/Action/Hades.lnk")
    )
    try writeStartMenuTestFile(
        alicePrograms.appendingPathComponent("Web/Portal.url")
    )
    try writeStartMenuTestFile(
        bobPrograms.appendingPathComponent("Steam.LNK")
    )
    try writeStartMenuTestFile(systemPrograms.appendingPathComponent("Ignore.txt"))
    try FileManager.default.createDirectory(
        at: systemPrograms.appendingPathComponent("Directory.lnk", isDirectory: true),
        withIntermediateDirectories: true
    )
    try writeStartMenuTestFile(outside.appendingPathComponent("Escaped.url"))
    try FileManager.default.createSymbolicLink(
        at: systemPrograms.appendingPathComponent("Linked.lnk"),
        withDestinationURL: outside.appendingPathComponent("Escaped.url")
    )
    try FileManager.default.createSymbolicLink(
        at: systemPrograms.appendingPathComponent("External", isDirectory: true),
        withDestinationURL: outside
    )

    let container = Container(name: "Games", path: prefix.path)
    let entries = WindowsStartMenuCatalog().entries(in: container)

    #expect(entries.map(\.displayName) == ["Hades", "Portal", "Steam"])
    let hades = try #require(entries.first(where: { $0.displayName == "Hades" }))
    #expect(hades.scope == .allUsers)
    #expect(hades.kind == .lnk)
    #expect(hades.groupComponents == ["Games", "Action"])
    #expect(hades.groupPath == #"Games\Action"#)
    #expect(
        hades.windowsShortcutPath
            == #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Games\Action\Hades.lnk"#
    )

    let portal = try #require(entries.first(where: { $0.displayName == "Portal" }))
    #expect(portal.scope == .user("alice"))
    #expect(portal.kind == .url)
    #expect(portal.groupComponents == ["Web"])

    let steam = try #require(entries.first(where: { $0.displayName == "Steam" }))
    #expect(steam.scope == .user("bob"))
    #expect(steam.groupComponents.isEmpty)
    #expect(steam.groupPath.isEmpty)
}

@Test func windowsStartMenuCatalogHonorsEntryDepthAndTraversalLimits() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchyard-start-menu-limits-\(UUID().uuidString)", isDirectory: true)
    let prefix = root.appendingPathComponent("Games.container", isDirectory: true)
    let programs = prefix.appendingPathComponent(
        "drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try writeStartMenuTestFile(programs.appendingPathComponent("Root.lnk"))
    try writeStartMenuTestFile(programs.appendingPathComponent("One/One.lnk"))
    try writeStartMenuTestFile(programs.appendingPathComponent("One/Two/Two.lnk"))

    let depthLimited = WindowsStartMenuCatalog(
        limits: .init(
            maximumEntries: 10,
            maximumVisitedItems: 100,
            maximumGroupDepth: 1
        )
    ).entries(prefixPath: prefix.path)
    #expect(Set(depthLimited.map(\.displayName)) == ["Root", "One"])

    let entryLimited = WindowsStartMenuCatalog(
        limits: .init(
            maximumEntries: 1,
            maximumVisitedItems: 100,
            maximumGroupDepth: 8
        )
    ).entries(prefixPath: prefix.path)
    #expect(entryLimited.count == 1)

    let traversalLimited = WindowsStartMenuCatalog(
        limits: .init(
            maximumEntries: 10,
            maximumVisitedItems: 1,
            maximumGroupDepth: 8
        )
    ).entries(prefixPath: prefix.path)
    #expect(traversalLimited.count <= 1)
}

@Test func windowsStartMenuCatalogRejectsSymlinkedRootsOutsidePrefix() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchyard-start-menu-root-link-\(UUID().uuidString)", isDirectory: true)
    let prefix = root.appendingPathComponent("Games.container", isDirectory: true)
    let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    let outsidePrograms = outside.appendingPathComponent(
        "Microsoft/Windows/Start Menu/Programs",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
    try writeStartMenuTestFile(outsidePrograms.appendingPathComponent("Escaped.lnk"))
    try FileManager.default.createSymbolicLink(
        at: driveC.appendingPathComponent("ProgramData", isDirectory: true),
        withDestinationURL: outside
    )

    #expect(
        WindowsStartMenuPath.hostProgramsDirectoryURL(
            for: .allUsers,
            prefixPath: prefix.path
        ) == nil
    )
    #expect(WindowsStartMenuCatalog().entries(prefixPath: prefix.path).isEmpty)
}

private func writeStartMenuTestFile(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("shortcut".utf8).write(to: url)
}
