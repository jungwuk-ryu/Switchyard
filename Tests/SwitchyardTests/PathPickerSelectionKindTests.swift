import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Switchyard

@Suite("Path Picker Selection Kind")
struct PathPickerSelectionKindTests {
    @Test("directory selection accepts only an existing real directory")
    func directorySelection() throws {
        let fixture = try PathPickerFixture()
        defer { fixture.remove() }
        let directory = try fixture.createDirectory("Library")
        let file = try fixture.createFile("Library.txt")

        #expect(
            PathPickerSelectionKind.directory.acceptedPath(for: directory)
                == directory.path
        )
        #expect(
            PathPickerSelectionKind.directory.acceptedPath(for: file) == nil
        )
        #expect(
            PathPickerSelectionKind.directory.acceptedPath(
                for: fixture.url("Missing")
            ) == nil
        )
        #expect(
            PathPickerSelectionKind.directory.acceptedPath(
                for: URL(fileURLWithPath: "/")
            ) == nil
        )
    }

    @Test("Windows executable selection validates regular file extensions case-insensitively")
    func windowsExecutableSelection() throws {
        let fixture = try PathPickerFixture()
        defer { fixture.remove() }
        let executable = try fixture.createFile("Game.EXE")
        let installer = try fixture.createFile("Setup.MsI")
        let textFile = try fixture.createFile("Notes.txt")
        let executableDirectory = try fixture.createDirectory("Folder.exe")

        #expect(
            PathPickerSelectionKind.windowsExecutable.acceptedPath(
                for: executable
            ) == executable.path
        )
        #expect(
            PathPickerSelectionKind.windowsExecutable.acceptedPath(
                for: installer
            ) == installer.path
        )
        #expect(
            PathPickerSelectionKind.windowsExecutable.acceptedPath(
                for: textFile
            ) == nil
        )
        #expect(
            PathPickerSelectionKind.windowsExecutable.acceptedPath(
                for: executableDirectory
            ) == nil
        )
    }

    @Test("GPTK selection accepts a directory or regular DMG only")
    func gptkSelection() throws {
        let fixture = try PathPickerFixture()
        defer { fixture.remove() }
        let directory = try fixture.createDirectory("Game Porting Toolkit")
        let diskImage = try fixture.createFile("GamePortingToolkit.DMG")
        let archive = try fixture.createFile("GamePortingToolkit.zip")

        #expect(
            PathPickerSelectionKind.gamePortingToolkit.acceptedPath(
                for: directory
            ) == directory.path
        )
        #expect(
            PathPickerSelectionKind.gamePortingToolkit.acceptedPath(
                for: diskImage
            ) == diskImage.path
        )
        #expect(
            PathPickerSelectionKind.gamePortingToolkit.acceptedPath(
                for: archive
            ) == nil
        )
    }

    @Test("Wine runtime selection requires a directory or executable regular file")
    func wineRuntimeSelection() throws {
        let fixture = try PathPickerFixture()
        defer { fixture.remove() }
        let directory = try fixture.createDirectory("Runtime")
        let executable = try fixture.createFile(
            "wine",
            permissions: 0o700
        )
        let nonExecutable = try fixture.createFile(
            "wine-disabled",
            permissions: 0o600
        )

        #expect(
            PathPickerSelectionKind.wineRuntime.acceptedPath(for: directory)
                == directory.path
        )
        #expect(
            PathPickerSelectionKind.wineRuntime.acceptedPath(for: executable)
                == executable.path
        )
        #expect(
            PathPickerSelectionKind.wineRuntime.acceptedPath(
                for: nonExecutable
            ) == nil
        )
    }

    @Test("symbolic links and unsafe URLs are rejected")
    func symbolicLinksAndUnsafeURLs() throws {
        let fixture = try PathPickerFixture()
        defer { fixture.remove() }
        let realDirectory = try fixture.createDirectory("Real")
        let executable = try fixture.createFile("Real/Game.exe")
        let directoryLink = fixture.url("Directory Link")
        let nestedLink = fixture.url("Nested Link")
        try FileManager.default.createSymbolicLink(
            at: directoryLink,
            withDestinationURL: realDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: nestedLink,
            withDestinationURL: realDirectory
        )

        #expect(
            PathPickerSelectionKind.directory.acceptedPath(
                for: directoryLink
            ) == nil
        )
        #expect(
            PathPickerSelectionKind.windowsExecutable.acceptedPath(
                for: nestedLink.appendingPathComponent("Game.exe")
            ) == nil
        )
        #expect(
            PathPickerSelectionKind.windowsExecutable.acceptedPath(
                for: executable
            ) == executable.path
        )
        #expect(
            PathPickerSelectionKind.directory.acceptedPath(
                for: URL(string: "https://example.com/folder")
            ) == nil
        )

        let nonStandardURL = fixture.rootURL
            .appendingPathComponent("Real")
            .appendingPathComponent("..")
            .appendingPathComponent("Real")
        #expect(
            PathPickerSelectionKind.directory.acceptedPath(
                for: nonStandardURL
            ) == nil
        )
    }

    @Test("cancel leaves the existing path unchanged")
    func cancelDoesNotMutatePath() {
        var storedPath = "/existing/selection"
        if let acceptedPath = PathPickerSelectionKind.directory.acceptedPath(
            for: nil
        ) {
            storedPath = acceptedPath
        }

        #expect(storedPath == "/existing/selection")
    }

    @Test("panel capabilities match each documented selection form")
    func panelCapabilities() {
        #expect(PathPickerSelectionKind.directory.canChooseDirectories)
        #expect(!PathPickerSelectionKind.directory.canChooseFiles)
        #expect(
            PathPickerSelectionKind.directory.allowedContentTypes == [.folder]
        )

        #expect(
            !PathPickerSelectionKind.windowsExecutable.canChooseDirectories
        )
        #expect(PathPickerSelectionKind.windowsExecutable.canChooseFiles)
        let windowsExtensions = Set(
            PathPickerSelectionKind.windowsExecutable
                .allowedContentTypes.map(\.preferredFilenameExtension)
                .compactMap { $0?.lowercased() }
        )
        #expect(windowsExtensions.contains("exe"))
        #expect(windowsExtensions.contains("msi"))

        #expect(
            PathPickerSelectionKind.gamePortingToolkit.canChooseDirectories
        )
        #expect(PathPickerSelectionKind.gamePortingToolkit.canChooseFiles)
        #expect(PathPickerSelectionKind.wineRuntime.canChooseDirectories)
        #expect(PathPickerSelectionKind.wineRuntime.canChooseFiles)
    }
}

private struct PathPickerFixture {
    let rootURL: URL

    init() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        var canonicalPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard temporaryPath.withCString({
            Darwin.realpath($0, &canonicalPath)
        }) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let canonicalBytes = canonicalPath
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        rootURL = URL(
            fileURLWithPath: String(decoding: canonicalBytes, as: UTF8.self),
            isDirectory: true
        )
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
    }

    func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func createDirectory(_ relativePath: String) throws -> URL {
        let url = self.url(relativePath)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func createFile(
        _ relativePath: String,
        permissions: Int = 0o600
    ) throws -> URL {
        let url = self.url(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data()
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
