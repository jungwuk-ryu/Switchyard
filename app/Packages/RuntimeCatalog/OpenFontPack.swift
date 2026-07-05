import AppCore
import CryptoKit
import Foundation

public struct OpenFontFile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var fileName: String
    public var sourceURL: URL
    public var sha256: String
    public var licenseName: String
    public var licenseURL: URL
    public var registryEntries: [String]

    public init(
        id: String,
        displayName: String,
        fileName: String,
        sourceURL: URL,
        sha256: String,
        licenseName: String,
        licenseURL: URL,
        registryEntries: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.registryEntries = registryEntries
    }
}

public struct FontReplacement: Codable, Equatable, Sendable {
    public var requestedFamily: String
    public var replacementFamily: String

    public init(requestedFamily: String, replacementFamily: String) {
        self.requestedFamily = requestedFamily
        self.replacementFamily = replacementFamily
    }
}

public struct OpenFontPackStatus: Codable, Equatable, Sendable {
    public var status: HealthStatus
    public var message: String
    public var missingFonts: [String]

    public init(status: HealthStatus, message: String, missingFonts: [String] = []) {
        self.status = status
        self.message = message
        self.missingFonts = missingFonts
    }
}

public struct OpenFontPackDownloadResult: Codable, Equatable, Sendable {
    public var downloadedFonts: [String]
    public var cachedFonts: [String]
    public var noticePath: String

    public init(downloadedFonts: [String], cachedFonts: [String], noticePath: String) {
        self.downloadedFonts = downloadedFonts
        self.cachedFonts = cachedFonts
        self.noticePath = noticePath
    }

    public var summary: String {
        if downloadedFonts.isEmpty {
            return "Open Font Pack is already cached with \(cachedFonts.count) font files."
        }
        return "Downloaded \(downloadedFonts.count) Open Font Pack font file(s); \(cachedFonts.count) file(s) were already cached."
    }
}

public enum OpenFontPackCatalog {
    public static let licenseName = "SIL Open Font License 1.1"
    public static let licenseURL = URL(string: "https://openfontlicense.org/")!

    public static let files: [OpenFontFile] = [
        OpenFontFile(
            id: "noto-sans-regular",
            displayName: "Noto Sans Regular",
            fileName: "NotoSans-Regular.ttf",
            sourceURL: URL(string: "https://github.com/notofonts/noto-fonts/raw/ffebf8c1ee449e544955a7e813c54f9b73848eac/hinted/ttf/NotoSans/NotoSans-Regular.ttf")!,
            sha256: "b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5",
            licenseName: licenseName,
            licenseURL: licenseURL,
            registryEntries: [
                "Noto Sans (TrueType)"
            ]
        ),
        OpenFontFile(
            id: "noto-sans-bold",
            displayName: "Noto Sans Bold",
            fileName: "NotoSans-Bold.ttf",
            sourceURL: URL(string: "https://github.com/notofonts/noto-fonts/raw/ffebf8c1ee449e544955a7e813c54f9b73848eac/hinted/ttf/NotoSans/NotoSans-Bold.ttf")!,
            sha256: "c976e4b1b99edc88775377fcc21692ca4bfa46b6d6ca6522bfda505b28ff9d6a",
            licenseName: licenseName,
            licenseURL: licenseURL,
            registryEntries: [
                "Noto Sans Bold (TrueType)"
            ]
        ),
        OpenFontFile(
            id: "noto-sans-cjk-regular",
            displayName: "Noto Sans CJK Regular",
            fileName: "NotoSansCJK-Regular.ttc",
            sourceURL: URL(string: "https://github.com/notofonts/noto-cjk/raw/523d033d6cb47f4a80c58a35753646f5c3608a78/Sans/OTC/NotoSansCJK-Regular.ttc")!,
            sha256: "b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a",
            licenseName: licenseName,
            licenseURL: licenseURL,
            registryEntries: [
                "Noto Sans CJK HK (TrueType)",
                "Noto Sans CJK JP (TrueType)",
                "Noto Sans CJK KR (TrueType)",
                "Noto Sans CJK SC (TrueType)",
                "Noto Sans CJK TC (TrueType)"
            ]
        ),
        OpenFontFile(
            id: "noto-sans-cjk-bold",
            displayName: "Noto Sans CJK Bold",
            fileName: "NotoSansCJK-Bold.ttc",
            sourceURL: URL(string: "https://github.com/notofonts/noto-cjk/raw/523d033d6cb47f4a80c58a35753646f5c3608a78/Sans/OTC/NotoSansCJK-Bold.ttc")!,
            sha256: "faa5f3656a78b2e2d450d27fe8382c778bc2b6bb5ea29c986664a6a435056ceb",
            licenseName: licenseName,
            licenseURL: licenseURL,
            registryEntries: [
                "Noto Sans CJK HK Bold (TrueType)",
                "Noto Sans CJK JP Bold (TrueType)",
                "Noto Sans CJK KR Bold (TrueType)",
                "Noto Sans CJK SC Bold (TrueType)",
                "Noto Sans CJK TC Bold (TrueType)"
            ]
        )
    ]

    public static let replacements: [FontReplacement] = [
        FontReplacement(requestedFamily: "Arial", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Arial Unicode MS", replacementFamily: "Noto Sans CJK KR"),
        FontReplacement(requestedFamily: "Helvetica", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Microsoft JhengHei", replacementFamily: "Noto Sans CJK TC"),
        FontReplacement(requestedFamily: "Microsoft JhengHei UI", replacementFamily: "Noto Sans CJK TC"),
        FontReplacement(requestedFamily: "Microsoft Sans Serif", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Microsoft YaHei", replacementFamily: "Noto Sans CJK SC"),
        FontReplacement(requestedFamily: "Microsoft YaHei UI", replacementFamily: "Noto Sans CJK SC"),
        FontReplacement(requestedFamily: "MS Gothic", replacementFamily: "Noto Sans CJK JP"),
        FontReplacement(requestedFamily: "MS PGothic", replacementFamily: "Noto Sans CJK JP"),
        FontReplacement(requestedFamily: "MS UI Gothic", replacementFamily: "Noto Sans CJK JP"),
        FontReplacement(requestedFamily: "Malgun Gothic", replacementFamily: "Noto Sans CJK KR"),
        FontReplacement(requestedFamily: "Malgun Gothic Semilight", replacementFamily: "Noto Sans CJK KR"),
        FontReplacement(requestedFamily: "Meiryo", replacementFamily: "Noto Sans CJK JP"),
        FontReplacement(requestedFamily: "Meiryo UI", replacementFamily: "Noto Sans CJK JP"),
        FontReplacement(requestedFamily: "MingLiU", replacementFamily: "Noto Sans CJK TC"),
        FontReplacement(requestedFamily: "PMingLiU", replacementFamily: "Noto Sans CJK TC"),
        FontReplacement(requestedFamily: "Segoe UI", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Segoe UI Black", replacementFamily: "Noto Sans Bold"),
        FontReplacement(requestedFamily: "Segoe UI Emoji", replacementFamily: "Noto Sans CJK KR"),
        FontReplacement(requestedFamily: "Segoe UI Historic", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Segoe UI Light", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Segoe UI Semibold", replacementFamily: "Noto Sans Bold"),
        FontReplacement(requestedFamily: "Segoe UI Semilight", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Segoe UI Symbol", replacementFamily: "Noto Sans CJK KR"),
        FontReplacement(requestedFamily: "SimSun", replacementFamily: "Noto Sans CJK SC"),
        FontReplacement(requestedFamily: "Tahoma", replacementFamily: "Noto Sans"),
        FontReplacement(requestedFamily: "Yu Gothic", replacementFamily: "Noto Sans CJK JP"),
        FontReplacement(requestedFamily: "Yu Gothic UI", replacementFamily: "Noto Sans CJK JP")
    ]

    public static func defaultCacheRoot(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
            .appendingPathComponent("OpenFontPack", isDirectory: true)
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("Switchyard", isDirectory: true)
                .appendingPathComponent("OpenFontPack", isDirectory: true)
    }

    public static func diagnose(cacheRoot: URL, fileManager: FileManager = .default) -> OpenFontPackStatus {
        let missing = files.filter { font in
            let url = cacheRoot.appendingPathComponent(font.fileName)
            guard fileManager.fileExists(atPath: url.path),
                  let digest = try? sha256Hex(for: url) else {
                return true
            }
            return digest != font.sha256
        }

        if missing.isEmpty {
            return OpenFontPackStatus(
                status: .ok,
                message: "Open Font Pack is cached and ready for container installation."
            )
        }

        return OpenFontPackStatus(
            status: .warning,
            message: "Open Font Pack is missing \(missing.count) OFL font file(s). Switchyard will try to download them automatically.",
            missingFonts: missing.map(\.displayName)
        )
    }

    public static func writeNotice(to cacheRoot: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let noticeURL = cacheRoot.appendingPathComponent("SWITCHYARD-FONT-PACK-NOTICES.txt")
        let body = """
        Switchyard Open Font Pack

        Switchyard downloads these font files from official upstream repositories and installs
        them into user-created Wine containers to provide multilingual text fallback without
        redistributing Microsoft Windows fonts.

        Fonts:
        \(files.map { "- \($0.displayName): \($0.sourceURL.absoluteString)" }.joined(separator: "\n"))

        License:
        \(licenseName)
        \(licenseURL.absoluteString)

        Keep the original font names intact. Do not sell these font files by themselves.
        See the upstream license for complete terms.
        """
        try Data(body.utf8).write(to: noticeURL, options: .atomic)
        return noticeURL
    }

    public static func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct OpenFontPackDownloader {
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func ensureFontPack(in cacheRoot: URL) async throws -> OpenFontPackDownloadResult {
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        var downloadedFonts: [String] = []
        var cachedFonts: [String] = []

        for font in OpenFontPackCatalog.files {
            let destination = cacheRoot.appendingPathComponent(font.fileName)
            if try cachedFontIsValid(destination, expectedSHA256: font.sha256) {
                cachedFonts.append(font.displayName)
                continue
            }

            try await download(font, to: destination)
            downloadedFonts.append(font.displayName)
        }

        let noticeURL = try OpenFontPackCatalog.writeNotice(to: cacheRoot, fileManager: fileManager)
        return OpenFontPackDownloadResult(
            downloadedFonts: downloadedFonts,
            cachedFonts: cachedFonts,
            noticePath: noticeURL.path
        )
    }

    private func cachedFontIsValid(_ url: URL, expectedSHA256: String) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        return try OpenFontPackCatalog.sha256Hex(for: url) == expectedSHA256
    }

    private func download(_ font: OpenFontFile, to destination: URL) async throws {
        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).download-\(UUID().uuidString)")
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let (downloadedURL, response) = try await URLSession.shared.download(from: font.sourceURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw OpenFontPackError.downloadFailed(font.displayName)
        }

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.moveItem(at: downloadedURL, to: temporaryURL)

        let digest = try OpenFontPackCatalog.sha256Hex(for: temporaryURL)
        guard digest == font.sha256 else {
            throw OpenFontPackError.checksumMismatch(font.displayName, expected: font.sha256, actual: digest)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        shouldRemoveTemporary = false
    }
}

public enum OpenFontPackError: LocalizedError, Equatable {
    case downloadFailed(String)
    case checksumMismatch(String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let fontName):
            return "Could not download \(fontName)."
        case .checksumMismatch(let fontName, let expected, let actual):
            return "\(fontName) checksum mismatch. Expected \(expected), got \(actual)."
        }
    }
}
