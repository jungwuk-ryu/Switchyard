import AppCore
import CryptoKit
import Darwin
import Foundation
import RuntimeCatalog

public struct ContainerFontInstallResult: Codable, Equatable, Sendable {
    public var installedFonts: [String]
    public var reusedFonts: [String]
    public var registeredFontEntries: Int
    public var registeredReplacements: Int
    public var skippedReason: String?

    public init(
        installedFonts: [String],
        reusedFonts: [String],
        registeredFontEntries: Int,
        registeredReplacements: Int,
        skippedReason: String? = nil
    ) {
        self.installedFonts = installedFonts
        self.reusedFonts = reusedFonts
        self.registeredFontEntries = registeredFontEntries
        self.registeredReplacements = registeredReplacements
        self.skippedReason = skippedReason
    }

    public var summary: String {
        if let skippedReason {
            return String(
                localized: "Open fonts skipped: \(skippedReason)",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Open fonts ready: \(installedFonts.count) copied, \(reusedFonts.count) already present, \(registeredReplacements) family replacements registered.",
            bundle: SwitchyardStrings.bundle
        )
    }
}

public enum ContainerFontInstallerError: LocalizedError, Equatable {
    case missingCachedFont(String, String)
    case invalidCachedFont(String, expected: String, actual: String)
    case invalidContainerPath(String)
    case unsafeFileSystemEntry(String)
    case registryReadFailed(String, code: Int32)
    case invalidRegistryEncoding(String)
    case registryChanged(String)
    case registryWriteFailed(String, code: Int32)
    case registryTransactionFailed(String)
    case registryRecoveryFailed(transaction: String, recovery: String)

    public var errorDescription: String? {
        switch self {
        case .missingCachedFont(let fontName, let path):
            return String(
                localized: "\(fontName) is missing from the Open Font Pack cache: \(path)",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidCachedFont(let fontName, let expected, let actual):
            return String(
                localized: "\(fontName) in the Open Font Pack cache failed checksum validation. Expected \(expected), got \(actual).",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidContainerPath(let path):
            return String(
                localized: "Container path is empty or invalid: \(path)",
                bundle: SwitchyardStrings.bundle
            )
        case .unsafeFileSystemEntry(let path):
            return String(
                localized: "Open Font Pack installation refused an unsafe file-system entry: \(path)",
                bundle: SwitchyardStrings.bundle
            )
        case .registryReadFailed(let path, let code):
            return String(
                localized: "The Wine registry could not be read safely at \(path) (error \(code)).",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidRegistryEncoding(let path):
            return String(
                localized: "The Wine registry is not valid UTF-8 and was left unchanged: \(path)",
                bundle: SwitchyardStrings.bundle
            )
        case .registryChanged(let path):
            return String(
                localized: "The Wine registry changed during font installation and was left unchanged: \(path)",
                bundle: SwitchyardStrings.bundle
            )
        case .registryWriteFailed(let path, let code):
            return String(
                localized: "The Wine registry update could not be committed at \(path) (error \(code)).",
                bundle: SwitchyardStrings.bundle
            )
        case .registryTransactionFailed(let message):
            return String(
                localized: "The Wine registry transaction failed: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        case .registryRecoveryFailed(let transaction, let recovery):
            return String(
                localized: "The Wine registry transaction failed (\(transaction)), and recovery also failed (\(recovery)).",
                bundle: SwitchyardStrings.bundle
            )
        }
    }
}

enum ContainerFontInstallerFailurePoint: Equatable, Sendable {
    case beforeSystemRegistryRead
    case beforeUserRegistryRead
    case beforeUserRegistryStaging
    case beforeOriginalRegistryValidation
    case beforeFirstRegistryReplacement
    case afterFirstRegistryReplacement
    case beforeSecondRegistryReplacement
    case afterSecondRegistryReplacement
    case beforeSystemRegistryRollback
    case beforeUserRegistryRollback
}

public struct ContainerFontInstaller {
    public var fileManager: FileManager
    public var catalog: [OpenFontFile]
    public var replacements: [FontReplacement]
    public var lockAcquisitionTimeout: Duration
    private var failureInjector:
        @Sendable (ContainerFontInstallerFailurePoint) throws -> Void

    public init(
        fileManager: FileManager = .default,
        catalog: [OpenFontFile] = OpenFontPackCatalog.files,
        replacements: [FontReplacement] = OpenFontPackCatalog.replacements,
        lockAcquisitionTimeout: Duration = .seconds(10)
    ) {
        self.fileManager = fileManager
        self.catalog = catalog
        self.replacements = replacements
        self.lockAcquisitionTimeout = lockAcquisitionTimeout
        self.failureInjector = { _ in }
    }

    init(
        fileManager: FileManager = .default,
        catalog: [OpenFontFile] = OpenFontPackCatalog.files,
        replacements: [FontReplacement] = OpenFontPackCatalog.replacements,
        lockAcquisitionTimeout: Duration = .seconds(10),
        failureInjector:
            @escaping @Sendable (ContainerFontInstallerFailurePoint) throws -> Void
    ) {
        self.fileManager = fileManager
        self.catalog = catalog
        self.replacements = replacements
        self.lockAcquisitionTimeout = lockAcquisitionTimeout
        self.failureInjector = failureInjector
    }

    public func installOpenFontPack(into container: Container, from fontCacheRoot: URL) throws -> ContainerFontInstallResult {
        let containerPath = container.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerPath.isEmpty,
              containerPath.first == "/",
              !containerPath.utf8.contains(0) else {
            throw ContainerFontInstallerError.invalidContainerPath(container.path)
        }

        let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        let containerDirectory = try openAbsoluteDirectory(
            at: containerURL,
            invalidPathError: .invalidContainerPath(container.path)
        )
        defer { Darwin.close(containerDirectory.descriptor) }

        let prefixLock = try WinePrefixFileLock(
            prefixPath: containerURL.path,
            mode: .exclusive,
            acquisitionTimeout: lockAcquisitionTimeout
        )
        defer { prefixLock.unlock() }
        try verifyPinnedDirectory(containerDirectory)

        try failureInjector(.beforeSystemRegistryRead)
        let systemRegistry = try WineRegistryFile.read(
            named: "system.reg",
            in: containerDirectory.descriptor,
            directoryPath: containerDirectory.path
        )
        try failureInjector(.beforeUserRegistryRead)
        let userRegistry = try WineRegistryFile.read(
            named: "user.reg",
            in: containerDirectory.descriptor,
            directoryPath: containerDirectory.path
        )
        guard let systemRegistry,
              let userRegistry,
              systemRegistry.hasArchitectureMarker,
              userRegistry.hasArchitectureMarker else {
            return ContainerFontInstallResult(
                installedFonts: [],
                reusedFonts: [],
                registeredFontEntries: 0,
                registeredReplacements: 0,
                skippedReason: String(
                    localized: "Wine has not initialized this container yet.",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }

        let cacheDirectory: OpenedDirectory?
        if catalog.isEmpty {
            cacheDirectory = nil
        } else {
            cacheDirectory = try openAbsoluteDirectory(
                at: fontCacheRoot,
                invalidPathError: .unsafeFileSystemEntry(fontCacheRoot.path)
            )
        }
        defer {
            if let cacheDirectory {
                Darwin.close(cacheDirectory.descriptor)
            }
        }

        let fontsComponents = ["drive_c", "windows", "Fonts"]
        let fontsDirectory = try openRelativeDirectory(
            components: fontsComponents,
            beneath: containerDirectory.descriptor,
            displayRoot: containerDirectory.path,
            createMissing: true
        )
        defer { Darwin.close(fontsDirectory.descriptor) }

        var installedFonts: [String] = []
        var reusedFonts: [String] = []
        var fontRegistryValues: [String: String] = [:]

        for font in catalog {
            guard isSinglePathComponent(font.fileName),
                  let cacheDirectory else {
                throw ContainerFontInstallerError.unsafeFileSystemEntry(
                    fontCacheRoot.appendingPathComponent(font.fileName).path
                )
            }

            let sourceURL = fontCacheRoot.appendingPathComponent(font.fileName)
            let source = try openSourceFont(
                named: font.fileName,
                displayName: font.displayName,
                in: cacheDirectory.descriptor,
                displayPath: sourceURL.path
            )
            defer { Darwin.close(source.descriptor) }

            let sourceDigest = try hashFileDescriptor(source.descriptor)
            try verifySourceFont(
                source,
                named: font.fileName,
                in: cacheDirectory.descriptor,
                displayPath: sourceURL.path
            )
            try verifyPinnedDirectory(cacheDirectory)
            guard sourceDigest == font.sha256 else {
                throw ContainerFontInstallerError.invalidCachedFont(font.displayName, expected: font.sha256, actual: sourceDigest)
            }

            let destinationPath = URL(fileURLWithPath: fontsDirectory.path, isDirectory: true)
                .appendingPathComponent(font.fileName)
                .path
            if try cachedFont(
                named: font.fileName,
                in: fontsDirectory.descriptor,
                displayPath: destinationPath,
                matchesSHA256: font.sha256
            ) {
                try verifyPinnedHierarchy(
                    root: containerDirectory,
                    relativeComponents: fontsComponents,
                    expectedDirectory: fontsDirectory
                )
                reusedFonts.append(font.displayName)
            } else {
                try installFontAtomically(
                    source: source,
                    sourceName: font.fileName,
                    sourceDisplayName: font.displayName,
                    sourceDirectory: cacheDirectory,
                    destinationName: font.fileName,
                    destinationDirectory: fontsDirectory,
                    containerDirectory: containerDirectory,
                    fontsComponents: fontsComponents,
                    expectedSHA256: font.sha256,
                    displayPath: destinationPath
                )
                installedFonts.append(font.displayName)
            }

            for entry in font.registryEntries {
                fontRegistryValues[entry] = font.fileName
            }
        }

        let replacementValues = Dictionary(
            uniqueKeysWithValues: replacements.map { ($0.requestedFamily, $0.replacementFamily) }
        )

        try registerFonts(
            containerDirectory: containerDirectory,
            systemRegistry: systemRegistry,
            userRegistry: userRegistry,
            fontValues: fontRegistryValues,
            replacementValues: replacementValues
        )

        return ContainerFontInstallResult(
            installedFonts: installedFonts,
            reusedFonts: reusedFonts,
            registeredFontEntries: fontRegistryValues.count,
            registeredReplacements: replacementValues.count
        )
    }

    private func cachedFont(
        named name: String,
        in directoryDescriptor: Int32,
        displayPath: String,
        matchesSHA256 expectedSHA256: String
    ) throws -> Bool {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            let openError = errno
            if openError == ENOENT {
                return false
            }
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayPath)
        }
        defer { Darwin.close(descriptor) }

        let opened = try verifiedRegularFile(
            descriptor: descriptor,
            named: name,
            in: directoryDescriptor,
            displayPath: displayPath
        )
        let digest = try hashFileDescriptor(descriptor)
        try verifyRegularFile(
            descriptor: descriptor,
            initialStatus: opened,
            named: name,
            in: directoryDescriptor,
            displayPath: displayPath
        )
        return digest == expectedSHA256
    }

    private func installFontAtomically(
        source: OpenedRegularFile,
        sourceName: String,
        sourceDisplayName: String,
        sourceDirectory: OpenedDirectory,
        destinationName: String,
        destinationDirectory: OpenedDirectory,
        containerDirectory: OpenedDirectory,
        fontsComponents: [String],
        expectedSHA256: String,
        displayPath: String
    ) throws {
        guard Darwin.lseek(source.descriptor, 0, SEEK_SET) == 0 else {
            throw posixError(path: source.path, code: errno)
        }

        let temporary = try createTemporaryFont(
            in: destinationDirectory.descriptor,
            displayRoot: destinationDirectory.path
        )
        var temporaryExists = true
        defer {
            if temporaryExists {
                unlinkIfSameFile(
                    temporary,
                    in: destinationDirectory.descriptor
                )
            }
        }

        let temporaryPath = URL(
            fileURLWithPath: destinationDirectory.path,
            isDirectory: true
        ).appendingPathComponent(temporary.name).path
        defer { Darwin.close(temporary.descriptor) }

        let copiedDigest = try copyAndHash(
            from: source.descriptor,
            to: temporary.descriptor,
            sourcePath: source.path,
            destinationPath: temporaryPath
        )
        guard copiedDigest == expectedSHA256 else {
            throw ContainerFontInstallerError.invalidCachedFont(
                sourceDisplayName,
                expected: expectedSHA256,
                actual: copiedDigest
            )
        }
        guard Darwin.fchmod(
            temporary.descriptor,
            mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        ) == 0 else {
            throw posixError(path: temporaryPath, code: errno)
        }
        guard Darwin.fsync(temporary.descriptor) == 0 else {
            throw posixError(path: temporaryPath, code: errno)
        }

        let storedDigest = try hashFileDescriptor(temporary.descriptor)
        guard storedDigest == expectedSHA256 else {
            throw ContainerFontInstallerError.invalidCachedFont(
                sourceDisplayName,
                expected: expectedSHA256,
                actual: storedDigest
            )
        }
        let storedStatus = try verifiedRegularFile(
            descriptor: temporary.descriptor,
            named: temporary.name,
            in: destinationDirectory.descriptor,
            displayPath: temporaryPath
        )
        guard sameFile(temporary.initialStatus, storedStatus) else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(temporaryPath)
        }

        try verifySourceFont(
            source,
            named: sourceName,
            in: sourceDirectory.descriptor,
            displayPath: source.path
        )
        try verifyPinnedDirectory(sourceDirectory)
        try verifyPinnedHierarchy(
            root: containerDirectory,
            relativeComponents: fontsComponents,
            expectedDirectory: destinationDirectory
        )
        try verifyTemporaryRegularFile(
            descriptor: temporary.descriptor,
            storedStatus: storedStatus,
            named: temporary.name,
            in: destinationDirectory.descriptor,
            displayPath: temporaryPath
        )
        try verifyReplaceableDestination(
            named: destinationName,
            in: destinationDirectory.descriptor,
            displayPath: displayPath
        )

        let renameResult = temporary.name.withCString { temporaryNamePointer in
            destinationName.withCString { destinationNamePointer in
                Darwin.renameat(
                    destinationDirectory.descriptor,
                    temporaryNamePointer,
                    destinationDirectory.descriptor,
                    destinationNamePointer
                )
            }
        }
        guard renameResult == 0 else {
            throw posixError(path: displayPath, code: errno)
        }
        temporaryExists = false
        _ = Darwin.fsync(destinationDirectory.descriptor)
    }

    private func createTemporaryFont(
        in directoryDescriptor: Int32,
        displayRoot: String
    ) throws -> OpenedTemporaryFile {
        for _ in 0..<32 {
            let name = ".switchyard-font-\(UUID().uuidString).tmp"
            let descriptor = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor >= 0 {
                do {
                    let initialStatus = try verifiedRegularFile(
                        descriptor: descriptor,
                        named: name,
                        in: directoryDescriptor,
                        displayPath: URL(
                            fileURLWithPath: displayRoot,
                            isDirectory: true
                        ).appendingPathComponent(name).path
                    )
                    return OpenedTemporaryFile(
                        descriptor: descriptor,
                        name: name,
                        initialStatus: initialStatus
                    )
                } catch {
                    var openedStatus = stat()
                    if Darwin.fstat(descriptor, &openedStatus) == 0 {
                        unlinkIfSameFile(
                            OpenedTemporaryFile(
                                descriptor: descriptor,
                                name: name,
                                initialStatus: openedStatus
                            ),
                            in: directoryDescriptor
                        )
                    }
                    Darwin.close(descriptor)
                    throw error
                }
            }
            let openError = errno
            if openError != EEXIST {
                throw posixError(path: displayRoot, code: openError)
            }
        }
        throw posixError(path: displayRoot, code: EEXIST)
    }

    private func openSourceFont(
        named name: String,
        displayName: String,
        in directoryDescriptor: Int32,
        displayPath: String
    ) throws -> OpenedRegularFile {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            let openError = errno
            if openError == ENOENT {
                throw ContainerFontInstallerError.missingCachedFont(displayName, displayPath)
            }
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayPath)
        }

        do {
            let status = try verifiedRegularFile(
                descriptor: descriptor,
                named: name,
                in: directoryDescriptor,
                displayPath: displayPath
            )
            return OpenedRegularFile(
                descriptor: descriptor,
                path: displayPath,
                initialStatus: status
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openAbsoluteDirectory(
        at url: URL,
        invalidPathError: ContainerFontInstallerError
    ) throws -> OpenedDirectory {
        guard url.isFileURL,
              url.path.first == "/",
              !url.path.utf8.contains(0) else {
            throw invalidPathError
        }

        let components = url.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard components.allSatisfy(isSinglePathComponent) else {
            throw invalidPathError
        }

        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw posixError(path: "/", code: errno)
        }

        var traversedPath = ""
        do {
            for component in components {
                traversedPath += "/\(component)"
                let nextDescriptor = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard nextDescriptor >= 0 else {
                    throw ContainerFontInstallerError.unsafeFileSystemEntry(traversedPath)
                }
                let isVerifiedDirectory: Bool
                do {
                    isVerifiedDirectory = try verifiedDirectory(
                        descriptor: nextDescriptor,
                        named: component,
                        in: descriptor,
                        displayPath: traversedPath
                    )
                } catch {
                    Darwin.close(nextDescriptor)
                    throw error
                }
                guard isVerifiedDirectory else {
                    Darwin.close(nextDescriptor)
                    throw ContainerFontInstallerError.unsafeFileSystemEntry(
                        traversedPath
                    )
                }
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }

            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  isDirectory(status) else {
                throw ContainerFontInstallerError.unsafeFileSystemEntry(url.path)
            }
            return OpenedDirectory(
                descriptor: descriptor,
                path: url.path,
                identity: FileIdentity(status)
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openRelativeDirectory(
        components: [String],
        beneath rootDescriptor: Int32,
        displayRoot: String,
        createMissing: Bool
    ) throws -> OpenedDirectory {
        guard components.allSatisfy(isSinglePathComponent) else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayRoot)
        }
        let duplicatedRoot = Darwin.dup(rootDescriptor)
        guard duplicatedRoot >= 0 else {
            throw posixError(path: displayRoot, code: errno)
        }

        var descriptor = duplicatedRoot
        var traversedPath = displayRoot
        do {
            for component in components {
                traversedPath = URL(
                    fileURLWithPath: traversedPath,
                    isDirectory: true
                ).appendingPathComponent(component, isDirectory: true).path

                var nextDescriptor = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                if nextDescriptor < 0, errno == ENOENT, createMissing {
                    let creationResult = component.withCString {
                        Darwin.mkdirat(
                            descriptor,
                            $0,
                            mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
                        )
                    }
                    if creationResult != 0, errno != EEXIST {
                        throw posixError(path: traversedPath, code: errno)
                    }
                    nextDescriptor = component.withCString {
                        Darwin.openat(
                            descriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                        )
                    }
                }
                guard nextDescriptor >= 0 else {
                    throw ContainerFontInstallerError.unsafeFileSystemEntry(traversedPath)
                }
                let isVerifiedDirectory: Bool
                do {
                    isVerifiedDirectory = try verifiedDirectory(
                        descriptor: nextDescriptor,
                        named: component,
                        in: descriptor,
                        displayPath: traversedPath
                    )
                } catch {
                    Darwin.close(nextDescriptor)
                    throw error
                }
                guard isVerifiedDirectory else {
                    Darwin.close(nextDescriptor)
                    throw ContainerFontInstallerError.unsafeFileSystemEntry(
                        traversedPath
                    )
                }
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }

            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  isDirectory(status) else {
                throw ContainerFontInstallerError.unsafeFileSystemEntry(traversedPath)
            }
            return OpenedDirectory(
                descriptor: descriptor,
                path: traversedPath,
                identity: FileIdentity(status)
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func verifyPinnedDirectory(_ directory: OpenedDirectory) throws {
        let reopened = try openAbsoluteDirectory(
            at: URL(fileURLWithPath: directory.path, isDirectory: true),
            invalidPathError: .unsafeFileSystemEntry(directory.path)
        )
        defer { Darwin.close(reopened.descriptor) }
        guard reopened.identity == directory.identity else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(directory.path)
        }
    }

    private func verifyPinnedHierarchy(
        root: OpenedDirectory,
        relativeComponents: [String],
        expectedDirectory: OpenedDirectory
    ) throws {
        let reopenedRoot = try openAbsoluteDirectory(
            at: URL(fileURLWithPath: root.path, isDirectory: true),
            invalidPathError: .unsafeFileSystemEntry(root.path)
        )
        defer { Darwin.close(reopenedRoot.descriptor) }
        guard reopenedRoot.identity == root.identity else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(root.path)
        }

        let reopenedDirectory = try openRelativeDirectory(
            components: relativeComponents,
            beneath: reopenedRoot.descriptor,
            displayRoot: reopenedRoot.path,
            createMissing: false
        )
        defer { Darwin.close(reopenedDirectory.descriptor) }
        guard reopenedDirectory.identity == expectedDirectory.identity else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(expectedDirectory.path)
        }
    }

    private func verifiedDirectory(
        descriptor: Int32,
        named name: String,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws -> Bool {
        var descriptorStatus = stat()
        var entryStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw posixError(path: displayPath, code: errno)
        }
        let statusResult = name.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &entryStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard statusResult == 0 else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayPath)
        }
        return isDirectory(descriptorStatus)
            && isDirectory(entryStatus)
            && sameFile(descriptorStatus, entryStatus)
    }

    private func verifiedRegularFile(
        descriptor: Int32,
        named name: String,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws -> stat {
        var descriptorStatus = stat()
        var entryStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw posixError(path: displayPath, code: errno)
        }
        let statusResult = name.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &entryStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard statusResult == 0,
              isSingleLinkRegularFile(descriptorStatus),
              isSingleLinkRegularFile(entryStatus),
              sameFile(descriptorStatus, entryStatus) else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayPath)
        }
        return descriptorStatus
    }

    private func verifyRegularFile(
        descriptor: Int32,
        initialStatus: stat,
        named name: String,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws {
        let finalStatus = try verifiedRegularFile(
            descriptor: descriptor,
            named: name,
            in: parentDescriptor,
            displayPath: displayPath
        )
        guard stableFile(initialStatus, finalStatus) else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayPath)
        }
    }

    private func verifySourceFont(
        _ source: OpenedRegularFile,
        named name: String,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws {
        try verifyRegularFile(
            descriptor: source.descriptor,
            initialStatus: source.initialStatus,
            named: name,
            in: parentDescriptor,
            displayPath: displayPath
        )
    }

    private func verifyTemporaryRegularFile(
        descriptor: Int32,
        storedStatus: stat,
        named name: String,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws {
        let finalStatus = try verifiedRegularFile(
            descriptor: descriptor,
            named: name,
            in: parentDescriptor,
            displayPath: displayPath
        )
        guard stableFile(storedStatus, finalStatus) else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayPath)
        }
    }

    private func unlinkIfSameFile(
        _ temporary: OpenedTemporaryFile,
        in parentDescriptor: Int32
    ) {
        var descriptorStatus = stat()
        var entryStatus = stat()
        guard Darwin.fstat(temporary.descriptor, &descriptorStatus) == 0,
              sameFile(temporary.initialStatus, descriptorStatus),
              temporary.name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &entryStatus,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0
              }),
              sameFile(descriptorStatus, entryStatus) else {
            return
        }
        _ = temporary.name.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
    }

    private func verifyReplaceableDestination(
        named name: String,
        in parentDescriptor: Int32,
        displayPath: String
    ) throws {
        var entryStatus = stat()
        let result = name.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &entryStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0 {
            let statusError = errno
            if statusError == ENOENT {
                return
            }
            throw posixError(path: displayPath, code: statusError)
        }
        guard isSingleLinkRegularFile(entryStatus) else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(displayPath)
        }
    }

    private func hashFileDescriptor(_ descriptor: Int32) throws -> String {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw posixError(path: "font descriptor", code: errno)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if bytesRead > 0 {
                buffer.withUnsafeBytes { bytes in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(
                        start: bytes.baseAddress,
                        count: bytesRead
                    ))
                }
                continue
            }
            if bytesRead == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw posixError(path: "font descriptor", code: errno)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyAndHash(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        sourcePath: String,
        destinationPath: String
    ) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if bytesRead > 0 {
                try buffer.withUnsafeBytes { bytes in
                    let chunk = UnsafeRawBufferPointer(
                        start: bytes.baseAddress,
                        count: bytesRead
                    )
                    hasher.update(bufferPointer: chunk)
                    var writtenBytes = 0
                    while writtenBytes < bytesRead {
                        let result = Darwin.write(
                            destinationDescriptor,
                            chunk.baseAddress?.advanced(by: writtenBytes),
                            bytesRead - writtenBytes
                        )
                        if result > 0 {
                            writtenBytes += result
                        } else if result < 0, errno == EINTR {
                            continue
                        } else {
                            throw posixError(path: destinationPath, code: errno)
                        }
                    }
                }
                continue
            }
            if bytesRead == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw posixError(path: sourcePath, code: errno)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.utf8.contains(0)
    }

    private func isDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
    }

    private func isSingleLinkRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG && status.st_nlink == 1
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func stableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFile(lhs, rhs)
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func posixError(path: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private struct OpenedDirectory {
        var descriptor: Int32
        var path: String
        var identity: FileIdentity
    }

    private struct OpenedRegularFile {
        var descriptor: Int32
        var path: String
        var initialStatus: stat
    }

    private struct OpenedTemporaryFile {
        var descriptor: Int32
        var name: String
        var initialStatus: stat
    }

    private struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t

        init(_ status: stat) {
            self.device = status.st_dev
            self.inode = status.st_ino
        }
    }

    private func registerFonts(
        containerDirectory: OpenedDirectory,
        systemRegistry originalSystemRegistry: WineRegistryFile,
        userRegistry originalUserRegistry: WineRegistryFile,
        fontValues: [String: String],
        replacementValues: [String: String]
    ) throws {
        var systemRegistry = originalSystemRegistry
        for section in [
            "Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts",
            "Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Fonts",
            "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts",
            "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Fonts"
        ] {
            systemRegistry.upsertStringValues(fontValues, in: section)
        }
        for section in [
            "Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes",
            "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\FontSubstitutes"
        ] {
            systemRegistry.upsertStringValues(replacementValues, in: section)
        }

        var userRegistry = originalUserRegistry
        userRegistry.upsertStringValues(replacementValues, in: "Software\\\\Wine\\\\Fonts\\\\Replacements")
        try WineRegistryTransaction(
            directoryDescriptor: containerDirectory.descriptor,
            directoryPath: containerDirectory.path,
            failureInjector: failureInjector
        ).commit(
            systemRegistry: systemRegistry,
            userRegistry: userRegistry
        )
    }
}

private struct WineRegistryFile {
    static let maximumByteCount = 16 * 1_024 * 1_024

    var name: String
    var path: String
    var originalData: Data
    var originalStatus: stat
    var lines: [String]

    static func read(
        named name: String,
        in directoryDescriptor: Int32,
        directoryPath: String
    ) throws -> WineRegistryFile? {
        let path = URL(
            fileURLWithPath: directoryPath,
            isDirectory: true
        ).appendingPathComponent(name).path
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            let openError = errno
            if openError == ENOENT {
                return nil
            }
            if openError == ELOOP {
                throw ContainerFontInstallerError.unsafeFileSystemEntry(path)
            }
            throw ContainerFontInstallerError.registryReadFailed(
                path,
                code: openError
            )
        }
        defer { Darwin.close(descriptor) }

        let initialStatus = try validatedRegistryStatus(
            descriptor: descriptor,
            path: path
        )
        let data = try readRegistryData(
            descriptor: descriptor,
            path: path
        )
        let finalStatus = try validatedRegistryStatus(
            descriptor: descriptor,
            path: path
        )
        var pathStatus = stat()
        let statusResult = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard statusResult == 0,
              stableRegistryFile(initialStatus, finalStatus),
              stableRegistryFile(initialStatus, pathStatus) else {
            throw ContainerFontInstallerError.registryChanged(path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ContainerFontInstallerError.invalidRegistryEncoding(path)
        }

        return WineRegistryFile(
            name: name,
            path: path,
            originalData: data,
            originalStatus: initialStatus,
            lines: text.components(separatedBy: .newlines)
        )
    }

    var hasArchitectureMarker: Bool {
        lines.contains { $0.hasPrefix("#arch=") }
    }

    var serializedData: Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    var permissions: mode_t {
        originalStatus.st_mode & mode_t(0o777)
    }

    func verifyUnchanged(
        in directoryDescriptor: Int32
    ) throws {
        var currentStatus = stat()
        let result = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &currentStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0,
              stableRegistryFile(originalStatus, currentStatus) else {
            throw ContainerFontInstallerError.registryChanged(path)
        }
    }

    mutating func upsertStringValues(_ values: [String: String], in section: String) {
        guard !values.isEmpty else { return }

        let headerPrefix = "[\(section)]"
        let sectionStart: Int
        if let existingStart = lines.firstIndex(where: { $0.hasPrefix(headerPrefix) }) {
            sectionStart = existingStart
        } else {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[\(section)] \(Int(Date().timeIntervalSince1970))")
            lines.append("")
            sectionStart = lines.count - 2
        }

        var sectionEnd = lines.count
        if sectionStart + 1 < lines.count {
            for index in (sectionStart + 1)..<lines.count where lines[index].hasPrefix("[") {
                sectionEnd = index
                break
            }
        }

        var existingValueLines: [String: Int] = [:]
        for index in (sectionStart + 1)..<sectionEnd {
            guard let key = registryValueName(from: lines[index]) else {
                continue
            }
            existingValueLines[key] = index
        }

        var insertions: [String] = []
        for key in values.keys.sorted() {
            let line = "\"\(escapeRegistryString(key))\"=\"\(escapeRegistryString(values[key] ?? ""))\""
            if let index = existingValueLines[key] {
                lines[index] = line
            } else {
                insertions.append(line)
            }
        }

        if !insertions.isEmpty {
            lines.insert(contentsOf: insertions, at: sectionEnd)
        }
    }

    private func registryValueName(from line: String) -> String? {
        guard line.first == "\"" else {
            return nil
        }
        var escaped = false
        var value = ""
        for character in line.dropFirst() {
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                return value
            }
            value.append(character)
        }
        return nil
    }

    private func escapeRegistryString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func validatedRegistryStatus(
        descriptor: Int32,
        path: String
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw ContainerFontInstallerError.registryReadFailed(
                path,
                code: errno
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1,
              status.st_uid == geteuid() else {
            throw ContainerFontInstallerError.unsafeFileSystemEntry(path)
        }
        guard status.st_size >= 0,
              status.st_size <= maximumByteCount else {
            throw ContainerFontInstallerError.registryReadFailed(
                path,
                code: EFBIG
            )
        }
        return status
    }

    private static func readRegistryData(
        descriptor: Int32,
        path: String
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                guard data.count <= maximumByteCount - count else {
                    throw ContainerFontInstallerError.registryReadFailed(
                        path,
                        code: EFBIG
                    )
                }
                data.append(buffer, count: count)
                continue
            }
            if count == 0 {
                return data
            }
            if errno == EINTR {
                continue
            }
            throw ContainerFontInstallerError.registryReadFailed(
                path,
                code: errno
            )
        }
    }
}

private struct WineRegistryTransaction {
    private let directoryDescriptor: Int32
    private let directoryPath: String
    private let failureInjector:
        @Sendable (ContainerFontInstallerFailurePoint) throws -> Void

    init(
        directoryDescriptor: Int32,
        directoryPath: String,
        failureInjector:
            @escaping @Sendable (ContainerFontInstallerFailurePoint) throws -> Void
    ) {
        self.directoryDescriptor = directoryDescriptor
        self.directoryPath = directoryPath
        self.failureInjector = failureInjector
    }

    func commit(
        systemRegistry: WineRegistryFile,
        userRegistry: WineRegistryFile
    ) throws {
        var stagedSystemStorage: RegistryStagedFile?
        var stagedUserStorage: RegistryStagedFile?
        var backupSystemStorage: RegistryStagedFile?
        var backupUserStorage: RegistryStagedFile?
        var preserveBackups = false
        defer {
            if let stagedSystemStorage {
                cleanupIfPresent(stagedSystemStorage)
            }
            if let stagedUserStorage {
                cleanupIfPresent(stagedUserStorage)
            }
            if !preserveBackups {
                if let backupSystemStorage {
                    cleanupIfPresent(backupSystemStorage)
                }
                if let backupUserStorage {
                    cleanupIfPresent(backupUserStorage)
                }
            }
        }

        stagedSystemStorage = try stage(
            data: systemRegistry.serializedData,
            permissions: systemRegistry.permissions,
            label: "system-new"
        )
        try failureInjector(.beforeUserRegistryStaging)
        stagedUserStorage = try stage(
            data: userRegistry.serializedData,
            permissions: userRegistry.permissions,
            label: "user-new"
        )
        backupSystemStorage = try stage(
            data: systemRegistry.originalData,
            permissions: systemRegistry.permissions,
            label: "system-backup"
        )
        backupUserStorage = try stage(
            data: userRegistry.originalData,
            permissions: userRegistry.permissions,
            label: "user-backup"
        )
        guard var stagedSystem = stagedSystemStorage,
              var stagedUser = stagedUserStorage,
              var backupSystem = backupSystemStorage,
              var backupUser = backupUserStorage else {
            throw ContainerFontInstallerError.registryTransactionFailed(
                "Registry staging did not complete."
            )
        }

        var replacedSystem = false
        var replacedUser = false
        do {
            try failureInjector(.beforeOriginalRegistryValidation)
            try systemRegistry.verifyUnchanged(in: directoryDescriptor)
            try userRegistry.verifyUnchanged(in: directoryDescriptor)

            try failureInjector(.beforeFirstRegistryReplacement)
            try systemRegistry.verifyUnchanged(in: directoryDescriptor)
            try replace(
                staged: &stagedSystem,
                destinationName: systemRegistry.name,
                destinationPath: systemRegistry.path,
                didReplace: &replacedSystem
            )
            try failureInjector(.afterFirstRegistryReplacement)

            try userRegistry.verifyUnchanged(in: directoryDescriptor)
            try failureInjector(.beforeSecondRegistryReplacement)
            try userRegistry.verifyUnchanged(in: directoryDescriptor)
            try replace(
                staged: &stagedUser,
                destinationName: userRegistry.name,
                destinationPath: userRegistry.path,
                didReplace: &replacedUser
            )
            try failureInjector(.afterSecondRegistryReplacement)
            try synchronizeDirectory()
        } catch {
            let transactionError = normalizedTransactionError(error)
            do {
                try rollback(
                    systemRegistry: systemRegistry,
                    userRegistry: userRegistry,
                    installedSystem: stagedSystem,
                    installedUser: stagedUser,
                    backupSystem: &backupSystem,
                    backupUser: &backupUser,
                    replacedSystem: replacedSystem,
                    replacedUser: replacedUser
                )
            } catch {
                preserveBackups = true
                throw ContainerFontInstallerError.registryRecoveryFailed(
                    transaction: transactionError.localizedDescription,
                    recovery: error.localizedDescription
                )
            }
            throw transactionError
        }

        try remove(staged: &backupSystem)
        try remove(staged: &backupUser)
        try synchronizeDirectory()
    }

    private func rollback(
        systemRegistry: WineRegistryFile,
        userRegistry: WineRegistryFile,
        installedSystem: RegistryStagedFile,
        installedUser: RegistryStagedFile,
        backupSystem: inout RegistryStagedFile,
        backupUser: inout RegistryStagedFile,
        replacedSystem: Bool,
        replacedUser: Bool
    ) throws {
        var recoveryFailures: [String] = []

        if replacedUser {
            do {
                try failureInjector(.beforeUserRegistryRollback)
                guard destinationMatches(
                    installedUser,
                    named: userRegistry.name
                ) else {
                    throw ContainerFontInstallerError.registryChanged(
                        userRegistry.path
                    )
                }
                var restoredUser = false
                try replace(
                    staged: &backupUser,
                    destinationName: userRegistry.name,
                    destinationPath: userRegistry.path,
                    didReplace: &restoredUser
                )
            } catch {
                recoveryFailures.append(error.localizedDescription)
            }
        }
        if replacedSystem {
            do {
                try failureInjector(.beforeSystemRegistryRollback)
                guard destinationMatches(
                    installedSystem,
                    named: systemRegistry.name
                ) else {
                    throw ContainerFontInstallerError.registryChanged(
                        systemRegistry.path
                    )
                }
                var restoredSystem = false
                try replace(
                    staged: &backupSystem,
                    destinationName: systemRegistry.name,
                    destinationPath: systemRegistry.path,
                    didReplace: &restoredSystem
                )
            } catch {
                recoveryFailures.append(error.localizedDescription)
            }
        }
        do {
            try synchronizeDirectory()
        } catch {
            recoveryFailures.append(error.localizedDescription)
        }

        guard recoveryFailures.isEmpty else {
            throw ContainerFontInstallerError.registryTransactionFailed(
                recoveryFailures.joined(separator: "; ")
            )
        }
    }

    private func stage(
        data: Data,
        permissions: mode_t,
        label: String
    ) throws -> RegistryStagedFile {
        for _ in 0..<32 {
            let name = ".switchyard-font-registry-\(label)-\(UUID().uuidString).tmp"
            let path = URL(
                fileURLWithPath: directoryPath,
                isDirectory: true
            ).appendingPathComponent(name).path
            let descriptor = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0 else {
                if errno == EEXIST {
                    continue
                }
                throw ContainerFontInstallerError.registryWriteFailed(
                    path,
                    code: errno
                )
            }

            var identity: RegistryFileIdentity?
            var keepFile = false
            defer {
                Darwin.close(descriptor)
                if !keepFile, let identity {
                    unlinkIfSameFile(named: name, identity: identity)
                }
            }
            do {
                var status = stat()
                guard Darwin.fstat(descriptor, &status) == 0 else {
                    throw ContainerFontInstallerError.registryWriteFailed(
                        path,
                        code: errno
                    )
                }
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      status.st_nlink == 1,
                      status.st_uid == geteuid() else {
                    throw ContainerFontInstallerError.unsafeFileSystemEntry(path)
                }
                identity = RegistryFileIdentity(status)
                try write(data, to: descriptor, path: path)
                guard Darwin.fchmod(descriptor, permissions) == 0,
                      Darwin.fsync(descriptor) == 0 else {
                    throw ContainerFontInstallerError.registryWriteFailed(
                        path,
                        code: errno
                    )
                }
                var finalStatus = stat()
                guard Darwin.fstat(descriptor, &finalStatus) == 0,
                      identity == RegistryFileIdentity(finalStatus),
                      finalStatus.st_size == data.count else {
                    throw ContainerFontInstallerError.registryChanged(path)
                }
                let snapshot = RegistryFileSnapshot(finalStatus)
                keepFile = true
                return RegistryStagedFile(
                    name: name,
                    path: path,
                    snapshot: snapshot,
                    contentDigest: Data(SHA256.hash(data: data)),
                    isPresent: true
                )
            } catch {
                throw normalizedTransactionError(error)
            }
        }
        throw ContainerFontInstallerError.registryWriteFailed(
            directoryPath,
            code: EEXIST
        )
    }

    private func replace(
        staged: inout RegistryStagedFile,
        destinationName: String,
        destinationPath: String,
        didReplace: inout Bool
    ) throws {
        guard staged.isPresent,
              stagedFileIsUnchanged(staged) else {
            throw ContainerFontInstallerError.registryChanged(staged.path)
        }
        let result = staged.name.withCString { sourceName in
            destinationName.withCString { destinationName in
                Darwin.renameat(
                    directoryDescriptor,
                    sourceName,
                    directoryDescriptor,
                    destinationName
                )
            }
        }
        guard result == 0 else {
            throw ContainerFontInstallerError.registryWriteFailed(
                destinationPath,
                code: errno
            )
        }
        didReplace = true
        staged.isPresent = false

        guard destinationMatches(
            staged,
            named: destinationName
        ) else {
            throw ContainerFontInstallerError.registryChanged(destinationPath)
        }
    }

    private func destinationMatches(
        _ staged: RegistryStagedFile,
        named name: String
    ) -> Bool {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              staged.snapshot.matchesAfterRename(initialStatus) else {
            return false
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var bytesRead = 0
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                bytesRead += count
                guard bytesRead <= staged.snapshot.size else {
                    return false
                }
                hasher.update(data: Data(buffer.prefix(count)))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            return false
        }

        var finalStatus = stat()
        var pathStatus = stat()
        let pathResult = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        return bytesRead == staged.snapshot.size
            && Data(hasher.finalize()) == staged.contentDigest
            && Darwin.fstat(descriptor, &finalStatus) == 0
            && stableRegistryFile(initialStatus, finalStatus)
            && pathResult == 0
            && RegistryFileIdentity(initialStatus)
                == RegistryFileIdentity(pathStatus)
    }

    private func remove(staged: inout RegistryStagedFile) throws {
        guard staged.isPresent else {
            return
        }
        guard stagedFileIsUnchanged(staged) else {
            throw ContainerFontInstallerError.registryChanged(staged.path)
        }
        let result = staged.name.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
        guard result == 0 else {
            throw ContainerFontInstallerError.registryWriteFailed(
                staged.path,
                code: errno
            )
        }
        staged.isPresent = false
    }

    private func cleanupIfPresent(_ staged: RegistryStagedFile) {
        guard staged.isPresent else {
            return
        }
        unlinkIfSameFile(
            named: staged.name,
            identity: staged.snapshot.identity
        )
    }

    private func unlinkIfSameFile(
        named name: String,
        identity: RegistryFileIdentity
    ) {
        var status = stat()
        let statusResult = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard statusResult == 0,
              identity == RegistryFileIdentity(status) else {
            return
        }
        _ = name.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
    }

    private func stagedFileIsUnchanged(
        _ staged: RegistryStagedFile
    ) -> Bool {
        var status = stat()
        let result = staged.name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        return result == 0
            && staged.snapshot == RegistryFileSnapshot(status)
    }

    private func write(
        _ data: Data,
        to descriptor: Int32,
        path: String
    ) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw ContainerFontInstallerError.registryWriteFailed(
                        path,
                        code: errno
                    )
                }
            }
        }
    }

    private func synchronizeDirectory() throws {
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw ContainerFontInstallerError.registryWriteFailed(
                directoryPath,
                code: errno
            )
        }
    }

    private func normalizedTransactionError(
        _ error: Error
    ) -> ContainerFontInstallerError {
        if let error = error as? ContainerFontInstallerError {
            return error
        }
        return .registryTransactionFailed(error.localizedDescription)
    }
}

private struct RegistryStagedFile {
    var name: String
    var path: String
    var snapshot: RegistryFileSnapshot
    var contentDigest: Data
    var isPresent: Bool
}

private struct RegistryFileIdentity: Equatable {
    var device: dev_t
    var inode: ino_t

    init(_ status: stat) {
        self.device = status.st_dev
        self.inode = status.st_ino
    }
}

private struct RegistryFileSnapshot: Equatable {
    var identity: RegistryFileIdentity
    var mode: mode_t
    var linkCount: nlink_t
    var owner: uid_t
    var size: Int
    var modificationSeconds: Int
    var modificationNanoseconds: Int
    var changeSeconds: Int
    var changeNanoseconds: Int

    init(_ status: stat) {
        self.identity = RegistryFileIdentity(status)
        self.mode = status.st_mode
        self.linkCount = status.st_nlink
        self.owner = status.st_uid
        self.size = Int(status.st_size)
        self.modificationSeconds = status.st_mtimespec.tv_sec
        self.modificationNanoseconds = status.st_mtimespec.tv_nsec
        self.changeSeconds = status.st_ctimespec.tv_sec
        self.changeNanoseconds = status.st_ctimespec.tv_nsec
    }

    func matchesAfterRename(_ status: stat) -> Bool {
        identity == RegistryFileIdentity(status)
            && mode == status.st_mode
            && linkCount == status.st_nlink
            && owner == status.st_uid
            && size == Int(status.st_size)
            && modificationSeconds == status.st_mtimespec.tv_sec
            && modificationNanoseconds == status.st_mtimespec.tv_nsec
    }
}

private func stableRegistryFile(_ lhs: stat, _ rhs: stat) -> Bool {
    RegistryFileIdentity(lhs) == RegistryFileIdentity(rhs)
        && lhs.st_size == rhs.st_size
        && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
        && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
        && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}
