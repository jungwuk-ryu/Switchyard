import AppCore
import Foundation
import Persistence
import Testing

@Test func windowsShortcutIconExtractorUsesExplicitIconLocation() throws {
    let fixture = try makeShortcutFixture(shortcutName: "Acme")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let iconURL = fixture.prefixURL.appendingPathComponent(
        "drive_c/Program Files/Acme/acme.ico"
    )
    let iconData = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0xAC, 0x4D])
    try writeTestFile(iconData, to: iconURL)
    try makeShellLink(
        iconPath: #"%ProgramFiles%\Acme\acme.ico"#,
        iconIndex: 7
    ).write(to: fixture.shortcutURL)

    let source = try #require(
        WindowsShortcutIconExtractor.source(
            for: fixture.entry,
            prefixPath: fixture.prefixURL.path
        )
    )

    #expect(source.fileURL == iconURL.standardizedFileURL)
    #expect(source.iconIndex == 7)
    #expect(WindowsShortcutIconExtractor.iconData(from: source) == iconData)
}

@Test func windowsShortcutIconExtractorFallsBackToLinkTarget() throws {
    let fixture = try makeShortcutFixture(shortcutName: "Tool")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let executableURL = fixture.prefixURL.appendingPathComponent(
        "drive_c/Tools/Tool.exe"
    )
    try writeTestFile(Data([0x4D, 0x5A]), to: executableURL)
    try makeShellLink(
        targetPath: #"C:\Tools\Tool.exe"#,
        iconIndex: 0
    ).write(to: fixture.shortcutURL)

    let source = try #require(
        WindowsShortcutIconExtractor.source(
            for: fixture.entry,
            prefixPath: fixture.prefixURL.path
        )
    )

    #expect(source.fileURL == executableURL.standardizedFileURL)
    #expect(source.iconIndex == 0)
}

@Test func windowsShortcutIconExtractorTriesTargetWhenExplicitIconFails() throws {
    let fixture = try makeShortcutFixture(shortcutName: "Target Fallback")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let invalidIconURL = fixture.prefixURL.appendingPathComponent(
        "drive_c/Bad/invalid.exe"
    )
    try writeTestFile(Data([0x4D, 0x5A]), to: invalidIconURL)

    let targetIconURL = fixture.prefixURL.appendingPathComponent(
        "drive_c/Target/fallback.ico"
    )
    let targetIconData = Data([0x00, 0x00, 0x01, 0x00, 0xF0, 0x0D])
    try writeTestFile(targetIconData, to: targetIconURL)

    try makeShellLink(
        targetPath: #"C:\Target\fallback.ico"#,
        iconPath: #"C:\Bad\invalid.exe"#,
        iconIndex: 0
    ).write(to: fixture.shortcutURL)

    #expect(
        WindowsShortcutIconExtractor.iconData(
            for: fixture.entry,
            prefixPath: fixture.prefixURL.path
        ) == targetIconData
    )
}

@Test func windowsShortcutIconExtractorResolvesRelativeIconFromDriveRoot() throws {
    let fixture = try makeShortcutFixture(shortcutName: "Root Relative")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let iconURL = fixture.prefixURL.appendingPathComponent(
        "drive_c/root.ico"
    )
    let iconData = Data([0x00, 0x00, 0x01, 0x00, 0xC0, 0xDE])
    try writeTestFile(iconData, to: iconURL)

    try makeShellLink(
        iconPath: "root.ico",
        iconIndex: 0,
        workingDirectory: #"C:\"#
    ).write(to: fixture.shortcutURL)

    let source = try #require(
        WindowsShortcutIconExtractor.source(
            for: fixture.entry,
            prefixPath: fixture.prefixURL.path
        )
    )

    #expect(source.fileURL == iconURL.standardizedFileURL)
    #expect(WindowsShortcutIconExtractor.iconData(from: source) == iconData)
}

@Test func windowsShortcutIconExtractorReadsInternetShortcutIcon() throws {
    let fixture = try makeShortcutFixture(
        shortcutName: "Website",
        fileExtension: "url"
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let iconURL = fixture.prefixURL.appendingPathComponent(
        "drive_c/Icons/website.ico"
    )
    try writeTestFile(Data([0x00, 0x00, 0x01, 0x00]), to: iconURL)
    let contents = """
    [InternetShortcut]
    URL=https://example.com
    IconFile=C:\\Icons\\website.ico
    IconIndex=3
    """
    try Data(contents.utf8).write(to: fixture.shortcutURL)

    let source = try #require(
        WindowsShortcutIconExtractor.source(
            for: fixture.entry,
            prefixPath: fixture.prefixURL.path
        )
    )

    #expect(source.fileURL == iconURL.standardizedFileURL)
    #expect(source.iconIndex == 3)
}

@Test func windowsShortcutIconExtractorRejectsSymlinkedIconSource() throws {
    let fixture = try makeShortcutFixture(shortcutName: "Unsafe")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let outsideURL = fixture.rootURL.appendingPathComponent(
        "Outside",
        isDirectory: true
    )
    let linkedIconsURL = fixture.prefixURL.appendingPathComponent(
        "drive_c/Icons",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: outsideURL,
        withIntermediateDirectories: true
    )
    try Data([0x00, 0x00, 0x01, 0x00]).write(
        to: outsideURL.appendingPathComponent("unsafe.ico")
    )
    try FileManager.default.createSymbolicLink(
        at: linkedIconsURL,
        withDestinationURL: outsideURL
    )
    try makeShellLink(
        iconPath: #"C:\Icons\unsafe.ico"#,
        iconIndex: 0
    ).write(to: fixture.shortcutURL)

    #expect(
        WindowsShortcutIconExtractor.source(
            for: fixture.entry,
            prefixPath: fixture.prefixURL.path
        ) == nil
    )
}

@Test func windowsShortcutIconExtractorRejectsMalformedStringData() throws {
    let fixture = try makeShortcutFixture(shortcutName: "Malformed")
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    var malformed = makeShellLink(
        iconPath: #"C:\Icons\missing.ico"#,
        iconIndex: 0
    )
    writeShortcutLittleEndian(UInt16.max, to: &malformed, at: 0x4C)
    try malformed.write(to: fixture.shortcutURL)

    #expect(
        WindowsShortcutIconExtractor.source(
            for: fixture.entry,
            prefixPath: fixture.prefixURL.path
        ) == nil
    )
}

private struct ShortcutFixture {
    let rootURL: URL
    let prefixURL: URL
    let shortcutURL: URL
    let entry: WindowsStartMenuEntry
}

private func makeShortcutFixture(
    shortcutName: String,
    fileExtension: String = "lnk"
) throws -> ShortcutFixture {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let prefixURL = rootURL.appendingPathComponent(
        "Test.container",
        isDirectory: true
    )
    let relativePath = "ProgramData/Microsoft/Windows/Start Menu/Programs/"
        + shortcutName + "." + fileExtension
    let shortcutURL = prefixURL
        .appendingPathComponent("drive_c")
        .appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: shortcutURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let windowsPath = #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\"#
        + shortcutName + "." + fileExtension
    let entry = try #require(
        WindowsStartMenuEntry(windowsShortcutPath: windowsPath)
    )
    return ShortcutFixture(
        rootURL: rootURL,
        prefixURL: prefixURL,
        shortcutURL: shortcutURL,
        entry: entry
    )
}

private func writeTestFile(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url)
}

private func makeShellLink(
    targetPath: String? = nil,
    iconPath: String? = nil,
    iconIndex: Int32,
    workingDirectory: String? = nil
) -> Data {
    var flags: UInt32 = 1 << 7
    if targetPath != nil { flags |= 1 << 1 }
    if workingDirectory != nil { flags |= 1 << 4 }
    if iconPath != nil { flags |= 1 << 6 }

    var data = Data(repeating: 0, count: 0x4C)
    writeShortcutLittleEndian(UInt32(0x4C), to: &data, at: 0)
    data.replaceSubrange(4..<20, with: [
        0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46,
    ])
    writeShortcutLittleEndian(flags, to: &data, at: 0x14)
    writeShortcutLittleEndian(
        UInt32(bitPattern: iconIndex),
        to: &data,
        at: 0x38
    )
    writeShortcutLittleEndian(UInt32(1), to: &data, at: 0x3C)

    if let targetPath {
        data.append(makeLinkInfo(targetPath: targetPath))
    }
    if let workingDirectory {
        appendCountedUTF16(workingDirectory, to: &data)
    }
    if let iconPath {
        appendCountedUTF16(iconPath, to: &data)
    }
    return data
}

private func makeLinkInfo(targetPath: String) -> Data {
    let baseBytes = Array(targetPath.utf8)
    let headerSize = 0x1C
    let suffixOffset = headerSize + baseBytes.count + 1
    let totalSize = suffixOffset + 1
    var data = Data(repeating: 0, count: totalSize)
    writeShortcutLittleEndian(UInt32(totalSize), to: &data, at: 0)
    writeShortcutLittleEndian(UInt32(headerSize), to: &data, at: 4)
    writeShortcutLittleEndian(UInt32(1), to: &data, at: 8)
    writeShortcutLittleEndian(UInt32(headerSize), to: &data, at: 16)
    writeShortcutLittleEndian(UInt32(suffixOffset), to: &data, at: 24)
    data.replaceSubrange(
        headerSize..<(headerSize + baseBytes.count),
        with: baseBytes
    )
    return data
}

private func appendCountedUTF16(_ value: String, to data: inout Data) {
    let characters = Array(value.utf16) + [UInt16(0)]
    appendShortcutLittleEndian(UInt16(characters.count), to: &data)
    for character in characters {
        appendShortcutLittleEndian(character, to: &data)
    }
}

private func appendShortcutLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func writeShortcutLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data,
    at offset: Int
) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
