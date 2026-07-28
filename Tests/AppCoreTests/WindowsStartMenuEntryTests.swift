import AppCore
import Foundation
import Testing

@Test func windowsStartMenuPathsNormalizeRootsAndPreserveGroups() throws {
    let allUsersPath = try #require(
        WindowsStartMenuPath(
            #" c:/PROGRAMDATA/Microsoft/windows/Start Menu/Programs/Games/RPG/My Game.LNK "#
        )
    )
    #expect(
        allUsersPath.rawValue
            == #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Games\RPG\My Game.LNK"#
    )
    #expect(allUsersPath.kind == .lnk)
    #expect(allUsersPath.scope == .allUsers)
    #expect(allUsersPath.relativeComponents == ["Games", "RPG", "My Game.LNK"])
    #expect(allUsersPath.relativePath == #"Games\RPG\My Game.LNK"#)
    #expect(allUsersPath.groupComponents == ["Games", "RPG"])
    #expect(allUsersPath.groupPath == #"Games\RPG"#)
    #expect(allUsersPath.displayName == "My Game")

    let userPath = try #require(
        WindowsStartMenuPath(
            #"c:\USERS\steamuser\appdata\roaming\microsoft\windows\start menu\programs\Tools\Store.url"#
        )
    )
    #expect(
        userPath.rawValue
            == #"C:\users\steamuser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Tools\Store.url"#
    )
    #expect(userPath.kind == .url)
    #expect(userPath.scope == .user("steamuser"))
    #expect(
        WindowsStartMenuPath.programsPath(for: .user("steamuser"))
            == #"C:\users\steamuser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"#
    )

    let entry = try #require(
        WindowsStartMenuEntry(windowsShortcutPath: userPath.rawValue)
    )
    #expect(entry.displayName == "Store")
    #expect(entry.groupComponents == ["Tools"])
    #expect(entry.groupPath == "Tools")
    #expect(entry.windowsShortcutPath == userPath.rawValue)

    let localizedPath = try #require(
        WindowsStartMenuPath(
            #"C:\users\steamuser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\게임\하트피아.lnk"#
        )
    )
    #expect(localizedPath.groupComponents == ["게임"])
    #expect(localizedPath.displayName == "하트피아")
}

@Test func windowsStartMenuPathsRejectTraversalAndNonStartMenuFiles() {
    let rejectedPaths = [
        #"D:\ProgramData\Microsoft\Windows\Start Menu\Programs\Game.lnk"#,
        #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\..\Game.lnk"#,
        #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\\Game.lnk"#,
        #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Game.exe"#,
        #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Game.lnk:payload"#,
        #"C:\ProgramData\Microsoft\Windows\Desktop\Game.lnk"#,
        #"C:\users\steamuser\AppData\Roaming\Microsoft\Windows\Start Menu\Game.lnk"#,
        #"C:\users\..\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Game.lnk"#,
    ]

    for path in rejectedPaths {
        #expect(WindowsStartMenuPath(rawValue: path) == nil)
        #expect(WindowsStartMenuEntry(windowsShortcutPath: path) == nil)
    }
    #expect(WindowsStartMenuPath.programsPath(for: .user("..")) == nil)
    #expect(WindowsStartMenuPath.programsPath(for: .user("name/other")) == nil)
}

@Test func windowsStartMenuHostURLsRequireRegularFilesWithoutSymlinks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchyard-start-menu-path-\(UUID().uuidString)", isDirectory: true)
    let prefix = root.appendingPathComponent("Test.container", isDirectory: true)
    let programs = prefix.appendingPathComponent(
        "drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs",
        isDirectory: true
    )
    let shortcut = programs.appendingPathComponent("Games/Game.lnk")
    let outside = root.appendingPathComponent("Outside", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
        at: shortcut.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("shortcut".utf8).write(to: shortcut)
    try Data("outside".utf8).write(to: outside.appendingPathComponent("Linked.url"))

    let path = try #require(
        WindowsStartMenuPath(
            #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Games\Game.lnk"#
        )
    )
    #expect(path.hostURL(prefixPath: prefix.path)?.standardizedFileURL == shortcut.standardizedFileURL)
    #expect(
        WindowsStartMenuPath.hostProgramsDirectoryURL(
            for: .allUsers,
            prefixPath: prefix.path
        )?.standardizedFileURL == programs.standardizedFileURL
    )

    let linkedFile = programs.appendingPathComponent("Linked.lnk")
    try FileManager.default.createSymbolicLink(
        at: linkedFile,
        withDestinationURL: shortcut
    )
    #expect(
        WindowsStartMenuPath.hostShortcutURL(
            windowsPath: #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Linked.lnk"#,
            prefixPath: prefix.path
        ) == nil
    )

    let linkedGroup = programs.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createSymbolicLink(
        at: linkedGroup,
        withDestinationURL: outside
    )
    #expect(
        WindowsStartMenuPath.hostShortcutURL(
            windowsPath:
                #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\External\Linked.url"#,
            prefixPath: prefix.path
        ) == nil
    )
    #expect(
        WindowsStartMenuPath.hostShortcutURL(
            windowsPath: #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Missing.lnk"#,
            prefixPath: prefix.path
        ) == nil
    )
}
