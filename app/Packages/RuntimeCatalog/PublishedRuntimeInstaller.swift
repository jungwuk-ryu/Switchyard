import CryptoKit
import Darwin
import Foundation
import Security

public struct PublishedRuntimePolicy: Sendable, Equatable {
    public var sourceRevision: String
    public var releaseManifestURL: URL
    public var developerTeamID: String
    public var archiveSha256: String
    public var archiveSize: UInt64
    public var notarizationID: String

    public init(
        sourceRevision: String,
        releaseManifestURL: URL,
        developerTeamID: String,
        archiveSha256: String,
        archiveSize: UInt64,
        notarizationID: String
    ) {
        self.sourceRevision = sourceRevision
        self.releaseManifestURL = releaseManifestURL
        self.developerTeamID = developerTeamID
        self.archiveSha256 = archiveSha256
        self.archiveSize = archiveSize
        self.notarizationID = notarizationID
    }
}

public struct PublishedRuntimeRelease: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var runtimeID: String
    public var sourceRevision: String
    public var archive: String
    public var archiveSha256: String
    public var archiveSize: UInt64
    public var platform: String
    public var hostArchitecture: String
    public var peArchitectures: [String]
    public var developerTeamID: String
    public var notarizationStatus: String
    public var notarizationID: String

    public init(
        schemaVersion: Int,
        runtimeID: String,
        sourceRevision: String,
        archive: String,
        archiveSha256: String,
        archiveSize: UInt64,
        platform: String,
        hostArchitecture: String,
        peArchitectures: [String],
        developerTeamID: String,
        notarizationStatus: String,
        notarizationID: String
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeID = runtimeID
        self.sourceRevision = sourceRevision
        self.archive = archive
        self.archiveSha256 = archiveSha256
        self.archiveSize = archiveSize
        self.platform = platform
        self.hostArchitecture = hostArchitecture
        self.peArchitectures = peArchitectures
        self.developerTeamID = developerTeamID
        self.notarizationStatus = notarizationStatus
        self.notarizationID = notarizationID
    }
}

public struct PublishedRuntimeInstallResult: Sendable, Equatable {
    public var runtimeID: String
    public var sourceRevision: String
    public var winePath: String

    public init(runtimeID: String, sourceRevision: String, winePath: String) {
        self.runtimeID = runtimeID
        self.sourceRevision = sourceRevision
        self.winePath = winePath
    }
}

public struct PublishedRuntimeInstaller: @unchecked Sendable {
    private static let maximumManifestSize = 64 * 1024
    private static let maximumArchiveSize: UInt64 = 4 * 1024 * 1024 * 1024
    private static let hardenedRuntimeFlag: UInt32 = 0x0001_0000

    private let fileManager: FileManager
    private let runtimeCacheRoot: URL
    private let session: URLSession

    public init(
        fileManager: FileManager = .default,
        runtimeCacheRoot: URL? = nil,
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.runtimeCacheRoot = runtimeCacheRoot
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".switchyard", isDirectory: true)
                .appendingPathComponent("runtimes", isDirectory: true)
        self.session = session
    }

    static func managedInstallationID(
        runtimeID: String,
        archiveSha256: String
    ) -> String {
        "\(runtimeID)-release-\(archiveSha256.prefix(16))"
    }

    public static func validate(release: PublishedRuntimeRelease, against policy: PublishedRuntimePolicy) throws {
        guard release.schemaVersion == 1 else {
            throw PublishedRuntimeInstallerError.unsupportedManifestVersion(release.schemaVersion)
        }
        guard policy.releaseManifestURL.scheme == "https",
              policy.releaseManifestURL.host?.lowercased() == "github.com",
              policy.releaseManifestURL.path.hasPrefix(
                "/jungwuk-ryu/switchyard-wine/releases/download/"
              ),
              policy.releaseManifestURL.lastPathComponent
                == "switchyard-runtime-release.json" else {
            throw PublishedRuntimeInstallerError.untrustedManifestURL
        }
        guard isSafeIdentifier(release.runtimeID) else {
            throw PublishedRuntimeInstallerError.invalidRuntimeID
        }
        guard isFullSHA(release.sourceRevision), release.sourceRevision == policy.sourceRevision else {
            throw PublishedRuntimeInstallerError.sourceRevisionMismatch
        }
        guard release.developerTeamID == policy.developerTeamID,
              release.developerTeamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw PublishedRuntimeInstallerError.developerTeamMismatch
        }
        guard release.platform == "macos", release.hostArchitecture == "x86_64" else {
            throw PublishedRuntimeInstallerError.unsupportedPlatform
        }
        guard Set(release.peArchitectures).isSuperset(of: ["i386", "x86_64"]) else {
            throw PublishedRuntimeInstallerError.incompleteRuntime
        }
        guard release.notarizationStatus == "Accepted",
              !policy.notarizationID.isEmpty,
              release.notarizationID == policy.notarizationID else {
            throw PublishedRuntimeInstallerError.notarizationMissing
        }
        guard release.archive == URL(fileURLWithPath: release.archive).lastPathComponent,
              !release.archive.hasPrefix("."),
              release.archive.lowercased().hasSuffix(".zip") else {
            throw PublishedRuntimeInstallerError.invalidArchiveName
        }
        guard policy.archiveSize > 0,
              policy.archiveSize <= maximumArchiveSize,
              release.archiveSize == policy.archiveSize else {
            throw PublishedRuntimeInstallerError.invalidArchiveSize
        }
        guard isSHA256(policy.archiveSha256),
              release.archiveSha256 == policy.archiveSha256 else {
            throw PublishedRuntimeInstallerError.invalidArchiveDigest
        }
    }

    public func install(policy: PublishedRuntimePolicy) async throws -> PublishedRuntimeInstallResult {
        try fileManager.createDirectory(at: runtimeCacheRoot, withIntermediateDirectories: true)
        let lockURL = runtimeCacheRoot.appendingPathComponent(".published-runtime-install.lock", isDirectory: false)
        let lockDescriptor = try acquireInstallLock(at: lockURL)
        defer { releaseInstallLock(lockDescriptor) }
        try removeAbandonedStagingDirectories()

        let (manifestData, manifestResponse) = try await session.data(from: policy.releaseManifestURL)
        try validateHTTPResponse(manifestResponse)
        guard manifestData.count <= Self.maximumManifestSize else {
            throw PublishedRuntimeInstallerError.manifestTooLarge
        }

        let release: PublishedRuntimeRelease
        do {
            release = try JSONDecoder().decode(PublishedRuntimeRelease.self, from: manifestData)
        } catch {
            throw PublishedRuntimeInstallerError.invalidManifest(error.localizedDescription)
        }
        try Self.validate(release: release, against: policy)

        let archiveURL = policy.releaseManifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(release.archive, isDirectory: false)
        let (downloadedArchive, archiveResponse) = try await session.download(from: archiveURL)
        try validateHTTPResponse(archiveResponse)

        let downloadedSize = try fileSize(at: downloadedArchive)
        guard downloadedSize == release.archiveSize else {
            throw PublishedRuntimeInstallerError.archiveSizeMismatch
        }
        guard try sha256(of: downloadedArchive) == release.archiveSha256 else {
            throw PublishedRuntimeInstallerError.archiveDigestMismatch
        }

        let stagingRoot = runtimeCacheRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let expectedRootName = String(release.archive.dropLast(".zip".count))
        try validateArchiveEntries(downloadedArchive, expectedRootName: expectedRootName)
        try extractArchive(downloadedArchive, to: stagingRoot)
        let extractedRuntime = try locateRuntimeRoot(under: stagingRoot)
        try validateExtractedRuntime(extractedRuntime, release: release, policy: policy)

        let destinationName = Self.managedInstallationID(
            runtimeID: release.runtimeID,
            archiveSha256: release.archiveSha256
        )
        let destination = runtimeCacheRoot.appendingPathComponent(destinationName, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            if try installedRuntimeMatches(destination, release: release, policy: policy) {
                return try result(for: destination, release: release)
            }
            throw PublishedRuntimeInstallerError.destinationConflict
        }
        try fileManager.moveItem(at: extractedRuntime, to: destination)

        return try result(for: destination, release: release)
    }

    private func acquireInstallLock(at lockURL: URL) throws -> Int32 {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: lockURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw PublishedRuntimeInstallerError.installAlreadyRunning
        }

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PublishedRuntimeInstallerError.installLockFailed(String(cString: strerror(errno)))
        }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let errorNumber = errno
            Darwin.close(descriptor)
            if errorNumber == EACCES || errorNumber == EAGAIN {
                throw PublishedRuntimeInstallerError.installAlreadyRunning
            }
            throw PublishedRuntimeInstallerError.installLockFailed(String(cString: strerror(errorNumber)))
        }
        return descriptor
    }

    private func releaseInstallLock(_ descriptor: Int32) {
        var lock = Darwin.flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        Darwin.close(descriptor)
    }

    private func removeAbandonedStagingDirectories() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: runtimeCacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(".install-") {
            try fileManager.removeItem(at: entry)
        }
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { return }
        guard (200 ... 299).contains(response.statusCode) else {
            throw PublishedRuntimeInstallerError.httpFailure(response.statusCode)
        }
    }

    private func validateExtractedRuntime(
        _ runtimeRoot: URL,
        release: PublishedRuntimeRelease,
        policy: PublishedRuntimePolicy
    ) throws {
        try validateNoEscapingSymbolicLinks(under: runtimeRoot)
        let manifest = try loadInstalledManifest(under: runtimeRoot)
        guard manifest.id == release.runtimeID,
              manifest.sourceRevision == policy.sourceRevision,
              manifest.sourceDirty == false,
              manifest.gptkPath?.isEmpty != false,
              manifest.gptkRedistDigest == "no-gptk",
              Set(manifest.peArchitectures ?? []).isSuperset(of: ["i386", "x86_64"]) else {
            throw PublishedRuntimeInstallerError.runtimeManifestMismatch
        }
        try validateContentTreeDigest(under: runtimeRoot)
        try validateMachOSignatures(under: runtimeRoot, teamID: policy.developerTeamID)
        _ = try result(for: runtimeRoot, release: release)
    }

    private func installedRuntimeMatches(
        _ runtimeRoot: URL,
        release: PublishedRuntimeRelease,
        policy: PublishedRuntimePolicy
    ) throws -> Bool {
        do {
            try validateExtractedRuntime(runtimeRoot, release: release, policy: policy)
            return true
        } catch {
            return false
        }
    }

    private func result(for runtimeRoot: URL, release: PublishedRuntimeRelease) throws -> PublishedRuntimeInstallResult {
        let candidates = ["bin/switchyard-wine", "bin/wine", "bin/wine64"]
        guard let executable = candidates
            .map({ runtimeRoot.appendingPathComponent($0) })
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw PublishedRuntimeInstallerError.wineExecutableMissing
        }
        return PublishedRuntimeInstallResult(
            runtimeID: release.runtimeID,
            sourceRevision: release.sourceRevision,
            winePath: executable.path
        )
    }

    private func locateRuntimeRoot(under stagingRoot: URL) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: stagingRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PublishedRuntimeInstallerError.runtimeRootMissing
        }

        var roots: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "switchyard-runtime.json" {
            roots.append(url.deletingLastPathComponent())
            enumerator.skipDescendants()
        }
        guard roots.count == 1 else {
            throw PublishedRuntimeInstallerError.runtimeRootMissing
        }
        return roots[0]
    }

    private func loadInstalledManifest(under runtimeRoot: URL) throws -> InstalledRuntimeManifest {
        do {
            let data = try Data(contentsOf: runtimeRoot.appendingPathComponent("switchyard-runtime.json"))
            return try JSONDecoder().decode(InstalledRuntimeManifest.self, from: data)
        } catch {
            throw PublishedRuntimeInstallerError.invalidInstalledManifest(error.localizedDescription)
        }
    }

    private func validateNoEscapingSymbolicLinks(under runtimeRoot: URL) throws {
        let rootPath = runtimeRoot.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: runtimeRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw PublishedRuntimeInstallerError.runtimeRootMissing
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            guard !target.hasPrefix("/") else {
                throw PublishedRuntimeInstallerError.escapingSymbolicLink
            }
            let resolved = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
                .standardizedFileURL.path
            guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
                throw PublishedRuntimeInstallerError.escapingSymbolicLink
            }
        }
    }

    private func validateContentTreeDigest(under runtimeRoot: URL) throws {
        let digestURL = runtimeRoot.appendingPathComponent(".switchyard-content-sha256")
        let expected = try String(contentsOf: digestURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSHA256(expected) else {
            throw PublishedRuntimeInstallerError.invalidContentDigest
        }

        guard let enumerator = fileManager.enumerator(
            at: runtimeRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw PublishedRuntimeInstallerError.runtimeRootMissing
        }

        var entries: [(path: String, line: String)] = []
        for case let url as URL in enumerator {
            let relativePath = String(url.path.dropFirst(runtimeRoot.path.count + 1))
            guard relativePath != ".switchyard-content-sha256" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                entries.append((relativePath, "link ./\(relativePath) \(target)\n"))
            } else if values.isRegularFile == true {
                entries.append((relativePath, "file ./\(relativePath) \(try sha256(of: url))\n"))
            }
        }

        entries.sort { lhs, rhs in
            lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
        let actual = Self.sha256(of: Data(entries.map(\.line).joined().utf8))
        guard actual == expected else {
            throw PublishedRuntimeInstallerError.contentDigestMismatch
        }
    }

    private func validateMachOSignatures(under runtimeRoot: URL, teamID: String) throws {
        guard let requirement = signingRequirement(teamID: teamID) else {
            throw PublishedRuntimeInstallerError.invalidSigningRequirement
        }
        guard let enumerator = fileManager.enumerator(
            at: runtimeRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw PublishedRuntimeInstallerError.runtimeRootMissing
        }

        var machOCount = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, try isMachO(url) else { continue }
            machOCount += 1
            try validateMachOSignature(at: url, teamID: teamID, requirement: requirement)
        }
        guard machOCount > 0 else {
            throw PublishedRuntimeInstallerError.machOMissing
        }
    }

    private func signingRequirement(teamID: String) -> SecRequirement? {
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement)
        return status == errSecSuccess ? requirement : nil
    }

    private func validateMachOSignature(at url: URL, teamID: String, requirement: SecRequirement) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else {
            throw PublishedRuntimeInstallerError.invalidCodeSignature(url.lastPathComponent)
        }
        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, validationFlags, requirement) == errSecSuccess else {
            throw PublishedRuntimeInstallerError.invalidCodeSignature(url.lastPathComponent)
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        information[kSecCodeInfoTeamIdentifier as String] as? String == teamID,
        let flags = information[kSecCodeInfoFlags as String] as? NSNumber,
        flags.uint32Value & Self.hardenedRuntimeFlag != 0 else {
            throw PublishedRuntimeInstallerError.invalidCodeSignature(url.lastPathComponent)
        }
    }

    private func isMachO(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4), data.count == 4 else { return false }
        let bytes = Array(data)
        let magics: [[UInt8]] = [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]
        ]
        return magics.contains(bytes)
    }

    private func extractArchive(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorText = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )
            let message = errorText?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? String(localized: "ditto failed", bundle: SwitchyardStrings.bundle)
            throw PublishedRuntimeInstallerError.archiveExtractionFailed(message)
        }
    }

    private func validateArchiveEntries(_ archive: URL, expectedRootName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archive.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let listing = String(data: output, encoding: .utf8) else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? String(localized: "zipinfo failed", bundle: SwitchyardStrings.bundle)
            throw PublishedRuntimeInstallerError.archiveInspectionFailed(message)
        }

        var containsRuntimeRoot = false
        for entry in listing.split(whereSeparator: { $0.isNewline }).map(String.init) {
            guard !entry.hasPrefix("/"), !entry.contains("\\") else {
                throw PublishedRuntimeInstallerError.unsafeArchiveEntry(entry)
            }
            let components = entry.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty,
                  !components.contains("."),
                  !components.contains("..") else {
                throw PublishedRuntimeInstallerError.unsafeArchiveEntry(entry)
            }
            if components[0] == expectedRootName {
                containsRuntimeRoot = true
            } else if components[0] == "__MACOSX" {
                guard components.count == 1 || components[1] == expectedRootName else {
                    throw PublishedRuntimeInstallerError.unsafeArchiveEntry(entry)
                }
            } else {
                throw PublishedRuntimeInstallerError.unsafeArchiveEntry(entry)
            }
        }
        guard containsRuntimeRoot else {
            throw PublishedRuntimeInstallerError.runtimeRootMissing
        }
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw PublishedRuntimeInstallerError.invalidArchiveSize
        }
        return UInt64(size)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func isFullSHA(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}

private struct InstalledRuntimeManifest: Decodable {
    var id: String?
    var sourceRevision: String?
    var sourceDirty: Bool?
    var peArchitectures: [String]?
    var gptkPath: String?
    var gptkRedistDigest: String?
}

private enum PublishedRuntimeInstallerError: LocalizedError {
    case archiveDigestMismatch
    case archiveExtractionFailed(String)
    case archiveInspectionFailed(String)
    case archiveSizeMismatch
    case contentDigestMismatch
    case developerTeamMismatch
    case destinationConflict
    case escapingSymbolicLink
    case httpFailure(Int)
    case incompleteRuntime
    case installAlreadyRunning
    case installLockFailed(String)
    case invalidArchiveDigest
    case invalidArchiveName
    case invalidArchiveSize
    case invalidCodeSignature(String)
    case invalidContentDigest
    case invalidInstalledManifest(String)
    case invalidManifest(String)
    case invalidRuntimeID
    case invalidSigningRequirement
    case machOMissing
    case manifestTooLarge
    case notarizationMissing
    case runtimeManifestMismatch
    case runtimeRootMissing
    case sourceRevisionMismatch
    case unsupportedManifestVersion(Int)
    case unsupportedPlatform
    case untrustedManifestURL
    case unsafeArchiveEntry(String)
    case wineExecutableMissing

    var errorDescription: String? {
        switch self {
        case .archiveDigestMismatch:
            String(
                localized: "The downloaded runtime checksum does not match its release manifest.",
                bundle: SwitchyardStrings.bundle
            )
        case .archiveExtractionFailed(let message):
            String(
                localized: "The runtime archive could not be extracted: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        case .archiveInspectionFailed(let message):
            String(
                localized: "The runtime archive could not be inspected safely: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        case .archiveSizeMismatch:
            String(
                localized: "The downloaded runtime size does not match its release manifest.",
                bundle: SwitchyardStrings.bundle
            )
        case .contentDigestMismatch:
            String(localized: "The extracted runtime content digest is invalid.", bundle: SwitchyardStrings.bundle)
        case .developerTeamMismatch:
            String(
                localized: "The runtime release was not produced by the expected developer team.",
                bundle: SwitchyardStrings.bundle
            )
        case .destinationConflict:
            String(
                localized: "A different runtime already exists at the immutable release destination.",
                bundle: SwitchyardStrings.bundle
            )
        case .escapingSymbolicLink:
            String(
                localized: "The runtime archive contains a symbolic link outside its installation directory.",
                bundle: SwitchyardStrings.bundle
            )
        case .httpFailure(let status):
            String(
                localized: "The runtime download server returned HTTP \(status).",
                bundle: SwitchyardStrings.bundle
            )
        case .incompleteRuntime:
            String(
                localized: "The runtime does not include both 32-bit and 64-bit Windows support.",
                bundle: SwitchyardStrings.bundle
            )
        case .installAlreadyRunning:
            String(localized: "Another runtime installation is already in progress.", bundle: SwitchyardStrings.bundle)
        case .installLockFailed(let message):
            String(
                localized: "The runtime installation lock could not be acquired: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidArchiveDigest:
            String(
                localized: "The runtime release manifest has an invalid archive checksum.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidArchiveName:
            String(
                localized: "The runtime release manifest has an unsafe archive name.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidArchiveSize:
            String(
                localized: "The runtime release manifest has an invalid archive size.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidCodeSignature(let name):
            String(
                localized: "The runtime code signature is invalid for \(name).",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidContentDigest:
            String(localized: "The runtime has no valid full-content digest.", bundle: SwitchyardStrings.bundle)
        case .invalidInstalledManifest(let message):
            String(
                localized: "The installed runtime manifest is invalid: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidManifest(let message):
            String(
                localized: "The runtime release manifest is invalid: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidRuntimeID:
            String(localized: "The runtime release has an unsafe identifier.", bundle: SwitchyardStrings.bundle)
        case .invalidSigningRequirement:
            String(
                localized: "The expected Developer ID signing requirement is invalid.",
                bundle: SwitchyardStrings.bundle
            )
        case .machOMissing:
            String(
                localized: "The runtime archive contains no signed macOS executable code.",
                bundle: SwitchyardStrings.bundle
            )
        case .manifestTooLarge:
            String(localized: "The runtime release manifest is unexpectedly large.", bundle: SwitchyardStrings.bundle)
        case .notarizationMissing:
            String(
                localized: "The runtime release has not been accepted by Apple notarization.",
                bundle: SwitchyardStrings.bundle
            )
        case .runtimeManifestMismatch:
            String(
                localized: "The extracted runtime does not match the requested release.",
                bundle: SwitchyardStrings.bundle
            )
        case .runtimeRootMissing:
            String(
                localized: "The archive does not contain exactly one Switchyard runtime.",
                bundle: SwitchyardStrings.bundle
            )
        case .sourceRevisionMismatch:
            String(
                localized: "The runtime release does not match this app's compatible source revision.",
                bundle: SwitchyardStrings.bundle
            )
        case .unsupportedManifestVersion(let version):
            String(
                localized: "Runtime release manifest version \(version) is unsupported.",
                bundle: SwitchyardStrings.bundle
            )
        case .unsupportedPlatform:
            String(
                localized: "The runtime release is not the supported x86_64 macOS build.",
                bundle: SwitchyardStrings.bundle
            )
        case .untrustedManifestURL:
            String(
                localized: "The runtime release manifest must be an official switchyard-wine GitHub release asset.",
                bundle: SwitchyardStrings.bundle
            )
        case .unsafeArchiveEntry(let entry):
            String(
                localized: "The runtime archive contains an unsafe entry: \(entry)",
                bundle: SwitchyardStrings.bundle
            )
        case .wineExecutableMissing:
            String(localized: "The installed runtime has no runnable Wine launcher.", bundle: SwitchyardStrings.bundle)
        }
    }
}
