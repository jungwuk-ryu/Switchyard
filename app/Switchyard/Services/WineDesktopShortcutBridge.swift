import AppCore
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

enum WineDesktopShortcutBridgeError: LocalizedError {
    case missingShortcutHandler
    case couldNotSignShortcut(String)
    case desktopNameCollision(String)
    case committedTransactionNeedsCleanup

    var errorDescription: String? {
        switch self {
        case .missingShortcutHandler:
            String(
                localized: "switchyard-shortcut-handler was not found in the app bundle or build directory.",
                bundle: SwitchyardStrings.bundle
            )
        case let .couldNotSignShortcut(name):
            String(
                localized: "Could not sign the generated macOS shortcut for \(name).",
                bundle: SwitchyardStrings.bundle
            )
        case let .desktopNameCollision(name):
            String(
                localized: "Could not choose a safe macOS desktop name for \(name).",
                bundle: SwitchyardStrings.bundle
            )
        case .committedTransactionNeedsCleanup:
            String(
                localized: "A generated macOS shortcut was committed, but its transaction cleanup must be retried.",
                bundle: SwitchyardStrings.bundle
            )
        }
    }
}

enum WineDesktopShortcutSubprocessError: Error, Equatable {
    case timedOut(String)
    case cleanupTimedOut(String, pid_t)
}

enum WineDesktopShortcutPersistenceLimits {
    static let maximumRouteIndexByteCount =
        4 * 1_024 * 1_024
    static let maximumTransactionJournalByteCount =
        8 * 1_024 * 1_024
    static let maximumBackupCount = 1_024
    static let maximumBundleTreeEntryCount = 32
    static let maximumTransactionTreeEntryCount = 16_384
}

enum WineDesktopShortcutSubprocessRunner {
    typealias ProcessStarted = @Sendable (pid_t) -> Void

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration = .seconds(15),
        processStarted: @escaping ProcessStarted = { _ in }
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(
            of: Int32.self,
            returning: Int32.self
        ) { group in
            group.addTask {
                try runSynchronously(
                    executableURL: executableURL,
                    arguments: arguments,
                    timeout: timeout,
                    processStarted: processStarted
                )
            }
            guard let status = try await group.next() else {
                throw CancellationError()
            }
            return status
        }
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        processStarted: ProcessStarted
    ) throws -> Int32 {
        try Task.checkCancellation()
        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            completion.signal()
        }
        try process.run()
        let processID = process.processIdentifier
        processStarted(processID)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while completion.wait(
            timeout: .now() + .milliseconds(25)
        ) == .timedOut {
            if Task.isCancelled {
                try stopAndReap(
                    process,
                    completion: completion,
                    command: executableURL.path
                )
                throw CancellationError()
            }
            if clock.now >= deadline {
                try stopAndReap(
                    process,
                    completion: completion,
                    command: executableURL.path
                )
                throw WineDesktopShortcutSubprocessError.timedOut(
                    executableURL.path
                )
            }
        }
        return process.terminationStatus
    }

    private static func stopAndReap(
        _ process: Process,
        completion: DispatchSemaphore,
        command: String
    ) throws {
        guard process.isRunning else { return }
        let processID = process.processIdentifier
        process.terminate()
        if completion.wait(
            timeout: .now() + .milliseconds(500)
        ) == .success {
            return
        }

        _ = Darwin.kill(processID, SIGKILL)
        guard completion.wait(
            timeout: .now() + .seconds(2)
        ) == .success else {
            throw WineDesktopShortcutSubprocessError.cleanupTimedOut(
                command,
                processID
            )
        }
    }
}

fileprivate struct WineDesktopShortcutSendableImage:
    @unchecked Sendable
{
    let value: CGImage
}

enum WineDesktopShortcutIconRenderer {
    private static let maximumSourceByteCount =
        32 * 1_024 * 1_024
    private static let maximumFrameCount = 256
    private static let maximumDimension = 16_384
    private static let maximumDecodedPixelCount =
        64 * 1_024 * 1_024

    static func pngDataBySize(
        at url: URL,
        pixelSizes: Set<Int>
    ) -> [Int: Data]? {
        guard let data = boundedRegularFileData(at: url),
              !Task.isCancelled,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary
              ),
              sourcePropertiesAreSafe(source),
              let maximumPixelSize = pixelSizes.max(),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                    kCGImageSourceCreateThumbnailFromImageAlways:
                        true,
                    kCGImageSourceCreateThumbnailWithTransform:
                        true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize:
                        maximumPixelSize
                  ] as CFDictionary
              ),
              !Task.isCancelled else {
            return nil
        }
        return pngDataBySize(
            for: WineDesktopShortcutSendableImage(
                value: image
            ),
            pixelSizes: pixelSizes
        )
    }

    static func decodedImageBudgetIsSafe(
        width: Int,
        height: Int,
        frameCount: Int
    ) -> Bool {
        guard width > 0,
              height > 0,
              frameCount > 0,
              frameCount <= maximumFrameCount,
              width <= maximumDimension,
              height <= maximumDimension,
              width <= maximumDecodedPixelCount / height else {
            return false
        }
        return true
    }

    private static func sourcePropertiesAreSafe(
        _ source: CGImageSource
    ) -> Bool {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0,
              frameCount <= maximumFrameCount,
              let properties =
                CGImageSourceCopyPropertiesAtIndex(
                    source,
                    0,
                    nil
                ) as? [CFString: Any],
              let width =
                (properties[kCGImagePropertyPixelWidth]
                    as? NSNumber)?.intValue,
              let height =
                (properties[kCGImagePropertyPixelHeight]
                    as? NSNumber)?.intValue else {
            return false
        }
        return decodedImageBudgetIsSafe(
            width: width,
            height: height,
            frameCount: frameCount
        )
    }

    fileprivate static func pngDataBySize(
        for image: WineDesktopShortcutSendableImage,
        pixelSizes: Set<Int>
    ) -> [Int: Data]? {
        var rendered: [Int: Data] = [:]
        for pixels in pixelSizes.sorted() {
            guard !Task.isCancelled,
                  let data = pngData(
                      for: image.value,
                      pixels: pixels
                  ) else {
                return nil
            }
            rendered[pixels] = data
        }
        return rendered
    }

    private static func pngData(
        for image: CGImage,
        pixels: Int
    ) -> Data? {
        guard pixels > 0,
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: pixels * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo:
                    CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.clear(
            CGRect(
                x: 0,
                y: 0,
                width: pixels,
                height: pixels
            )
        )

        let sourceWidth = max(CGFloat(image.width), 1)
        let sourceHeight = max(CGFloat(image.height), 1)
        let scale = min(
            CGFloat(pixels) / sourceWidth,
            CGFloat(pixels) / sourceHeight
        )
        let targetWidth = sourceWidth * scale
        let targetHeight = sourceHeight * scale
        context.draw(
            image,
            in: CGRect(
                x: (CGFloat(pixels) - targetWidth) / 2,
                y: (CGFloat(pixels) - targetHeight) / 2,
                width: targetWidth,
                height: targetHeight
            )
        )
        guard let renderedImage = context.makeImage() else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            renderedImage,
            nil
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func boundedRegularFileData(
        at url: URL
    ) -> Data? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              initialStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG),
              initialStatus.st_size > 0,
              initialStatus.st_size
                <= off_t(maximumSourceByteCount) else {
            return nil
        }
        let byteCount = Int(initialStatus.st_size)
        var data = Data(count: byteCount)
        var consumed = 0
        let readSucceeded = data.withUnsafeMutableBytes {
            bytes -> Bool in
            while consumed < byteCount {
                guard !Task.isCancelled else { return false }
                let count = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: consumed),
                    byteCount - consumed,
                    off_t(consumed)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                consumed += count
            }
            return true
        }
        guard readSucceeded else { return nil }

        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard Darwin.fstat(
            descriptor,
            &finalDescriptorStatus
        ) == 0,
              Darwin.lstat(url.path, &finalPathStatus) == 0,
              sameFileStatus(
                  initialStatus,
                  finalDescriptorStatus
              ),
              sameFileStatus(
                  initialStatus,
                  finalPathStatus
              ) else {
            return nil
        }
        return data
    }

    private static func sameFileStatus(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }
}

struct WineDesktopShortcutBundleSignatureSnapshot:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let fileStampsByRelativePath:
        [String: WineBridgeFileStamp]
}

struct WineDesktopShortcutBundleStableIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let rootDevice: UInt64
    let rootInode: UInt64
    let rootMode: UInt32
    let rootLinkCount: UInt64
    let rootOwnerUserID: UInt32
    let rootOwnerGroupID: UInt32
    let treeEntryCount: UInt32
    let treeDigest: String
}

enum WineDesktopShortcutBundleSignatureVerifier {
    private struct StableIdentityBudget {
        var remainingEntries: Int
        var remainingRelativePathBytes: Int
    }

    private static let observedRelativePaths = [
        "Contents",
        "Contents/Info.plist",
        "Contents/MacOS",
        "Contents/MacOS/switchyard-shortcut-handler",
        "Contents/Resources",
        "Contents/Resources/Shortcut.icns",
        "Contents/_CodeSignature",
        "Contents/_CodeSignature/CodeResources",
    ]

    static func analysis(
        at bundleURL: URL,
        matching expectedSnapshot:
            WineDesktopShortcutBundleSignatureSnapshot? = nil
    ) -> WineDesktopShortcutBundleSignatureSnapshot? {
        guard !Task.isCancelled else { return nil }
        guard let initial = safeSnapshot(at: bundleURL),
              expectedSnapshot == nil
                || expectedSnapshot == initial else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  nil
              ) == errSecSuccess,
              !Task.isCancelled,
              safeSnapshot(at: bundleURL) == initial else {
            return nil
        }
        return initial
    }

    static func safeSnapshot(
        at bundleURL: URL
    ) -> WineDesktopShortcutBundleSignatureSnapshot? {
        guard layoutIsSafe(at: bundleURL),
              !Task.isCancelled else {
            return nil
        }
        let initial = snapshot(at: bundleURL)
        guard layoutIsSafe(at: bundleURL),
              snapshot(at: bundleURL) == initial else {
            return nil
        }
        return initial
    }

    static func snapshot(
        at bundleURL: URL
    ) -> WineDesktopShortcutBundleSignatureSnapshot {
        WineDesktopShortcutBundleSignatureSnapshot(
            fileStampsByRelativePath: Dictionary(
                uniqueKeysWithValues:
                    observedRelativePaths.map { relativePath in
                        let url = relativePath.isEmpty
                            ? bundleURL
                            : bundleURL.appendingPathComponent(
                                relativePath
                            )
                        return (
                            relativePath,
                            WineBridgeFileStamp.read(from: url)
                        )
                    }
            )
        )
    }

    static func stableIdentity(
        at bundleURL: URL,
        maximumEntryCount: Int =
            WineDesktopShortcutPersistenceLimits
                .maximumBundleTreeEntryCount
    ) -> WineDesktopShortcutBundleStableIdentity? {
        let boundedEntryCount = min(
            WineDesktopShortcutPersistenceLimits
                .maximumBundleTreeEntryCount,
            max(1, maximumEntryCount)
        )
        guard !Task.isCancelled,
              let first = captureStableIdentity(
                  at: bundleURL,
                  maximumEntryCount: boundedEntryCount
              ),
              !Task.isCancelled,
              let second = captureStableIdentity(
                  at: bundleURL,
                  maximumEntryCount: boundedEntryCount
              ),
              first == second else {
            return nil
        }
        return second
    }

    static func layoutIsSafe(
        at bundleURL: URL,
        includesIcon expectedIncludesIcon: Bool? = nil
    ) -> Bool {
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let macOSURL = contentsURL.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        let resourcesURL = contentsURL.appendingPathComponent(
            "Resources",
            isDirectory: true
        )
        let signatureURL = contentsURL.appendingPathComponent(
            "_CodeSignature",
            isDirectory: true
        )
        guard boundedDirectoryEntryNames(
            at: bundleURL,
            maximumEntryCount: 1
        ) == ["Contents"],
              boundedDirectoryEntryNames(
                  at: contentsURL,
                  maximumEntryCount: 4
              ) == [
                  "Info.plist",
                  "MacOS",
                  "Resources",
                  "_CodeSignature"
              ],
              boundedDirectoryEntryNames(
                  at: macOSURL,
                  maximumEntryCount: 1
              ) == ["switchyard-shortcut-handler"],
              let resourceEntries =
                boundedDirectoryEntryNames(
                    at: resourcesURL,
                    maximumEntryCount: 1
                ),
              resourceEntries == []
                || resourceEntries == ["Shortcut.icns"],
              boundedDirectoryEntryNames(
                  at: signatureURL,
                  maximumEntryCount: 1
              ) == ["CodeResources"],
              expectedIncludesIcon == nil
                || expectedIncludesIcon
                    == !resourceEntries.isEmpty,
              isBoundedRegularFile(
                  contentsURL.appendingPathComponent(
                      "Info.plist"
                  ),
                  maximumByteCount: 64 * 1_024
              ),
              isBoundedRegularFile(
                  macOSURL.appendingPathComponent(
                      "switchyard-shortcut-handler"
                  ),
                  maximumByteCount: 64 * 1_024 * 1_024
              ),
              isBoundedRegularFile(
                  signatureURL.appendingPathComponent(
                      "CodeResources"
                  ),
                  maximumByteCount: 4 * 1_024 * 1_024
              ) else {
            return false
        }
        return resourceEntries.isEmpty
            || isBoundedRegularFile(
                resourcesURL.appendingPathComponent(
                    "Shortcut.icns"
                ),
                maximumByteCount: 32 * 1_024 * 1_024
            )
    }

    private static func isBoundedRegularFile(
        _ url: URL,
        maximumByteCount: Int
    ) -> Bool {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(
            descriptor,
            &descriptorStatus
        ) == 0,
              Darwin.lstat(url.path, &pathStatus) == 0,
              sameFileStatus(
                  descriptorStatus,
                  pathStatus
              ),
              descriptorStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG),
              descriptorStatus.st_size > 0,
              descriptorStatus.st_size
                <= off_t(maximumByteCount) else {
            return false
        }
        return true
    }

    private static func boundedDirectoryEntryNames(
        at url: URL,
        maximumEntryCount: Int
    ) -> Set<String>? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        guard let directory = Darwin.fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }
        defer { Darwin.closedir(directory) }

        var initialStatus = stat()
        guard Darwin.fstat(
            Darwin.dirfd(directory),
            &initialStatus
        ) == 0,
              initialStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFDIR) else {
            return nil
        }
        var names: Set<String> = []
        while let entry = Darwin.readdir(directory) {
            let name = directoryEntryName(entry)
            guard name != ".", name != ".." else { continue }
            guard names.count < maximumEntryCount,
                  names.insert(name).inserted else {
                return nil
            }
        }
        var finalStatus = stat()
        guard Darwin.fstat(
            Darwin.dirfd(directory),
            &finalStatus
        ) == 0,
              sameFileStatus(
                  initialStatus,
                  finalStatus
              ) else {
            return nil
        }
        return names
    }

    private static func captureStableIdentity(
        at bundleURL: URL,
        maximumEntryCount: Int
    ) -> WineDesktopShortcutBundleStableIdentity? {
        let rootDescriptor = Darwin.open(
            bundleURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else { return nil }
        defer { Darwin.close(rootDescriptor) }

        var rootStatus = stat()
        guard Darwin.fstat(
            rootDescriptor,
            &rootStatus
        ) == 0,
              rootStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFDIR) else {
            return nil
        }
        var hasher = SHA256()
        hasher.update(
            data: Data(
                "switchyard-desktop-bundle-tree-v1".utf8
            )
        )
        var entryCount: UInt32 = 0
        var budget = StableIdentityBudget(
            remainingEntries: maximumEntryCount,
            remainingRelativePathBytes: 64 * 1_024
        )
        guard captureDirectoryEntries(
            descriptor: rootDescriptor,
            relativeComponents: [],
            hasher: &hasher,
            entryCount: &entryCount,
            budget: &budget
        ) else {
            return nil
        }
        var finalRootStatus = stat()
        guard Darwin.fstat(
            rootDescriptor,
            &finalRootStatus
        ) == 0,
              sameFileStatus(
                  rootStatus,
                  finalRootStatus
              ) else {
            return nil
        }
        return WineDesktopShortcutBundleStableIdentity(
            rootDevice: UInt64(rootStatus.st_dev),
            rootInode: UInt64(rootStatus.st_ino),
            rootMode: UInt32(rootStatus.st_mode),
            rootLinkCount: UInt64(rootStatus.st_nlink),
            rootOwnerUserID: UInt32(rootStatus.st_uid),
            rootOwnerGroupID: UInt32(rootStatus.st_gid),
            treeEntryCount: entryCount,
            treeDigest: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func captureDirectoryEntries(
        descriptor: Int32,
        relativeComponents: [String],
        hasher: inout SHA256,
        entryCount: inout UInt32,
        budget: inout StableIdentityBudget
    ) -> Bool {
        var initialDirectoryStatus = stat()
        guard Darwin.fstat(
            descriptor,
            &initialDirectoryStatus
        ) == 0,
              initialDirectoryStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFDIR) else {
            return false
        }

        let enumerationDescriptor = Darwin.dup(descriptor)
        guard enumerationDescriptor >= 0,
              let directory =
                Darwin.fdopendir(enumerationDescriptor) else {
            if enumerationDescriptor >= 0 {
                Darwin.close(enumerationDescriptor)
            }
            return false
        }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = directoryEntryName(entry)
            guard name != ".", name != ".." else { continue }
            guard budget.remainingEntries > 0 else {
                Darwin.closedir(directory)
                return false
            }
            budget.remainingEntries -= 1
            names.append(name)
        }
        Darwin.closedir(directory)

        for name in names.sorted() {
            guard !Task.isCancelled else { return false }
            let childComponents = relativeComponents + [name]
            let relativePath = childComponents.joined(
                separator: "/"
            )
            guard let pathByteCount =
                relativePath.data(using: .utf8)?.count,
                  pathByteCount
                    <= budget.remainingRelativePathBytes else {
                return false
            }
            budget.remainingRelativePathBytes -= pathByteCount

            var childStatus = stat()
            let statusResult = name.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &childStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statusResult == 0 else { return false }
            entryCount &+= 1
            updateStableTreeHasher(
                &hasher,
                relativePath: relativePath,
                status: childStatus
            )
            guard childStatus.st_mode & mode_t(S_IFMT)
                    == mode_t(S_IFDIR) else {
                continue
            }

            let childDescriptor = name.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC
                        | O_NOFOLLOW
                )
            }
            guard childDescriptor >= 0 else { return false }
            var openedStatus = stat()
            let openedMatches =
                Darwin.fstat(
                    childDescriptor,
                    &openedStatus
                ) == 0
                && sameFileStatus(
                    childStatus,
                    openedStatus
                )
            let captured = openedMatches
                && captureDirectoryEntries(
                    descriptor: childDescriptor,
                    relativeComponents: childComponents,
                    hasher: &hasher,
                    entryCount: &entryCount,
                    budget: &budget
                )
            Darwin.close(childDescriptor)
            guard captured else { return false }
        }

        var finalDirectoryStatus = stat()
        return Darwin.fstat(
            descriptor,
            &finalDirectoryStatus
        ) == 0
            && sameFileStatus(
                initialDirectoryStatus,
                finalDirectoryStatus
            )
    }

    private static func updateStableTreeHasher(
        _ hasher: inout SHA256,
        relativePath: String,
        status: stat
    ) {
        let pathData = Data(relativePath.utf8)
        update(
            UInt64(pathData.count),
            hasher: &hasher
        )
        hasher.update(data: pathData)
        update(UInt64(status.st_dev), hasher: &hasher)
        update(UInt64(status.st_ino), hasher: &hasher)
        update(UInt32(status.st_mode), hasher: &hasher)
        update(UInt64(status.st_nlink), hasher: &hasher)
        update(UInt32(status.st_uid), hasher: &hasher)
        update(UInt32(status.st_gid), hasher: &hasher)
        update(
            UInt64(max(0, status.st_size)),
            hasher: &hasher
        )
        update(
            Int64(status.st_mtimespec.tv_sec),
            hasher: &hasher
        )
        update(
            Int64(status.st_mtimespec.tv_nsec),
            hasher: &hasher
        )
        update(
            Int64(status.st_ctimespec.tv_sec),
            hasher: &hasher
        )
        update(
            Int64(status.st_ctimespec.tv_nsec),
            hasher: &hasher
        )
    }

    private static func update<T: FixedWidthInteger>(
        _ value: T,
        hasher: inout SHA256
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) {
            hasher.update(data: Data($0))
        }
    }

    private static func directoryEntryName(
        _ entry: UnsafeMutablePointer<dirent>
    ) -> String {
        withUnsafePointer(to: entry.pointee.d_name) {
            pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXNAMLEN) + 1
            ) {
                String(cString: $0)
            }
        }
    }

    private static func sameFileStatus(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }
}

actor WineDesktopShortcutBundleSignatureCache {
    typealias Analyzer = @Sendable (
        URL,
        WineDesktopShortcutBundleSignatureSnapshot
    ) -> WineDesktopShortcutBundleSignatureSnapshot?

    private struct InFlightAnalysis {
        let id: UUID
        let generation: UInt64
        let task: Task<
            WineDesktopShortcutBundleSignatureSnapshot?,
            Never
        >
        var waiterIDs: Set<UUID>
    }

    private let maximumEntryCount: Int
    private let analyzer: Analyzer
    private var cached:
        Set<WineDesktopShortcutBundleSignatureSnapshot> = []
    private var cacheOrder:
        [WineDesktopShortcutBundleSignatureSnapshot] = []
    private var inFlight:
        [WineDesktopShortcutBundleSignatureSnapshot:
            InFlightAnalysis] = [:]
    private var analysisExecutionCount = 0
    private var generation: UInt64 = 0

    init(
        maximumEntryCount: Int = 1_024,
        analyzer: @escaping Analyzer = {
            WineDesktopShortcutBundleSignatureVerifier.analysis(
                at: $0,
                matching: $1
            )
        }
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.analyzer = analyzer
    }

    func analysis(
        at url: URL
    ) async throws
        -> WineDesktopShortcutBundleSignatureSnapshot?
    {
        try Task.checkCancellation()
        guard let snapshot =
            WineDesktopShortcutBundleSignatureVerifier
                .safeSnapshot(at: url) else {
            return nil
        }
        if cached.contains(snapshot) {
            return snapshot
        }

        let waiterID = UUID()
        let flight: InFlightAnalysis
        if var existing = inFlight[snapshot] {
            existing.waiterIDs.insert(waiterID)
            inFlight[snapshot] = existing
            flight = existing
        } else {
            let analyzer = analyzer
            let task = Task.detached(priority: .utility) {
                analyzer(url, snapshot)
            }
            flight = InFlightAnalysis(
                id: UUID(),
                generation: generation,
                task: task,
                waiterIDs: [waiterID]
            )
            inFlight[snapshot] = flight
            analysisExecutionCount += 1
        }

        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    snapshot: snapshot,
                    flightID: flight.id
                )
            }
        }
        completeFlight(
            snapshot: snapshot,
            flightID: flight.id
        )
        try Task.checkCancellation()
        guard generation == flight.generation,
              result == snapshot,
              WineDesktopShortcutBundleSignatureVerifier
                .safeSnapshot(at: url) == snapshot else {
            return nil
        }
        store(snapshot)
        return snapshot
    }

    func removeAll() {
        generation &+= 1
        for flight in inFlight.values {
            flight.task.cancel()
        }
        cached.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        inFlight.removeAll(keepingCapacity: false)
    }

    func analysisExecutionCountForTesting() -> Int {
        analysisExecutionCount
    }

    func inFlightCountForTesting() -> Int {
        inFlight.count
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        snapshot: WineDesktopShortcutBundleSignatureSnapshot,
        flightID: UUID
    ) {
        guard var flight = inFlight[snapshot],
              flight.id == flightID else {
            return
        }
        flight.waiterIDs.remove(waiterID)
        guard !flight.waiterIDs.isEmpty else {
            inFlight.removeValue(forKey: snapshot)
            flight.task.cancel()
            return
        }
        inFlight[snapshot] = flight
    }

    private func completeFlight(
        snapshot: WineDesktopShortcutBundleSignatureSnapshot,
        flightID: UUID
    ) {
        guard inFlight[snapshot]?.id == flightID else {
            return
        }
        inFlight.removeValue(forKey: snapshot)
    }

    private func store(
        _ snapshot: WineDesktopShortcutBundleSignatureSnapshot
    ) {
        guard cached.insert(snapshot).inserted else { return }
        cacheOrder.append(snapshot)
        while cached.count > maximumEntryCount,
              let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cached.remove(oldest)
        }
    }
}

struct WineDesktopShortcutBridgeRefreshResult {
    var createdShortcutNames: [String]
    var removedShortcutNames: [String]
}

enum WineDesktopShortcutCommitCheckpoint: Equatable {
    case didBackupBundle(Int)
    case didInstallBundle(Int)
    case willPublishRoutes
    case willMarkRolledBack
    case willCleanupTransaction
}

struct WineDesktopShortcutHelperIdentity:
    Codable,
    Equatable,
    Sendable
{
    let sha256: String
    let byteCount: UInt64
}

struct WineDesktopShortcutHelperSliceProfile:
    Hashable,
    Sendable
{
    let cpuType: UInt32
    let cpuSubtype: UInt32
    let canonicalByteCount: UInt64
}

struct WineDesktopShortcutHelperProfile:
    Hashable,
    Sendable
{
    let slices: [WineDesktopShortcutHelperSliceProfile]
}

struct WineDesktopShortcutHelperAnalysis: Sendable {
    let identity: WineDesktopShortcutHelperIdentity
    let profile: WineDesktopShortcutHelperProfile
    let fileSnapshot: WineDesktopShortcutHelperFileSnapshot
}

struct WineDesktopShortcutHelperFileSnapshot:
    Hashable,
    Sendable
{
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let linkCount: UInt64
    let owner: UInt32
    let byteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        mode = UInt32(status.st_mode)
        linkCount = UInt64(status.st_nlink)
        owner = UInt32(status.st_uid)
        byteCount = Int64(status.st_size)
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changeSeconds = Int64(status.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

enum WineDesktopShortcutHelperIdentityReader {
    static let maximumByteCount: UInt64 = 64 * 1_024 * 1_024
    private static let maximumLoadCommandBytes = 4 * 1_024 * 1_024
    private static let maximumArchitectureCount = 16
    private static let maximumLoadCommandCount = 4_096
    private static let streamBufferByteCount = 64 * 1_024
    private static let codeSignatureCommand: UInt32 = 0x1d
    private static let segmentCommand: UInt32 = 0x1
    private static let segment64Command: UInt32 = 0x19

    private enum ByteOrder {
        case littleEndian
        case bigEndian
    }

    private struct Slice {
        let offset: UInt64
        let size: UInt64
        let byteOrder: ByteOrder
        let is64Bit: Bool
        let cpuType: UInt32
        let cpuSubtype: UInt32
    }

    private struct CanonicalSlice {
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let byteCount: UInt64
        let slice: Slice
        let normalizedRanges: [Range<UInt64>]
    }

    private struct SegmentExtent {
        let isLinkEdit: Bool
        let vmAddress: UInt64
        let vmSize: UInt64
        let fileOffset: UInt64
        let fileSize: UInt64
    }

    static func identity(
        at url: URL
    ) -> WineDesktopShortcutHelperIdentity? {
        analysis(at: url)?.identity
    }

    static func fileSnapshot(
        at url: URL
    ) -> WineDesktopShortcutHelperFileSnapshot? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0,
              UInt64(status.st_size) <= maximumByteCount else {
            return nil
        }
        return WineDesktopShortcutHelperFileSnapshot(status)
    }

    static func analysis(
        at url: URL,
        matching expectedProfile:
            WineDesktopShortcutHelperProfile? = nil
    ) -> WineDesktopShortcutHelperAnalysis? {
        guard !Task.isCancelled else { return nil }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              initialStatus.st_mode & S_IFMT == S_IFREG,
              initialStatus.st_size >= 0 else {
            return nil
        }
        let byteCount = UInt64(initialStatus.st_size)
        guard byteCount > 0,
              byteCount <= maximumByteCount,
              let slices = slices(
                  descriptor: descriptor,
                  fileByteCount: byteCount
              ) else {
            return nil
        }

        var canonicalSlices: [CanonicalSlice] = []
        for slice in slices {
            guard !Task.isCancelled,
                  let canonicalSlice = canonicalSlice(
                descriptor: descriptor,
                slice: slice
            ) else {
                return nil
            }
            canonicalSlices.append(canonicalSlice)
        }

        canonicalSlices.sort {
            if $0.cpuType != $1.cpuType {
                return $0.cpuType < $1.cpuType
            }
            return $0.cpuSubtype < $1.cpuSubtype
        }
        guard Set(canonicalSlices.map {
            "\($0.cpuType):\($0.cpuSubtype)"
        }).count == canonicalSlices.count else {
            return nil
        }
        let profile = WineDesktopShortcutHelperProfile(
            slices: canonicalSlices.map {
                WineDesktopShortcutHelperSliceProfile(
                    cpuType: $0.cpuType,
                    cpuSubtype: $0.cpuSubtype,
                    canonicalByteCount: $0.byteCount
                )
            }
        )
        guard expectedProfile == nil || expectedProfile == profile else {
            return nil
        }

        var canonicalByteCount: UInt64 = 0
        var digests: [Data] = []
        for slice in canonicalSlices {
            guard !Task.isCancelled else { return nil }
            let (sum, overflow) = canonicalByteCount
                .addingReportingOverflow(slice.byteCount)
            guard !overflow,
                  let digest = hash(
                      descriptor: descriptor,
                      fileOffset: slice.slice.offset,
                      byteCount: slice.byteCount,
                      normalizedRanges: slice.normalizedRanges
                  ) else {
                return nil
            }
            canonicalByteCount = sum
            digests.append(digest)
        }

        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard Darwin.fstat(descriptor, &finalDescriptorStatus) == 0,
              Darwin.lstat(url.path, &finalPathStatus) == 0,
              sameIdentity(initialStatus, finalDescriptorStatus),
              sameIdentity(initialStatus, finalPathStatus) else {
            return nil
        }

        var hasher = SHA256()
        hasher.update(
            data: Data(
                "SwitchyardShortcutMachOContentV1\u{0}".utf8
            )
        )
        update(UInt32(canonicalSlices.count), hasher: &hasher)
        for (slice, digest) in zip(canonicalSlices, digests) {
            update(slice.cpuType, hasher: &hasher)
            update(slice.cpuSubtype, hasher: &hasher)
            update(slice.byteCount, hasher: &hasher)
            hasher.update(data: digest)
        }
        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return WineDesktopShortcutHelperAnalysis(
            identity: WineDesktopShortcutHelperIdentity(
                sha256: digest,
                byteCount: canonicalByteCount
            ),
            profile: profile,
            fileSnapshot:
                WineDesktopShortcutHelperFileSnapshot(initialStatus)
        )
    }

    private static func slices(
        descriptor: Int32,
        fileByteCount: UInt64
    ) -> [Slice]? {
        guard let prefix = read(
            descriptor: descriptor,
            offset: 0,
            byteCount: min(32, Int(fileByteCount))
        ),
              prefix.count >= 8 else {
            return nil
        }
        let magic = Array(prefix.prefix(4))
        if let format = thinFormat(magic) {
            guard let cpuType = uint32(
                prefix,
                offset: 4,
                byteOrder: format.byteOrder
            ),
                  let cpuSubtype = uint32(
                      prefix,
                      offset: 8,
                      byteOrder: format.byteOrder
                  ) else {
                return nil
            }
            return [
                Slice(
                    offset: 0,
                    size: fileByteCount,
                    byteOrder: format.byteOrder,
                    is64Bit: format.is64Bit,
                    cpuType: cpuType,
                    cpuSubtype: cpuSubtype
                )
            ]
        }

        let fatFormat: (byteOrder: ByteOrder, is64Bit: Bool)
        switch magic {
        case [0xca, 0xfe, 0xba, 0xbe]:
            fatFormat = (.bigEndian, false)
        case [0xbe, 0xba, 0xfe, 0xca]:
            fatFormat = (.littleEndian, false)
        case [0xca, 0xfe, 0xba, 0xbf]:
            fatFormat = (.bigEndian, true)
        case [0xbf, 0xba, 0xfe, 0xca]:
            fatFormat = (.littleEndian, true)
        default:
            return nil
        }
        guard let architectureCountValue = uint32(
            prefix,
            offset: 4,
            byteOrder: fatFormat.byteOrder
        ),
              architectureCountValue > 0,
              architectureCountValue <= maximumArchitectureCount else {
            return nil
        }
        let architectureCount = Int(architectureCountValue)
        let entryByteCount = fatFormat.is64Bit ? 32 : 20
        guard let entries = read(
            descriptor: descriptor,
            offset: 8,
            byteCount: architectureCount * entryByteCount
        ) else {
            return nil
        }

        var slices: [Slice] = []
        let tableEnd = UInt64(
            8 + architectureCount * entryByteCount
        )
        for index in 0..<architectureCount {
            guard !Task.isCancelled else { return nil }
            let offset = index * entryByteCount
            guard let cpuType = uint32(
                entries,
                offset: offset,
                byteOrder: fatFormat.byteOrder
            ),
                  let cpuSubtype = uint32(
                      entries,
                      offset: offset + 4,
                      byteOrder: fatFormat.byteOrder
                  ) else {
                return nil
            }
            let sliceOffset: UInt64?
            let sliceSize: UInt64?
            let alignmentExponent: UInt32?
            if fatFormat.is64Bit {
                sliceOffset = uint64(
                    entries,
                    offset: offset + 8,
                    byteOrder: fatFormat.byteOrder
                )
                sliceSize = uint64(
                    entries,
                    offset: offset + 16,
                    byteOrder: fatFormat.byteOrder
                )
                alignmentExponent = uint32(
                    entries,
                    offset: offset + 24,
                    byteOrder: fatFormat.byteOrder
                )
            } else {
                sliceOffset = uint32(
                    entries,
                    offset: offset + 8,
                    byteOrder: fatFormat.byteOrder
                ).map(UInt64.init)
                sliceSize = uint32(
                    entries,
                    offset: offset + 12,
                    byteOrder: fatFormat.byteOrder
                ).map(UInt64.init)
                alignmentExponent = uint32(
                    entries,
                    offset: offset + 16,
                    byteOrder: fatFormat.byteOrder
                )
            }
            guard let sliceOffset,
                  let sliceSize,
                  let alignmentExponent,
                  alignmentExponent <= 31,
                  !fatFormat.is64Bit
                    || uint32(
                        entries,
                        offset: offset + 28,
                        byteOrder: fatFormat.byteOrder
                    ) == 0,
                  sliceSize > 0,
                  sliceOffset >= tableEnd,
                  sliceOffset
                    % (UInt64(1) << alignmentExponent) == 0,
                  sliceOffset <= fileByteCount,
                  sliceSize <= fileByteCount - sliceOffset,
                  let slicePrefix = read(
                      descriptor: descriptor,
                      offset: sliceOffset,
                      byteCount: 12
                  ),
                  let thinFormat = thinFormat(
                      Array(slicePrefix.prefix(4))
                  ),
                  uint32(
                      slicePrefix,
                      offset: 4,
                      byteOrder: thinFormat.byteOrder
                  ) == cpuType,
                  uint32(
                      slicePrefix,
                      offset: 8,
                      byteOrder: thinFormat.byteOrder
                  ) == cpuSubtype else {
                return nil
            }
            slices.append(
                Slice(
                    offset: sliceOffset,
                    size: sliceSize,
                    byteOrder: thinFormat.byteOrder,
                    is64Bit: thinFormat.is64Bit,
                    cpuType: cpuType,
                    cpuSubtype: cpuSubtype
                )
            )
        }

        let byOffset = slices.sorted { $0.offset < $1.offset }
        for pair in zip(byOffset, byOffset.dropFirst()) {
            guard pair.0.offset + pair.0.size <= pair.1.offset else {
                return nil
            }
        }
        return slices
    }

    private static func canonicalSlice(
        descriptor: Int32,
        slice: Slice
    ) -> CanonicalSlice? {
        let headerByteCount = slice.is64Bit ? 32 : 28
        guard slice.size >= UInt64(headerByteCount),
              let header = read(
                  descriptor: descriptor,
                  offset: slice.offset,
                  byteCount: headerByteCount
              ),
              let commandCountValue = uint32(
                  header,
                  offset: 16,
                  byteOrder: slice.byteOrder
              ),
              let commandBytesValue = uint32(
                  header,
                  offset: 20,
                  byteOrder: slice.byteOrder
              ),
              commandCountValue > 0,
              commandCountValue <= maximumLoadCommandCount,
              commandBytesValue > 0,
              commandBytesValue <= maximumLoadCommandBytes,
              UInt64(headerByteCount) + UInt64(commandBytesValue)
                  <= slice.size,
              let commands = read(
                  descriptor: descriptor,
                  offset: slice.offset + UInt64(headerByteCount),
                  byteCount: Int(commandBytesValue)
              ) else {
            return nil
        }

        var commandOffset = 0
        var codeSignatureRange: Range<UInt64>?
        var normalizedRanges: [Range<UInt64>] = []
        var segments: [SegmentExtent] = []
        for _ in 0..<Int(commandCountValue) {
            guard !Task.isCancelled,
                  let command = uint32(
                commands,
                offset: commandOffset,
                byteOrder: slice.byteOrder
            ),
                  let commandSizeValue = uint32(
                      commands,
                      offset: commandOffset + 4,
                      byteOrder: slice.byteOrder
                  ),
                  commandSizeValue >= 8,
                  commandSizeValue % 4 == 0 else {
                return nil
            }
            let commandSize = Int(commandSizeValue)
            guard commandOffset <= commands.count - commandSize else {
                return nil
            }
            let commandFileOffset =
                UInt64(headerByteCount + commandOffset)

            if command == codeSignatureCommand {
                guard codeSignatureRange == nil,
                      commandSize == 16,
                      let dataOffset = uint32(
                          commands,
                          offset: commandOffset + 8,
                          byteOrder: slice.byteOrder
                      ),
                      let dataSize = uint32(
                          commands,
                          offset: commandOffset + 12,
                          byteOrder: slice.byteOrder
                      ),
                      dataSize > 0 else {
                    return nil
                }
                let lowerBound = UInt64(dataOffset)
                let upperBound = lowerBound + UInt64(dataSize)
                guard lowerBound >= UInt64(headerByteCount)
                    + UInt64(commandBytesValue),
                      lowerBound % 16 == 0,
                      upperBound == slice.size else {
                    return nil
                }
                codeSignatureRange = lowerBound..<upperBound
                normalizedRanges.append(
                    (commandFileOffset + 8)..<(
                        commandFileOffset + 16
                    )
                )
            } else if command == segment64Command {
                guard slice.is64Bit,
                      commandSize >= 72,
                      let sectionCount = uint32(
                          commands,
                          offset: commandOffset + 64,
                          byteOrder: slice.byteOrder
                      ),
                      UInt64(sectionCount)
                        <= UInt64((Int.max - 72) / 80),
                      commandSize == 72 + Int(sectionCount) * 80,
                      let vmAddress = uint64(
                          commands,
                          offset: commandOffset + 24,
                          byteOrder: slice.byteOrder
                      ),
                      let vmSize = uint64(
                          commands,
                          offset: commandOffset + 32,
                          byteOrder: slice.byteOrder
                      ),
                      let fileOffset = uint64(
                          commands,
                          offset: commandOffset + 40,
                          byteOrder: slice.byteOrder
                      ),
                      let fileSize = uint64(
                          commands,
                          offset: commandOffset + 48,
                          byteOrder: slice.byteOrder
                      ),
                      fileOffset <= slice.size,
                      fileSize <= slice.size - fileOffset,
                      vmAddress <= UInt64.max - vmSize else {
                    return nil
                }
                let isLinkEdit = segmentName(
                    commands,
                    offset: commandOffset + 8
                ) == "__LINKEDIT"
                segments.append(
                    SegmentExtent(
                        isLinkEdit: isLinkEdit,
                        vmAddress: vmAddress,
                        vmSize: vmSize,
                        fileOffset: fileOffset,
                        fileSize: fileSize
                    )
                )
                if isLinkEdit {
                    normalizedRanges.append(
                        (commandFileOffset + 32)..<(
                            commandFileOffset + 40
                        )
                    )
                    normalizedRanges.append(
                        (commandFileOffset + 48)..<(
                            commandFileOffset + 56
                        )
                    )
                }
            } else if command == segmentCommand {
                guard !slice.is64Bit,
                      commandSize >= 56,
                      let sectionCount = uint32(
                          commands,
                          offset: commandOffset + 48,
                          byteOrder: slice.byteOrder
                      ),
                      UInt64(sectionCount)
                        <= UInt64((Int.max - 56) / 68),
                      commandSize == 56 + Int(sectionCount) * 68,
                      let vmAddressValue = uint32(
                          commands,
                          offset: commandOffset + 24,
                          byteOrder: slice.byteOrder
                      ),
                      let vmSizeValue = uint32(
                          commands,
                          offset: commandOffset + 28,
                          byteOrder: slice.byteOrder
                      ),
                      let fileOffsetValue = uint32(
                          commands,
                          offset: commandOffset + 32,
                          byteOrder: slice.byteOrder
                      ),
                      let fileSizeValue = uint32(
                          commands,
                          offset: commandOffset + 36,
                          byteOrder: slice.byteOrder
                      ) else {
                    return nil
                }
                let vmAddress = UInt64(vmAddressValue)
                let vmSize = UInt64(vmSizeValue)
                let fileOffset = UInt64(fileOffsetValue)
                let fileSize = UInt64(fileSizeValue)
                guard fileOffset <= slice.size,
                      fileSize <= slice.size - fileOffset else {
                    return nil
                }
                let isLinkEdit = segmentName(
                    commands,
                    offset: commandOffset + 8
                ) == "__LINKEDIT"
                segments.append(
                    SegmentExtent(
                        isLinkEdit: isLinkEdit,
                        vmAddress: vmAddress,
                        vmSize: vmSize,
                        fileOffset: fileOffset,
                        fileSize: fileSize
                    )
                )
                if isLinkEdit {
                    normalizedRanges.append(
                        (commandFileOffset + 28)..<(
                            commandFileOffset + 32
                        )
                    )
                    normalizedRanges.append(
                        (commandFileOffset + 36)..<(
                            commandFileOffset + 40
                        )
                    )
                }
            }
            commandOffset += commandSize
        }

        let linkEditSegments = segments.filter(\.isLinkEdit)
        guard commandOffset == commands.count,
              let codeSignatureRange,
              linkEditSegments.count == 1,
              let linkEdit = linkEditSegments.first,
              linkEdit.fileSize > 0,
              linkEdit.vmSize > 0 else {
            return nil
        }
        let minimumPageSize: UInt64 = 4 * 1_024
        let vmSizeAlignment: UInt64 = slice.is64Bit
            ? 16 * 1_024
            : minimumPageSize
        guard linkEdit.fileOffset % minimumPageSize == 0,
              linkEdit.vmAddress % minimumPageSize == 0,
              linkEdit.fileOffset + linkEdit.fileSize == slice.size,
              roundedUp(
                  linkEdit.fileSize,
                  toMultipleOf: vmSizeAlignment
              ) == linkEdit.vmSize,
              codeSignatureRange.lowerBound >= linkEdit.fileOffset,
              codeSignatureRange.upperBound
                == linkEdit.fileOffset + linkEdit.fileSize,
              segments.filter({ !$0.isLinkEdit }).allSatisfy({
                  !rangesOverlap(
                      $0.fileOffset,
                      $0.fileSize,
                      linkEdit.fileOffset,
                      linkEdit.fileSize
                  ) && !rangesOverlap(
                      $0.vmAddress,
                      $0.vmSize,
                      linkEdit.vmAddress,
                      linkEdit.vmSize
                  )
              }),
              normalizedRanges.allSatisfy({
                  $0.lowerBound < $0.upperBound
                      && $0.upperBound <= codeSignatureRange.lowerBound
              }) else {
            return nil
        }
        return CanonicalSlice(
            cpuType: slice.cpuType,
            cpuSubtype: slice.cpuSubtype,
            byteCount: codeSignatureRange.lowerBound,
            slice: slice,
            normalizedRanges: normalizedRanges
        )
    }

    private static func roundedUp(
        _ value: UInt64,
        toMultipleOf alignment: UInt64
    ) -> UInt64? {
        guard alignment > 0 else { return nil }
        let remainder = value % alignment
        guard remainder != 0 else { return value }
        let increment = alignment - remainder
        guard value <= UInt64.max - increment else { return nil }
        return value + increment
    }

    private static func rangesOverlap(
        _ firstOffset: UInt64,
        _ firstSize: UInt64,
        _ secondOffset: UInt64,
        _ secondSize: UInt64
    ) -> Bool {
        guard firstSize > 0, secondSize > 0 else { return false }
        return firstOffset < secondOffset + secondSize
            && secondOffset < firstOffset + firstSize
    }

    private static func hash(
        descriptor: Int32,
        fileOffset: UInt64,
        byteCount: UInt64,
        normalizedRanges: [Range<UInt64>]
    ) -> Data? {
        let ranges = normalizedRanges.sorted {
            $0.lowerBound < $1.lowerBound
        }
        for pair in zip(ranges, ranges.dropFirst()) {
            guard pair.0.upperBound <= pair.1.lowerBound else {
                return nil
            }
        }

        var hasher = SHA256()
        var cursor: UInt64 = 0
        for range in ranges {
            guard range.lowerBound >= cursor,
                  stream(
                      descriptor: descriptor,
                      offset: fileOffset + cursor,
                      byteCount: range.lowerBound - cursor,
                      hasher: &hasher
                  ) else {
                return nil
            }
            updateZeros(
                byteCount: range.upperBound - range.lowerBound,
                hasher: &hasher
            )
            cursor = range.upperBound
        }
        guard cursor <= byteCount,
              stream(
                  descriptor: descriptor,
                  offset: fileOffset + cursor,
                  byteCount: byteCount - cursor,
                  hasher: &hasher
              ) else {
            return nil
        }
        return Data(hasher.finalize())
    }

    private static func stream(
        descriptor: Int32,
        offset: UInt64,
        byteCount: UInt64,
        hasher: inout SHA256
    ) -> Bool {
        var buffer = [UInt8](
            repeating: 0,
            count: streamBufferByteCount
        )
        var consumed: UInt64 = 0
        while consumed < byteCount {
            guard !Task.isCancelled else { return false }
            let requested = min(
                buffer.count,
                Int(byteCount - consumed)
            )
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress,
                    requested,
                    off_t(offset + consumed)
                )
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard bytesRead > 0 else { return false }
            hasher.update(data: Data(buffer.prefix(bytesRead)))
            consumed += UInt64(bytesRead)
        }
        return true
    }

    private static func read(
        descriptor: Int32,
        offset: UInt64,
        byteCount: Int
    ) -> Data? {
        guard byteCount >= 0,
              offset <= UInt64(off_t.max),
              UInt64(byteCount)
                  <= UInt64(off_t.max) - offset else {
            return nil
        }
        var data = Data(count: byteCount)
        var consumed = 0
        let succeeded = data.withUnsafeMutableBytes { bytes -> Bool in
            while consumed < byteCount {
                guard !Task.isCancelled else { return false }
                let bytesRead = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: consumed),
                    byteCount - consumed,
                    off_t(offset) + off_t(consumed)
                )
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard bytesRead > 0 else { return false }
                consumed += bytesRead
            }
            return true
        }
        return succeeded ? data : nil
    }

    private static func thinFormat(
        _ magic: [UInt8]
    ) -> (byteOrder: ByteOrder, is64Bit: Bool)? {
        switch magic {
        case [0xce, 0xfa, 0xed, 0xfe]:
            (.littleEndian, false)
        case [0xcf, 0xfa, 0xed, 0xfe]:
            (.littleEndian, true)
        case [0xfe, 0xed, 0xfa, 0xce]:
            (.bigEndian, false)
        case [0xfe, 0xed, 0xfa, 0xcf]:
            (.bigEndian, true)
        default:
            nil
        }
    }

    private static func uint32(
        _ data: Data,
        offset: Int,
        byteOrder: ByteOrder
    ) -> UInt32? {
        guard offset >= 0,
              offset <= data.count - 4 else {
            return nil
        }
        let bytes = (0..<4).map { data[offset + $0] }
        switch byteOrder {
        case .littleEndian:
            return bytes.enumerated().reduce(0) {
                $0 | UInt32($1.element) << UInt32($1.offset * 8)
            }
        case .bigEndian:
            return bytes.reduce(0) {
                $0 << 8 | UInt32($1)
            }
        }
    }

    private static func uint64(
        _ data: Data,
        offset: Int,
        byteOrder: ByteOrder
    ) -> UInt64? {
        guard offset >= 0,
              offset <= data.count - 8 else {
            return nil
        }
        let bytes = (0..<8).map { data[offset + $0] }
        switch byteOrder {
        case .littleEndian:
            return bytes.enumerated().reduce(0) {
                $0 | UInt64($1.element) << UInt64($1.offset * 8)
            }
        case .bigEndian:
            return bytes.reduce(0) {
                $0 << 8 | UInt64($1)
            }
        }
    }

    private static func segmentName(
        _ data: Data,
        offset: Int
    ) -> String? {
        guard offset >= 0,
              offset <= data.count - 16 else {
            return nil
        }
        let bytes = data[offset..<(offset + 16)]
            .prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func update<T: FixedWidthInteger>(
        _ value: T,
        hasher: inout SHA256
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) {
            hasher.update(data: Data($0))
        }
    }

    private static func updateZeros(
        byteCount: UInt64,
        hasher: inout SHA256
    ) {
        let zeros = Data(
            repeating: 0,
            count: streamBufferByteCount
        )
        var remaining = byteCount
        while remaining > 0 {
            let count = min(zeros.count, Int(remaining))
            hasher.update(data: zeros.prefix(count))
            remaining -= UInt64(count)
        }
    }

    private static func sameIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

actor WineDesktopShortcutHelperIdentityCache {
    typealias Analyzer = @Sendable (
        URL,
        WineDesktopShortcutHelperProfile?
    ) -> WineDesktopShortcutHelperAnalysis?

    private struct RequestKey: Hashable {
        let snapshot: WineDesktopShortcutHelperFileSnapshot
        let expectedProfile: WineDesktopShortcutHelperProfile?
    }

    private struct InFlightAnalysis {
        let id: UUID
        let generation: UInt64
        let task: Task<
            WineDesktopShortcutHelperAnalysis?,
            Never
        >
        var waiterIDs: Set<UUID>
    }

    private let maximumEntryCount: Int
    private let analyzer: Analyzer
    private var cachedBySnapshot:
        [WineDesktopShortcutHelperFileSnapshot:
            WineDesktopShortcutHelperAnalysis] = [:]
    private var cacheOrder:
        [WineDesktopShortcutHelperFileSnapshot] = []
    private var rejectedRequests: Set<RequestKey> = []
    private var inFlight: [RequestKey: InFlightAnalysis] = [:]
    private var analysisExecutionCount = 0
    private var generation: UInt64 = 0

    init(
        maximumEntryCount: Int = 1_024,
        analyzer: @escaping Analyzer = {
            WineDesktopShortcutHelperIdentityReader.analysis(
                at: $0,
                matching: $1
            )
        }
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.analyzer = analyzer
    }

    func analysis(
        at url: URL,
        matching expectedProfile:
            WineDesktopShortcutHelperProfile? = nil
    ) async throws -> WineDesktopShortcutHelperAnalysis? {
        try Task.checkCancellation()
        guard let snapshot =
            WineDesktopShortcutHelperIdentityReader.fileSnapshot(
                at: url
            ) else {
            return nil
        }
        if let cached = cachedBySnapshot[snapshot] {
            try Task.checkCancellation()
            return expectedProfile == nil
                    || cached.profile == expectedProfile
                ? cached
                : nil
        }

        let request = RequestKey(
            snapshot: snapshot,
            expectedProfile: expectedProfile
        )
        guard !rejectedRequests.contains(request) else {
            return nil
        }

        let waiterID = UUID()
        let flight: InFlightAnalysis
        if var existing = inFlight[request] {
            existing.waiterIDs.insert(waiterID)
            inFlight[request] = existing
            flight = existing
        } else {
            let analyzer = analyzer
            let task = Task.detached(priority: .utility) {
                analyzer(url, expectedProfile)
            }
            flight = InFlightAnalysis(
                id: UUID(),
                generation: generation,
                task: task,
                waiterIDs: [waiterID]
            )
            inFlight[request] = flight
            analysisExecutionCount += 1
        }

        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    request: request,
                    flightID: flight.id
                )
            }
        }
        completeFlight(
            request: request,
            flightID: flight.id
        )
        try Task.checkCancellation()
        guard generation == flight.generation else {
            return nil
        }
        guard WineDesktopShortcutHelperIdentityReader.fileSnapshot(
            at: url
        ) == snapshot else {
            return nil
        }
        guard let result else {
            rejectedRequests.insert(request)
            trimIfNeeded()
            return nil
        }
        guard expectedProfile == nil
                || result.profile == expectedProfile,
              result.fileSnapshot == snapshot else {
            rejectedRequests.insert(request)
            trimIfNeeded()
            return nil
        }
        store(result, for: snapshot)
        return result
    }

    func removeAll() {
        generation &+= 1
        for flight in inFlight.values {
            flight.task.cancel()
        }
        cachedBySnapshot.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        rejectedRequests.removeAll(keepingCapacity: false)
        inFlight.removeAll(keepingCapacity: false)
    }

    func analysisExecutionCountForTesting() -> Int {
        analysisExecutionCount
    }

    func inFlightCountForTesting() -> Int {
        inFlight.count
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        request: RequestKey,
        flightID: UUID
    ) {
        guard var flight = inFlight[request],
              flight.id == flightID else {
            return
        }
        flight.waiterIDs.remove(waiterID)
        guard !flight.waiterIDs.isEmpty else {
            inFlight.removeValue(forKey: request)
            flight.task.cancel()
            return
        }
        inFlight[request] = flight
    }

    private func completeFlight(
        request: RequestKey,
        flightID: UUID
    ) {
        guard inFlight[request]?.id == flightID else {
            return
        }
        inFlight.removeValue(forKey: request)
    }

    private func store(
        _ analysis: WineDesktopShortcutHelperAnalysis,
        for snapshot: WineDesktopShortcutHelperFileSnapshot
    ) {
        if cachedBySnapshot.updateValue(
            analysis,
            forKey: snapshot
        ) == nil {
            cacheOrder.append(snapshot)
        }
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        while cachedBySnapshot.count > maximumEntryCount,
              let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cachedBySnapshot.removeValue(forKey: oldest)
        }
        if rejectedRequests.count > maximumEntryCount {
            rejectedRequests.removeAll(keepingCapacity: true)
        }
    }
}

@MainActor
final class WineDesktopShortcutBridge {
    typealias CommitCheckpoint = @MainActor (
        WineDesktopShortcutCommitCheckpoint
    ) throws -> Void
    typealias StableIdentityAnalyzer = @Sendable (
        URL,
        Int
    ) -> WineDesktopShortcutBundleStableIdentity?

    private struct ShortcutCandidate {
        var id: String
        var entry: WineDesktopShortcutManifestEntry
        var container: Container
        var containerName: String
        var verifiedSourceURL: URL
        var verifiedIconURL: URL?
    }

    fileprivate struct DesiredShortcut {
        var id: String
        var displayName: String
        var containerName: String
        var sourceURL: URL
        var iconURL: URL?
        var route: WineDesktopShortcutRoute
    }

    private struct Placement {
        var desired: DesiredShortcut
        var bundleURL: URL
    }

    private struct PlacementIdentityCandidate {
        let placement: Placement
        let executableURL: URL
        let iconDigest: String?
    }

    private struct StagedPlacement {
        let placement: Placement
        let temporaryURL: URL
        let executableURL: URL
        let helperAnalysis: WineDesktopShortcutHelperAnalysis
        let helperDigest: String
        let iconDigest: String?
        let signatureSnapshot:
            WineDesktopShortcutBundleSignatureSnapshot?
    }

    private struct BundleBackup {
        let originalURL: URL
        let backupURL: URL
        let removedShortcutName: String?
        let originalIdentity:
            WineDesktopShortcutBundleStableIdentity
    }

    private struct BundleBackupCandidate {
        let originalURL: URL
        let removedShortcutName: String?
    }

    private struct ShortcutTransactionJournal: Codable {
        enum State: String, Codable {
            case preparing
            case committed
            case rolledBack
        }

        struct Backup: Codable {
            let originalName: String
            let backupName: String
            let originalIdentity:
                WineDesktopShortcutBundleStableIdentity
        }

        struct Target: Codable {
            let bundleName: String
            let shortcutID: String
            let stableIdentity:
                WineDesktopShortcutBundleStableIdentity
        }

        var state: State
        let transactionID: String
        let backups: [Backup]
        let targets: [Target]
        let previousRouteData: Data?
    }

    struct PreparedRefresh {
        let observedDependencyURLs: Set<URL>
        let digestURLs: Set<URL>

        fileprivate let desired: [DesiredShortcut]
        fileprivate let helperURL: URL?
        fileprivate let wineURL: URL
        fileprivate let runnerURL: URL
        fileprivate let dependencyStamps:
            [URL: WineBridgeFileStamp]
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let desktopURL: URL
    private let helperIdentityCache:
        WineDesktopShortcutHelperIdentityCache
    private let bundleSignatureCache:
        WineDesktopShortcutBundleSignatureCache
    private let stableIdentityAnalyzer:
        StableIdentityAnalyzer
    private let commitCheckpoint: CommitCheckpoint

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        desktopURL: URL? = nil,
        helperIdentityCache:
            WineDesktopShortcutHelperIdentityCache =
                WineDesktopShortcutHelperIdentityCache(),
        bundleSignatureCache:
            WineDesktopShortcutBundleSignatureCache =
                WineDesktopShortcutBundleSignatureCache(),
        stableIdentityAnalyzer:
            @escaping StableIdentityAnalyzer = {
                WineDesktopShortcutBundleSignatureVerifier
                    .stableIdentity(
                        at: $0,
                        maximumEntryCount: $1
                    )
            },
        commitCheckpoint:
            @escaping CommitCheckpoint = { _ in }
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Switchyard", isDirectory: true)
                .appendingPathComponent("DesktopShortcutBridge", isDirectory: true)
        self.desktopURL = desktopURL
            ?? fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        self.helperIdentityCache = helperIdentityCache
        self.bundleSignatureCache = bundleSignatureCache
        self.stableIdentityAnalyzer = stableIdentityAnalyzer
        self.commitCheckpoint = commitCheckpoint
    }

    func refresh(
        containers: [Container],
        winePath: String,
        runnerPath: String
    ) async throws -> WineDesktopShortcutBridgeRefreshResult {
        let prepared = try prepareRefresh(
            containers: containers,
            winePath: winePath,
            runnerPath: runnerPath
        )
        let fileDigests = try Dictionary(
            uniqueKeysWithValues: prepared.digestURLs.map { url in
                (url, try sha256Hex(of: url))
            }
        )
        return try await refresh(
            prepared,
            fileDigests: fileDigests
        )
    }

    func prepareRefresh(
        containers: [Container],
        winePath: String,
        runnerPath: String
    ) throws -> PreparedRefresh {
        try prepareRefresh(
            containers: containers,
            indexedMetadataByContainerID: nil,
            winePath: winePath,
            runnerPath: runnerPath
        )
    }

    func prepareRefresh(
        containers: [Container],
        indexedMetadataByContainerID:
            [UUID: ContainerBridgeIndexMetadata],
        winePath: String,
        runnerPath: String
    ) throws -> PreparedRefresh {
        try prepareRefresh(
            containers: containers,
            indexedMetadataByContainerID:
                Optional(indexedMetadataByContainerID),
            winePath: winePath,
            runnerPath: runnerPath
        )
    }

    private func prepareRefresh(
        containers: [Container],
        indexedMetadataByContainerID:
            [UUID: ContainerBridgeIndexMetadata]?,
        winePath: String,
        runnerPath: String
    ) throws -> PreparedRefresh {
        let wineURL = URL(fileURLWithPath: winePath).standardizedFileURL
        let runnerURL = URL(
            fileURLWithPath: runnerPath
        ).standardizedFileURL
        var observedDependencyURLs = Set(
            containers.map {
                WineDesktopShortcutFormat.manifestURL(
                    prefixPath: $0.path
                ).standardizedFileURL
            }
        )
        observedDependencyURLs.insert(wineURL)
        observedDependencyURLs.insert(runnerURL)
        if let indexedMetadataByContainerID {
            for metadata in indexedMetadataByContainerID.values {
                for dependency in metadata.dependencies {
                    switch dependency.role {
                    case .desktopShortcutManifest,
                         .desktopShortcut,
                         .desktopShortcutIcon:
                        observedDependencyURLs.insert(
                            URL(
                                fileURLWithPath:
                                    dependency.path
                            ).standardizedFileURL
                        )
                    case .protocolManifest:
                        break
                    }
                }
            }
        }
        var preparedDependencyStamps = dependencyStamps(
            for: observedDependencyURLs
        )
        if let indexedMetadataByContainerID {
            for metadata in indexedMetadataByContainerID.values {
                for dependency in metadata.dependencies {
                    guard let fileStamp = dependency.fileStamp else {
                        continue
                    }
                    let dependencyURL = URL(
                        fileURLWithPath: dependency.path
                    ).standardizedFileURL
                    preparedDependencyStamps[
                        dependencyURL
                    ] = fileStamp
                }
            }
        }

        guard fileManager.isExecutableFile(atPath: winePath),
              fileManager.isExecutableFile(atPath: runnerPath) else {
            return PreparedRefresh(
                observedDependencyURLs: observedDependencyURLs,
                digestURLs: [],
                desired: [],
                helperURL: nil,
                wineURL: wineURL,
                runnerURL: runnerURL,
                dependencyStamps: dependencyStamps(
                    for: observedDependencyURLs,
                    preferred: preparedDependencyStamps
                )
            )
        }

        let desired = desiredShortcuts(
            containers: containers,
            indexedMetadataByContainerID:
                indexedMetadataByContainerID,
            winePath: winePath,
            runnerPath: runnerPath
        )
        for shortcut in desired {
            observedDependencyURLs.insert(
                shortcut.sourceURL.standardizedFileURL
            )
            if let iconURL = shortcut.iconURL {
                observedDependencyURLs.insert(
                    iconURL.standardizedFileURL
                )
            }
        }

        let helperURL = try desired.isEmpty
            ? nil
            : locateShortcutHandler().standardizedFileURL
        var digestURLs = Set(
            desired.compactMap(\.iconURL).map(\.standardizedFileURL)
        )
        if let helperURL {
            digestURLs.insert(helperURL)
            observedDependencyURLs.insert(helperURL)
        }

        return PreparedRefresh(
            observedDependencyURLs: observedDependencyURLs,
            digestURLs: digestURLs,
            desired: desired,
            helperURL: helperURL,
            wineURL: wineURL,
            runnerURL: runnerURL,
            dependencyStamps: dependencyStamps(
                for: observedDependencyURLs,
                preferred: preparedDependencyStamps
            )
        )
    }

    func refresh(
        _ prepared: PreparedRefresh,
        fileDigests: [URL: String],
        isStillCurrent: @escaping @MainActor () -> Bool = { true }
    ) async throws -> WineDesktopShortcutBridgeRefreshResult {
        try fileManager.createDirectory(
            at: desktopURL,
            withIntermediateDirectories: true
        )
        try prepareBridgeRoot()
        try await recoverShortcutTransactions()
        let preparedRefreshIsStillCurrent: @MainActor () -> Bool = {
            !Task.isCancelled
                && isStillCurrent()
                && self.dependenciesAreCurrent(prepared)
        }
        guard fileManager.isExecutableFile(
            atPath: prepared.wineURL.path
        ),
              fileManager.isExecutableFile(
                  atPath: prepared.runnerURL.path
              ) else {
            return WineDesktopShortcutBridgeRefreshResult(
                createdShortcutNames: [],
                removedShortcutNames: []
            )
        }

        let desired = prepared.desired
        guard !desired.isEmpty else {
            let removedNames = try await commitRefresh(
                staged: [],
                placements: [],
                routes: [],
                isStillCurrent: preparedRefreshIsStillCurrent
            )
            return WineDesktopShortcutBridgeRefreshResult(
                createdShortcutNames: [],
                removedShortcutNames: removedNames.sorted()
            )
        }

        guard let helperURL = prepared.helperURL else {
            throw WineDesktopShortcutBridgeError.missingShortcutHandler
        }
        let helperDigest = try digest(
            of: helperURL,
            cachedDigests: fileDigests
        )
        guard let helperAnalysis = try await helperIdentityCache.analysis(
            at: helperURL
        ),
              WineDesktopShortcutHelperIdentityReader.fileSnapshot(
                  at: helperURL
              ) == helperAnalysis.fileSnapshot else {
            throw POSIXError(.ENOEXEC)
        }
        let placements = try makePlacements(for: desired)
        var candidates: [PlacementIdentityCandidate] = []
        for placement in placements {
            let iconDigest = try placement.desired.iconURL.map {
                try digest(of: $0, cachedDigests: fileDigests)
            }
            let executableURL = helperExecutableURL(
                at: placement.bundleURL
            )
            if bundleMetadataMatches(
                at: placement.bundleURL,
                desired: placement.desired,
                helperDigest: helperDigest,
                iconDigest: iconDigest
            ),
               fileManager.isExecutableFile(
                   atPath: executableURL.path
               ) {
                candidates.append(
                    PlacementIdentityCandidate(
                        placement: placement,
                        executableURL: executableURL,
                        iconDigest: iconDigest
                    )
                )
            }
        }

        let candidateSignatureSnapshots =
            try await signatureSnapshots(
                for: candidates.map {
                    $0.placement.bundleURL
                }
            )
        let signatureCandidates = candidates.filter { candidate in
            guard let signatureSnapshot =
                candidateSignatureSnapshots[
                    candidate.placement.bundleURL
                ] else {
                return false
            }
            return WineDesktopShortcutBundleSignatureVerifier
                .snapshot(at: candidate.placement.bundleURL)
                    == signatureSnapshot
        }
        let candidateAnalyses = try await helperAnalyses(
            for: signatureCandidates.map(\.executableURL),
            matching: helperAnalysis.profile
        )
        let identityCandidates = signatureCandidates.filter {
            candidate in
            guard let analysis =
                candidateAnalyses[candidate.executableURL] else {
                return false
            }
            return analysis.identity == helperAnalysis.identity
                && WineDesktopShortcutHelperIdentityReader
                    .fileSnapshot(at: candidate.executableURL)
                    == analysis.fileSnapshot
        }
        let currentIDs = Set(
            identityCandidates.map(\.placement.desired.id)
        )

        var staged: [StagedPlacement] = []
        defer {
            for stagedPlacement in staged {
                try? fileManager.removeItem(
                    at: stagedPlacement.temporaryURL
                )
            }
        }
        for placement in placements
        where !currentIDs.contains(placement.desired.id) {
            let iconDigest = try placement.desired.iconURL.map {
                try digest(of: $0, cachedDigests: fileDigests)
            }
            staged.append(
                try await stageBundle(
                    placement,
                    helperURL: helperURL,
                    helperDigest: helperDigest,
                    helperAnalysis: helperAnalysis,
                    iconDigest: iconDigest
                )
            )
        }
        let stagedSignatureSnapshots =
            try await signatureSnapshots(
                for: staged.map(\.temporaryURL)
            )
        guard stagedSignatureSnapshots.count == staged.count else {
            throw POSIXError(.EIO)
        }
        staged = staged.map { stagedPlacement in
            verifiedStagedPlacement(
                stagedPlacement,
                signatureSnapshot:
                    stagedSignatureSnapshots[
                        stagedPlacement.temporaryURL
                    ]
            )
        }

        guard !Task.isCancelled,
              WineDesktopShortcutHelperIdentityReader.fileSnapshot(
                  at: helperURL
              ) == helperAnalysis.fileSnapshot,
              candidates.allSatisfy({ candidate in
                  guard currentIDs.contains(
                      candidate.placement.desired.id
                  ),
                        let analysis =
                          candidateAnalyses[
                              candidate.executableURL
                          ],
                        let signatureSnapshot =
                          candidateSignatureSnapshots[
                              candidate.placement.bundleURL
                          ] else {
                      return true
                  }
                  return WineDesktopShortcutHelperIdentityReader
                      .fileSnapshot(at: candidate.executableURL)
                      == analysis.fileSnapshot
                      && bundleMetadataMatches(
                          at: candidate.placement.bundleURL,
                          desired: candidate.placement.desired,
                          helperDigest: helperDigest,
                          iconDigest: candidate.iconDigest
                      )
                      && WineDesktopShortcutBundleSignatureVerifier
                        .snapshot(
                            at: candidate.placement.bundleURL
                        ) == signatureSnapshot
              }),
              staged.allSatisfy({
                  isStagedPlacementCurrent($0)
                      && $0.helperAnalysis.identity
                        == helperAnalysis.identity
              }) else {
            throw CancellationError()
        }

        let removedNames = try await commitRefresh(
            staged: staged,
            placements: placements,
            routes: desired.map(\.route),
            isStillCurrent: preparedRefreshIsStillCurrent
        )

        return WineDesktopShortcutBridgeRefreshResult(
            createdShortcutNames: staged.map {
                $0.placement.desired.displayName
            }.sorted(),
            removedShortcutNames: removedNames
        )
    }

    private func dependencyStamps(
        for urls: Set<URL>,
        preferred: [URL: WineBridgeFileStamp] = [:]
    ) -> [URL: WineBridgeFileStamp] {
        Dictionary(
            uniqueKeysWithValues: urls.map {
                let normalizedURL = $0.standardizedFileURL
                return (
                    normalizedURL,
                    preferred[normalizedURL]
                        ?? WineBridgeFileStamp.read(
                            from: normalizedURL
                        )
                )
            }
        )
    }

    private func dependenciesAreCurrent(
        _ prepared: PreparedRefresh
    ) -> Bool {
        prepared.dependencyStamps.allSatisfy {
            WineBridgeFileStamp.read(from: $0.key) == $0.value
        }
    }

    private func prepareBridgeRoot() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        var status = stat()
        guard Darwin.lstat(rootURL.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFDIR) else {
            throw POSIXError(.EIO)
        }
        guard status.st_mode & mode_t(0o777)
                == mode_t(S_IRWXU)
                || Darwin.chmod(
                    rootURL.path,
                    mode_t(S_IRWXU)
                ) == 0 else {
            throw POSIXError(.EACCES)
        }
        guard discardRecoverableRouteTemporaryFile() else {
            throw POSIXError(.EIO)
        }
    }

    private func helperExecutableURL(at bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent(
                "Contents/MacOS",
                isDirectory: true
            )
            .appendingPathComponent(
                "switchyard-shortcut-handler"
            )
    }

    private func stableIdentity(
        at url: URL,
        maximumEntryCount: Int =
            WineDesktopShortcutPersistenceLimits
                .maximumBundleTreeEntryCount
    ) async throws
        -> WineDesktopShortcutBundleStableIdentity?
    {
        let analyzer = stableIdentityAnalyzer
        let task = Task.detached(priority: .utility) {
            analyzer(url, maximumEntryCount)
        }
        let identity = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return identity
    }

    private func transactionStableIdentity(
        at url: URL
    ) async -> WineDesktopShortcutBundleStableIdentity? {
        let analyzer = stableIdentityAnalyzer
        return await Task.detached(priority: .utility) {
            analyzer(
                url,
                WineDesktopShortcutPersistenceLimits
                    .maximumBundleTreeEntryCount
            )
        }.value
    }

    private func helperAnalyses(
        for urls: [URL],
        matching profile: WineDesktopShortcutHelperProfile
    ) async throws -> [URL: WineDesktopShortcutHelperAnalysis] {
        let uniqueURLs = Array(Set(urls)).sorted {
            $0.path < $1.path
        }
        let cache = helperIdentityCache
        var analyses:
            [URL: WineDesktopShortcutHelperAnalysis] = [:]
        var lowerBound = 0
        while lowerBound < uniqueURLs.count {
            let upperBound = min(
                lowerBound + 4,
                uniqueURLs.count
            )
            let batch = uniqueURLs[lowerBound..<upperBound]
            try await withThrowingTaskGroup(
                of: (
                    URL,
                    WineDesktopShortcutHelperAnalysis?
                ).self
            ) { group in
                for url in batch {
                    group.addTask {
                        (
                            url,
                            try await cache.analysis(
                                at: url,
                                matching: profile
                            )
                        )
                    }
                }
                for try await (url, analysis) in group {
                    if let analysis {
                        analyses[url] = analysis
                    }
                }
            }
            lowerBound = upperBound
        }
        return analyses
    }

    private func signatureSnapshots(
        for urls: [URL]
    ) async throws -> [
        URL: WineDesktopShortcutBundleSignatureSnapshot
    ] {
        let cache = bundleSignatureCache
        let uniqueURLs = Array(Set(urls)).sorted {
            $0.path < $1.path
        }
        var snapshots:
            [URL: WineDesktopShortcutBundleSignatureSnapshot] = [:]
        var lowerBound = 0
        while lowerBound < uniqueURLs.count {
            try Task.checkCancellation()
            let upperBound = min(
                lowerBound + 4,
                uniqueURLs.count
            )
            let batch = uniqueURLs[lowerBound..<upperBound]
            await withTaskGroup(
                of: (
                    URL,
                    WineDesktopShortcutBundleSignatureSnapshot?
                ).self
            ) { group in
                for url in batch {
                    group.addTask {
                        (
                            url,
                            try? await cache.analysis(at: url)
                        )
                    }
                }
                for await (url, snapshot) in group {
                    if let snapshot {
                        snapshots[url] = snapshot
                    }
                }
            }
            lowerBound = upperBound
        }
        try Task.checkCancellation()
        return snapshots
    }

    // Discovery-only seam keeps limit tests independent from codesigning and Desktop writes.
    func desiredShortcutRoutesForTesting(
        containers: [Container],
        winePath: String,
        runnerPath: String
    ) -> [WineDesktopShortcutRoute] {
        desiredShortcuts(
            containers: containers,
            winePath: winePath,
            runnerPath: runnerPath
        ).map(\.route)
    }

    func desiredShortcutRoutesForTesting(
        containers: [Container],
        indexedMetadataByContainerID:
            [UUID: ContainerBridgeIndexMetadata],
        winePath: String,
        runnerPath: String
    ) -> [WineDesktopShortcutRoute] {
        desiredShortcuts(
            containers: containers,
            indexedMetadataByContainerID:
                indexedMetadataByContainerID,
            winePath: winePath,
            runnerPath: runnerPath
        ).map(\.route)
    }

    private func desiredShortcuts(
        containers: [Container],
        indexedMetadataByContainerID:
            [UUID: ContainerBridgeIndexMetadata]? = nil,
        winePath: String,
        runnerPath: String
    ) -> [DesiredShortcut] {
        var candidatesByID: [String: ShortcutCandidate] = [:]
        for container in containers {
            let entries: [WineDesktopShortcutManifestEntry]
            if let indexedMetadataByContainerID {
                // Missing indexed data is deliberately fail-closed. Falling back
                // to disk here would restore one manifest scan per bridge.
                entries =
                    indexedMetadataByContainerID[container.id]?
                        .desktopShortcutEntries ?? []
            } else {
                let manifestURL = WineDesktopShortcutFormat.manifestURL(
                    prefixPath: container.path
                )
                guard let contents = WineManifestFileReader.contents(
                    at: manifestURL,
                    insidePrefix: container.path,
                    maximumBytes:
                        WineDesktopShortcutFormat.maximumManifestBytes
                ) else {
                    continue
                }
                entries = WineDesktopShortcutFormat.entries(
                    inManifest: contents
                )
            }

            for entry in entries {
                guard let sourceURL = WineDesktopShortcutFormat.hostShortcutURL(
                    windowsPath: entry.windowsShortcutPath,
                    prefixPath: container.path
                ) else {
                    continue
                }
                if indexedMetadataByContainerID == nil,
                   !isRegularNonSymbolicFile(sourceURL) {
                    continue
                }
                let iconURL = entry.windowsIconPath.flatMap {
                    WineDesktopShortcutFormat.hostIconURL(
                        windowsPath: $0,
                        prefixPath: container.path
                    )
                }.flatMap {
                    indexedMetadataByContainerID != nil
                        || isRegularNonSymbolicFile($0)
                        ? $0
                        : nil
                }
                let id = shortcutID(containerID: container.id, windowsPath: entry.windowsShortcutPath)
                let candidate = ShortcutCandidate(
                    id: id,
                    entry: entry,
                    container: container,
                    containerName: WineDesktopShortcutFormat.nativeDisplayName(container.name)
                        ?? "Switchyard",
                    verifiedSourceURL: sourceURL,
                    verifiedIconURL: iconURL
                )
                insertBoundedCandidate(candidate, into: &candidatesByID)
            }
        }

        var desired: [DesiredShortcut] = []
        for candidate in candidatesByID.values.sorted(by: candidatePrecedes) {
            let entry = candidate.entry
            let container = candidate.container
            desired.append(
                DesiredShortcut(
                    id: candidate.id,
                    displayName: entry.displayName,
                    containerName: candidate.containerName,
                    sourceURL: candidate.verifiedSourceURL,
                    iconURL: candidate.verifiedIconURL,
                    route: WineDesktopShortcutRoute(
                        id: candidate.id,
                        containerID: container.id,
                        prefixPath: container.path,
                        winePath: winePath,
                        runnerPath: runnerPath,
                        windowsShortcutPath: entry.windowsShortcutPath,
                        rosettaAVXAdvertisingPreference:
                            RosettaAVXAdvertisingPolicy.explicitPreference(
                                in: container.environmentOverrides
                            )
                    )
                )
            )
        }
        return desired
    }

    private func insertBoundedCandidate(
        _ candidate: ShortcutCandidate,
        into candidatesByID: inout [String: ShortcutCandidate]
    ) {
        candidatesByID[candidate.id] = candidate
        guard candidatesByID.count > WineDesktopShortcutFormat.maximumEntries,
              let excluded = candidatesByID.values.max(by: candidatePrecedes) else {
            return
        }
        candidatesByID.removeValue(forKey: excluded.id)
    }

    private func candidatePrecedes(_ lhs: ShortcutCandidate, _ rhs: ShortcutCandidate) -> Bool {
        let displayComparison = stableCompare(lhs.entry.displayName, rhs.entry.displayName)
        if displayComparison != .orderedSame {
            return displayComparison == .orderedAscending
        }
        let containerComparison = stableCompare(lhs.containerName, rhs.containerName)
        if containerComparison != .orderedSame {
            return containerComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func stableCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func makePlacements(for desired: [DesiredShortcut]) throws -> [Placement] {
        let managedByPath = try managedBundles().reduce(into: [String: String]()) { result, item in
            result[pathKey(item.url)] = item.id
        }
        var reservedPaths: Set<String> = []
        var placements: [Placement] = []

        for shortcut in desired {
            let bases = [
                shortcut.displayName,
                "\(shortcut.displayName) — \(shortcut.containerName)",
                "\(shortcut.displayName) (Switchyard)"
            ]
            var selectedURL: URL?
            for base in bases {
                let candidate = desktopURL.appendingPathComponent("\(base).app", isDirectory: true)
                if isAvailable(candidate, for: shortcut.id, managedByPath: managedByPath, reserved: reservedPaths) {
                    selectedURL = candidate
                    break
                }
            }
            if selectedURL == nil {
                for suffix in 2...999 {
                    let candidate = desktopURL.appendingPathComponent(
                        "\(shortcut.displayName) (Switchyard \(suffix)).app",
                        isDirectory: true
                    )
                    if isAvailable(candidate, for: shortcut.id, managedByPath: managedByPath, reserved: reservedPaths) {
                        selectedURL = candidate
                        break
                    }
                }
            }
            guard let selectedURL else {
                throw WineDesktopShortcutBridgeError.desktopNameCollision(shortcut.displayName)
            }
            reservedPaths.insert(pathKey(selectedURL))
            placements.append(Placement(desired: shortcut, bundleURL: selectedURL))
        }
        return placements
    }

    private func isAvailable(
        _ url: URL,
        for id: String,
        managedByPath: [String: String],
        reserved: Set<String>
    ) -> Bool {
        let key = pathKey(url)
        guard !reserved.contains(key) else { return false }
        if !fileManager.fileExists(atPath: url.path) { return true }
        return managedByPath[key] == id
    }

    private func stageBundle(
        _ placement: Placement,
        helperURL: URL,
        helperDigest: String,
        helperAnalysis: WineDesktopShortcutHelperAnalysis,
        iconDigest: String?
    ) async throws -> StagedPlacement {
        let temporaryURL = desktopURL.appendingPathComponent(
            ".switchyard-shortcut-\(UUID().uuidString).app",
            isDirectory: true
        )
        var keepTemporaryBundle = false
        defer {
            if !keepTemporaryBundle {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let macOSURL = temporaryURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let executableURL = macOSURL.appendingPathComponent("switchyard-shortcut-handler")
        try fileManager.copyItem(at: helperURL, to: executableURL)
        guard Darwin.chmod(
            executableURL.path,
            mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
        ) == 0 else {
            throw POSIXError(.EACCES)
        }

        let includesIcon = try await writeBundleIcon(
            from: placement.desired.iconURL,
            to: temporaryURL
        )
        let infoPlist = expectedInfoDictionary(
            desired: placement.desired,
            helperDigest: helperDigest,
            iconDigest: iconDigest,
            includesIcon: includesIcon
        )
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(
            to: temporaryURL.appendingPathComponent("Contents/Info.plist"),
            options: [.atomic]
        )
        try await signBundle(
            at: temporaryURL,
            displayName: placement.desired.displayName
        )
        guard let signedAnalysis = try await helperIdentityCache.analysis(
            at: executableURL,
            matching: helperAnalysis.profile
        ),
              signedAnalysis.identity == helperAnalysis.identity,
              WineDesktopShortcutHelperIdentityReader.fileSnapshot(
                  at: executableURL
              ) == signedAnalysis.fileSnapshot else {
            throw POSIXError(.EIO)
        }
        keepTemporaryBundle = true
        return StagedPlacement(
            placement: placement,
            temporaryURL: temporaryURL,
            executableURL: executableURL,
            helperAnalysis: signedAnalysis,
            helperDigest: helperDigest,
            iconDigest: iconDigest,
            signatureSnapshot: nil
        )
    }

    private func commitRefresh(
        staged: [StagedPlacement],
        placements: [Placement],
        routes: [WineDesktopShortcutRoute],
        isStillCurrent: @MainActor () -> Bool
    ) async throws -> [String] {
        try prepareBridgeRoot()
        guard staged.allSatisfy(isStagedPlacementCurrent) else {
            throw POSIXError(.EIO)
        }

        let managed = try managedBundles()
        let desiredIDs = Set(placements.map(\.desired.id))
        let keptURLs = Dictionary(
            uniqueKeysWithValues: placements.map {
                ($0.desired.id, $0.bundleURL)
            }
        )
        var backupCandidatesByPath:
            [String: BundleBackupCandidate] = [:]
        for stagedPlacement in staged
        where fileManager.fileExists(
            atPath: stagedPlacement.placement.bundleURL.path
        ) {
            guard managedShortcutID(
                at: stagedPlacement.placement.bundleURL
            ) == stagedPlacement.placement.desired.id else {
                throw WineDesktopShortcutBridgeError
                    .desktopNameCollision(
                        stagedPlacement.placement.desired
                            .displayName
                    )
            }
            let targetURL =
                stagedPlacement.placement.bundleURL
            backupCandidatesByPath[pathKey(targetURL)] =
                BundleBackupCandidate(
                    originalURL: targetURL,
                    removedShortcutName: nil
                )
        }
        for bundle in managed {
            let shouldRemove = !desiredIDs.contains(bundle.id)
            let isDuplicate = keptURLs[bundle.id].map {
                pathKey($0) != pathKey(bundle.url)
            } ?? false
            guard shouldRemove || isDuplicate else { continue }
            let key = pathKey(bundle.url)
            if backupCandidatesByPath[key] == nil {
                guard managedShortcutID(at: bundle.url)
                        == bundle.id else {
                    throw POSIXError(.EIO)
                }
                backupCandidatesByPath[key] =
                    BundleBackupCandidate(
                        originalURL: bundle.url,
                        removedShortcutName:
                            bundle.url.deletingPathExtension()
                                .lastPathComponent
                    )
            }
        }

        if backupCandidatesByPath.isEmpty, staged.isEmpty {
            guard isStillCurrent() else {
                throw CancellationError()
            }
            try writeRouteIndex(
                WineDesktopShortcutRouteIndex(routes: routes)
            )
            return []
        }
        guard backupCandidatesByPath.count
                <= WineDesktopShortcutPersistenceLimits
                    .maximumBackupCount,
              staged.count
                <= WineDesktopShortcutFormat.maximumEntries else {
            throw POSIXError(.EFBIG)
        }

        let transactionID = UUID().uuidString
        let transactionURL = desktopURL.appendingPathComponent(
            ".switchyard-shortcut-transaction-\(transactionID)",
            isDirectory: true
        )
        let sortedBackupCandidates = backupCandidatesByPath.values
            .sorted {
                $0.originalURL.path < $1.originalURL.path
            }
        var remainingTreeEntryCount =
            WineDesktopShortcutPersistenceLimits
                .maximumTransactionTreeEntryCount
        var backups: [BundleBackup] = []
        for (index, candidate) in
            sortedBackupCandidates.enumerated()
        {
            guard remainingTreeEntryCount > 0,
                  let originalIdentity = try await stableIdentity(
                    at: candidate.originalURL,
                    maximumEntryCount: min(
                        WineDesktopShortcutPersistenceLimits
                            .maximumBundleTreeEntryCount,
                        remainingTreeEntryCount
                    )
                  ) else {
                throw POSIXError(.EFBIG)
            }
            remainingTreeEntryCount -= Int(
                originalIdentity.treeEntryCount
            )
            backups.append(
                BundleBackup(
                    originalURL: candidate.originalURL,
                    backupURL: transactionURL.appendingPathComponent(
                        "backup-\(index)",
                        isDirectory: true
                    ),
                    removedShortcutName:
                        candidate.removedShortcutName,
                    originalIdentity:
                        originalIdentity
                )
            )
        }
        guard backups.allSatisfy({
            !fileManager.fileExists(atPath: $0.backupURL.path)
        }) else {
            throw POSIXError(.EEXIST)
        }

        let previousRouteData = try routeIndexSnapshot()
        var transactionTargets:
            [ShortcutTransactionJournal.Target] = []
        for stagedPlacement in staged {
            guard stagedPlacement.signatureSnapshot != nil,
                  remainingTreeEntryCount > 0,
                  let targetIdentity = try await stableIdentity(
                    at: stagedPlacement.temporaryURL,
                    maximumEntryCount: min(
                        WineDesktopShortcutPersistenceLimits
                            .maximumBundleTreeEntryCount,
                        remainingTreeEntryCount
                    )
                  ) else {
                throw POSIXError(.EFBIG)
            }
            remainingTreeEntryCount -= Int(
                targetIdentity.treeEntryCount
            )
            transactionTargets.append(
                ShortcutTransactionJournal.Target(
                    bundleName:
                        stagedPlacement.placement.bundleURL
                            .lastPathComponent,
                    shortcutID:
                        stagedPlacement.placement.desired.id,
                    stableIdentity: targetIdentity
                )
            )
        }
        var journal = ShortcutTransactionJournal(
            state: .preparing,
            transactionID: transactionID,
            backups: backups.map {
                ShortcutTransactionJournal.Backup(
                    originalName:
                        $0.originalURL.lastPathComponent,
                    backupName:
                        $0.backupURL.lastPathComponent,
                    originalIdentity:
                        $0.originalIdentity
                )
            },
            targets: transactionTargets,
            previousRouteData: previousRouteData
        )
        var maximumJournal = journal
        maximumJournal.state = .rolledBack
        _ = try encodedTransactionJournalData(
            maximumJournal
        )
        guard isStillCurrent(),
              staged.allSatisfy(isStagedPlacementCurrent) else {
            throw CancellationError()
        }
        try fileManager.createDirectory(
            at: transactionURL,
            withIntermediateDirectories: false
        )
        guard Darwin.chmod(
            transactionURL.path,
            mode_t(S_IRWXU)
        ) == 0 else {
            try? fileManager.removeItem(at: transactionURL)
            throw POSIXError(.EACCES)
        }
        do {
            try synchronizeDirectory(at: desktopURL)
            try writeTransactionJournal(
                journal,
                at: transactionURL
            )
        } catch {
            try? fileManager.removeItem(at: transactionURL)
            throw error
        }
        var movedBackups: [BundleBackup] = []
        var installedPlacements: [StagedPlacement] = []
        var routeWriteAttempted = false
        do {
            for (index, backup) in backups.enumerated() {
                let originalIdentity =
                    await transactionStableIdentity(
                        at: backup.originalURL
                    )
                try Task.checkCancellation()
                guard originalIdentity == backup.originalIdentity else {
                    throw POSIXError(.EIO)
                }
                try fileManager.moveItem(
                    at: backup.originalURL,
                    to: backup.backupURL
                )
                movedBackups.append(backup)
                let backupIdentity =
                    await transactionStableIdentity(
                        at: backup.backupURL
                    )
                try Task.checkCancellation()
                guard backupIdentity == backup.originalIdentity else {
                    throw POSIXError(.EIO)
                }
                try synchronizeDirectory(at: desktopURL)
                try synchronizeDirectory(at: transactionURL)
                try commitCheckpoint(.didBackupBundle(index))
            }

            for (index, stagedPlacement) in staged.enumerated() {
                let targetIdentity = transactionTargets[index]
                let targetURL =
                    stagedPlacement.placement.bundleURL
                guard !fileManager.fileExists(
                    atPath: targetURL.path
                ) else {
                    throw WineDesktopShortcutBridgeError
                        .desktopNameCollision(
                            stagedPlacement.placement.desired
                                .displayName
                        )
                }
                let stagedIdentity =
                    await transactionStableIdentity(
                        at: stagedPlacement.temporaryURL
                    )
                try Task.checkCancellation()
                guard stagedIdentity
                        == targetIdentity.stableIdentity else {
                    throw POSIXError(.EIO)
                }
                try fileManager.moveItem(
                    at: stagedPlacement.temporaryURL,
                    to: targetURL
                )
                let installed = installedPlacement(
                    stagedPlacement,
                    at: targetURL
                )
                installedPlacements.append(installed)
                let installedIdentity =
                    await transactionStableIdentity(
                        at: targetURL
                    )
                try Task.checkCancellation()
                guard installedIdentity
                        == targetIdentity.stableIdentity,
                      isStagedPlacementCurrent(installed) else {
                    throw POSIXError(.EIO)
                }
                try synchronizeDirectory(at: desktopURL)
                try commitCheckpoint(.didInstallBundle(index))
            }

            guard isStillCurrent() else {
                throw CancellationError()
            }
            try commitCheckpoint(.willPublishRoutes)
            routeWriteAttempted = true
            try writeRouteIndex(
                WineDesktopShortcutRouteIndex(routes: routes)
            )
            journal.state = .committed
            try writeTransactionJournal(
                journal,
                at: transactionURL
            )
        } catch {
            let bundlesRestored = await rollbackBundles(
                installedPlacements: installedPlacements,
                targets: transactionTargets,
                movedBackups: movedBackups,
                transactionURL: transactionURL
            )
            let routesRestored = !routeWriteAttempted
                || restoreRouteIndex(previousRouteData)
            var transactionMarkedRolledBack = false
            if bundlesRestored, routesRestored {
                journal.state = .rolledBack
                do {
                    try commitCheckpoint(
                        .willMarkRolledBack
                    )
                    try writeTransactionJournal(
                        journal,
                        at: transactionURL
                    )
                    transactionMarkedRolledBack = true
                } catch {
                    transactionMarkedRolledBack = false
                }
            }
            let transactionRemoved: Bool
            if transactionMarkedRolledBack {
                transactionRemoved =
                    await cleanupTransactionDirectory(
                    journal,
                    at: transactionURL
                )
            } else {
                transactionRemoved = false
            }
            guard bundlesRestored,
                  routesRestored,
                  transactionMarkedRolledBack,
                  transactionRemoved else {
                throw POSIXError(.EIO)
            }
            throw error
        }

        do {
            try commitCheckpoint(.willCleanupTransaction)
            guard await cleanupTransactionDirectory(
                journal,
                at: transactionURL
            ) else {
                throw POSIXError(.EIO)
            }
        } catch {
            throw WineDesktopShortcutBridgeError
                .committedTransactionNeedsCleanup
        }
        return backups.compactMap(\.removedShortcutName)
            .sorted()
    }

    private func writeTransactionJournal(
        _ journal: ShortcutTransactionJournal,
        at transactionURL: URL
    ) throws {
        let journalURL = transactionURL.appendingPathComponent(
            "journal-v1.json"
        )
        let temporaryURL = transactionURL.appendingPathComponent(
            "journal-v1.json.tmp"
        )
        let data = try encodedTransactionJournalData(
            journal
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
                | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        var keepTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if keepTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        guard Darwin.fchmod(
            descriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0 else {
            throw POSIXError(.EACCES)
        }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        guard wroteAll,
              Darwin.fsync(descriptor) == 0,
              Darwin.rename(
                  temporaryURL.path,
                  journalURL.path
              ) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        keepTemporaryFile = false
        try synchronizeDirectory(at: transactionURL)
    }

    private func encodedTransactionJournalData(
        _ journal: ShortcutTransactionJournal
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count
                <= WineDesktopShortcutPersistenceLimits
                    .maximumTransactionJournalByteCount else {
            throw POSIXError(.EFBIG)
        }
        return data
    }

    private func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
    }

    private func discardRecoverableJournalTemporaryFile(
        at transactionURL: URL
    ) -> Bool {
        let temporaryURL = transactionURL.appendingPathComponent(
            "journal-v1.json.tmp"
        )
        var status = stat()
        guard Darwin.lstat(
            temporaryURL.path,
            &status
        ) == 0 else {
            return errno == ENOENT
        }
        guard status.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <=
                WineDesktopShortcutPersistenceLimits
                    .maximumTransactionJournalByteCount else {
            return false
        }
        do {
            try fileManager.removeItem(at: temporaryURL)
            try synchronizeDirectory(at: transactionURL)
            return true
        } catch {
            return false
        }
    }

    private func recoverShortcutTransactions() async throws {
        let prefix = ".switchyard-shortcut-transaction-"
        let entries = try fileManager.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for transactionURL in entries
        where transactionURL.lastPathComponent.hasPrefix(prefix) {
            var status = stat()
            guard Darwin.lstat(
                transactionURL.path,
                &status
            ) == 0,
                  status.st_mode & mode_t(S_IFMT)
                    == mode_t(S_IFDIR),
                  status.st_uid == geteuid(),
                  status.st_mode & mode_t(0o777)
                    == mode_t(S_IRWXU) else {
                continue
            }
            guard discardRecoverableJournalTemporaryFile(
                at: transactionURL
            ) else {
                throw POSIXError(.EIO)
            }
            let transactionID = String(
                transactionURL.lastPathComponent
                    .dropFirst(prefix.count)
            )
            guard !transactionID.isEmpty else { continue }
            let journalURL = transactionURL
                .appendingPathComponent("journal-v1.json")
            guard let journalData = boundedRegularFileData(
                at: journalURL,
                maximumByteCount:
                    WineDesktopShortcutPersistenceLimits
                        .maximumTransactionJournalByteCount
            ) else {
                if (try? fileManager.contentsOfDirectory(
                    atPath: transactionURL.path
                ).isEmpty) == true {
                    try fileManager.removeItem(at: transactionURL)
                }
                continue
            }
            let journal = try JSONDecoder().decode(
                ShortcutTransactionJournal.self,
                from: journalData
            )
            guard journal.transactionID == transactionID,
                  transactionJournalPathsAreSafe(
                      journal,
                      transactionURL: transactionURL
                  ) else {
                continue
            }
            let recovered: Bool
            switch journal.state {
            case .preparing:
                recovered = await recoverPreparingTransaction(
                    journal,
                    at: transactionURL
                )
            case .committed:
                recovered = await cleanupTransactionDirectory(
                    journal,
                    at: transactionURL
                )
            case .rolledBack:
                recovered = await cleanupTransactionDirectory(
                    journal,
                    at: transactionURL
                )
            }
            guard recovered else {
                throw POSIXError(.EIO)
            }
        }
    }

    private func transactionJournalPathsAreSafe(
        _ journal: ShortcutTransactionJournal,
        transactionURL: URL
    ) -> Bool {
        let isDirectChildName: (String) -> Bool = { name in
            !name.isEmpty
                && name != "."
                && name != ".."
                && !name.contains("/")
                && URL(fileURLWithPath: name)
                    .lastPathComponent == name
        }
        let originalNames = journal.backups.map(\.originalName)
        let backupNames = journal.backups.map(\.backupName)
        let targetNames = journal.targets.map(\.bundleName)
        let uniqueOriginalNames = Set(originalNames)
        let uniqueBackupNames = Set(backupNames)
        let uniqueTargetNames = Set(targetNames)
        let uniqueShortcutIDs = Set(
            journal.targets.map(\.shortcutID)
        )
        guard journal.backups.allSatisfy({
            isDirectChildName($0.originalName)
                && isDirectChildName($0.backupName)
                && $0.backupName.hasPrefix("backup-")
                && $0.originalName.hasSuffix(".app")
                && $0.originalIdentity.rootMode
                    & UInt32(S_IFMT)
                    == UInt32(S_IFDIR)
                && $0.originalIdentity.rootOwnerUserID
                    == UInt32(geteuid())
                && $0.originalIdentity.treeEntryCount
                    <= UInt32(
                        WineDesktopShortcutPersistenceLimits
                            .maximumBundleTreeEntryCount
                    )
                && $0.originalIdentity.treeDigest.count == 64
                && $0.originalIdentity.treeDigest
                    .allSatisfy(\.isHexDigit)
        }),
              journal.targets.allSatisfy({
                  isDirectChildName($0.bundleName)
                      && $0.bundleName.hasSuffix(".app")
                      && $0.shortcutID.count == 64
                      && $0.shortcutID.allSatisfy(\.isHexDigit)
                      && $0.stableIdentity.rootMode
                        & UInt32(S_IFMT)
                        == UInt32(S_IFDIR)
                      && $0.stableIdentity.rootOwnerUserID
                        == UInt32(geteuid())
                      && $0.stableIdentity.treeEntryCount
                        <= UInt32(
                            WineDesktopShortcutPersistenceLimits
                                .maximumBundleTreeEntryCount
                        )
                      && $0.stableIdentity.treeDigest.count == 64
                      && $0.stableIdentity.treeDigest
                        .allSatisfy(\.isHexDigit)
              }),
              journal.backups.count
                <= WineDesktopShortcutPersistenceLimits
                    .maximumBackupCount,
              journal.targets.count
                <= WineDesktopShortcutFormat.maximumEntries,
              uniqueOriginalNames.count == originalNames.count,
              uniqueBackupNames.count == backupNames.count,
              uniqueTargetNames.count == targetNames.count,
              uniqueShortcutIDs.count == journal.targets.count,
              journal.backups.allSatisfy({
                  let backupURL = transactionURL
                      .appendingPathComponent(
                          $0.backupName,
                          isDirectory: true
                      )
                  var status = stat()
                  guard Darwin.lstat(
                      backupURL.path,
                      &status
                  ) == 0 else {
                      return errno == ENOENT
                  }
                  return status.st_mode & mode_t(S_IFMT)
                      == mode_t(S_IFDIR)
              }),
              let actualEntries = directoryEntryNames(
                  at: transactionURL,
                  maximumEntryCount:
                    1 + journal.backups.count
                    + journal.backups.count
                    + journal.targets.count
              ) else {
            return false
        }
        let expectedEntries = Set(
            ["journal-v1.json"]
                + journal.backups.map(\.backupName)
                + journal.backups.map(
                    transactionBackupDiscardName
                )
                + journal.targets.map(
                    transactionDiscardName
                )
        )
        return actualEntries.isSubset(of: expectedEntries)
    }

    private func recoverPreparingTransaction(
        _ journal: ShortcutTransactionJournal,
        at transactionURL: URL
    ) async -> Bool {
        let backupByOriginal = Dictionary(
            uniqueKeysWithValues: journal.backups.map {
                ($0.originalName, $0)
            }
        )
        for target in journal.targets {
            let targetURL = desktopURL.appendingPathComponent(
                target.bundleName,
                isDirectory: true
            )
            let plannedBackup =
                backupByOriginal[target.bundleName]
            let backupExists = plannedBackup.map {
                pathEntryExists(
                    transactionURL.appendingPathComponent(
                        $0.backupName,
                        isDirectory: true
                    )
                )
            } ?? false
            guard pathEntryExists(targetURL) else {
                guard await removeVerifiedDiscardIfPresent(
                    for: target,
                    at: transactionURL
                ) else {
                    return false
                }
                continue
            }
            guard let currentIdentity =
                await transactionStableIdentity(
                    at: targetURL
                ) else {
                return false
            }
            if let plannedBackup,
               !backupExists,
               currentIdentity
                == plannedBackup.originalIdentity {
                // Rollback may have restored this object before its
                // journal marker was durably replaced.
                continue
            }
            guard currentIdentity == target.stableIdentity,
                  managedShortcutID(at: targetURL)
                    == target.shortcutID,
                  await removeVerifiedTransactionTarget(
                      target,
                      at: targetURL,
                      transactionURL: transactionURL
                  ) else {
                return false
            }
        }

        for backup in journal.backups.reversed() {
            let backupURL = transactionURL
                .appendingPathComponent(
                    backup.backupName,
                    isDirectory: true
                )
            let originalURL = desktopURL
                .appendingPathComponent(
                    backup.originalName,
                    isDirectory: true
                )
            guard pathEntryExists(backupURL) else {
                guard pathEntryExists(originalURL),
                      await transactionStableIdentity(
                        at: originalURL
                      )
                        == backup.originalIdentity else {
                    return false
                }
                continue
            }
            guard await transactionStableIdentity(
                at: backupURL
            )
                    == backup.originalIdentity,
                  !pathEntryExists(originalURL) else {
                return false
            }
            do {
                try fileManager.moveItem(
                    at: backupURL,
                    to: originalURL
                )
                try synchronizeDirectory(at: transactionURL)
                try synchronizeDirectory(at: desktopURL)
                guard await transactionStableIdentity(
                    at: originalURL
                )
                        == backup.originalIdentity else {
                    return false
                }
            } catch {
                return false
            }
        }
        guard restoreRouteIndex(journal.previousRouteData) else {
            return false
        }
        var rolledBackJournal = journal
        rolledBackJournal.state = .rolledBack
        do {
            try writeTransactionJournal(
                rolledBackJournal,
                at: transactionURL
            )
        } catch {
            return false
        }
        return await cleanupTransactionDirectory(
            rolledBackJournal,
            at: transactionURL
        )
    }

    private func transactionDiscardName(
        _ target: ShortcutTransactionJournal.Target
    ) -> String {
        "discard-\(target.shortcutID).app"
    }

    private func transactionBackupDiscardName(
        _ backup: ShortcutTransactionJournal.Backup
    ) -> String {
        "discard-\(backup.backupName)"
    }

    private func removeVerifiedDiscardIfPresent(
        for target: ShortcutTransactionJournal.Target,
        at transactionURL: URL
    ) async -> Bool {
        let discardURL = transactionURL.appendingPathComponent(
            transactionDiscardName(target),
            isDirectory: true
        )
        guard pathEntryExists(discardURL) else { return true }
        guard await transactionStableIdentity(
            at: discardURL
        )
                == target.stableIdentity else {
            return false
        }
        do {
            try fileManager.removeItem(at: discardURL)
            try synchronizeDirectory(at: transactionURL)
            return true
        } catch {
            return false
        }
    }

    private func removeVerifiedTransactionTarget(
        _ target: ShortcutTransactionJournal.Target,
        at targetURL: URL,
        transactionURL: URL
    ) async -> Bool {
        guard await removeVerifiedDiscardIfPresent(
            for: target,
            at: transactionURL
        ) else {
            return false
        }
        guard pathEntryExists(targetURL) else { return true }
        guard await transactionStableIdentity(
            at: targetURL
        )
                == target.stableIdentity else {
            return false
        }
        let discardURL = transactionURL.appendingPathComponent(
            transactionDiscardName(target),
            isDirectory: true
        )
        do {
            try fileManager.moveItem(
                at: targetURL,
                to: discardURL
            )
            try synchronizeDirectory(at: desktopURL)
            try synchronizeDirectory(at: transactionURL)
            guard await transactionStableIdentity(
                at: discardURL
            )
                    == target.stableIdentity else {
                if !pathEntryExists(targetURL) {
                    try? fileManager.moveItem(
                        at: discardURL,
                        to: targetURL
                    )
                    try? synchronizeDirectory(at: desktopURL)
                    try? synchronizeDirectory(at: transactionURL)
                }
                return false
            }
            try fileManager.removeItem(at: discardURL)
            try synchronizeDirectory(at: transactionURL)
            return true
        } catch {
            return false
        }
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var status = stat()
        return Darwin.lstat(url.path, &status) == 0
    }

    private func removeVerifiedTransactionBackup(
        _ backup: ShortcutTransactionJournal.Backup,
        at transactionURL: URL
    ) async -> Bool {
        let backupURL = transactionURL.appendingPathComponent(
            backup.backupName,
            isDirectory: true
        )
        let discardURL = transactionURL.appendingPathComponent(
            transactionBackupDiscardName(backup),
            isDirectory: true
        )
        if pathEntryExists(discardURL) {
            guard await transactionStableIdentity(
                at: discardURL
            )
                    == backup.originalIdentity else {
                return false
            }
            do {
                try fileManager.removeItem(at: discardURL)
                try synchronizeDirectory(at: transactionURL)
            } catch {
                return false
            }
        }
        guard pathEntryExists(backupURL) else { return true }
        guard await transactionStableIdentity(
            at: backupURL
        )
                == backup.originalIdentity else {
            return false
        }
        do {
            try fileManager.moveItem(
                at: backupURL,
                to: discardURL
            )
            try synchronizeDirectory(at: transactionURL)
            guard await transactionStableIdentity(
                at: discardURL
            )
                    == backup.originalIdentity else {
                if !pathEntryExists(backupURL) {
                    try? fileManager.moveItem(
                        at: discardURL,
                        to: backupURL
                    )
                    try? synchronizeDirectory(
                        at: transactionURL
                    )
                }
                return false
            }
            try fileManager.removeItem(at: discardURL)
            try synchronizeDirectory(at: transactionURL)
            return true
        } catch {
            return false
        }
    }

    private func cleanupTransactionDirectory(
        _ journal: ShortcutTransactionJournal,
        at transactionURL: URL
    ) async -> Bool {
        do {
            for target in journal.targets {
                guard await removeVerifiedDiscardIfPresent(
                    for: target,
                    at: transactionURL
                ) else {
                    return false
                }
            }
            for backup in journal.backups {
                guard await removeVerifiedTransactionBackup(
                    backup,
                    at: transactionURL
                ) else {
                    return false
                }
            }
            try synchronizeDirectory(at: transactionURL)
            let journalURL = transactionURL
                .appendingPathComponent("journal-v1.json")
            guard let remainingBeforeMarkerRemoval =
                    directoryEntryNames(
                        at: transactionURL,
                        maximumEntryCount: 1
                    ),
                  remainingBeforeMarkerRemoval
                    .isSubset(of: ["journal-v1.json"]) else {
                return false
            }
            if fileManager.fileExists(atPath: journalURL.path) {
                try fileManager.removeItem(at: journalURL)
            }
            guard directoryEntryNames(
                at: transactionURL,
                maximumEntryCount: 0
            )?.isEmpty == true else {
                return false
            }
            try fileManager.removeItem(at: transactionURL)
            try synchronizeDirectory(at: desktopURL)
            return true
        } catch {
            return false
        }
    }

    private func installedPlacement(
        _ staged: StagedPlacement,
        at bundleURL: URL
    ) -> StagedPlacement {
        StagedPlacement(
            placement: staged.placement,
            temporaryURL: bundleURL,
            executableURL: helperExecutableURL(at: bundleURL),
            helperAnalysis: staged.helperAnalysis,
            helperDigest: staged.helperDigest,
            iconDigest: staged.iconDigest,
            signatureSnapshot: staged.signatureSnapshot
        )
    }

    private func verifiedStagedPlacement(
        _ staged: StagedPlacement,
        signatureSnapshot:
            WineDesktopShortcutBundleSignatureSnapshot?
    ) -> StagedPlacement {
        StagedPlacement(
            placement: staged.placement,
            temporaryURL: staged.temporaryURL,
            executableURL: staged.executableURL,
            helperAnalysis: staged.helperAnalysis,
            helperDigest: staged.helperDigest,
            iconDigest: staged.iconDigest,
            signatureSnapshot: signatureSnapshot
        )
    }

    private func rollbackBundles(
        installedPlacements: [StagedPlacement],
        targets: [ShortcutTransactionJournal.Target],
        movedBackups: [BundleBackup],
        transactionURL: URL
    ) async -> Bool {
        var succeeded = true
        let targetsByName = Dictionary(
            uniqueKeysWithValues: targets.map {
                ($0.bundleName, $0)
            }
        )
        for installed in installedPlacements.reversed() {
            let installedURL = installed.temporaryURL
            guard let target =
                targetsByName[installedURL.lastPathComponent],
                  await removeVerifiedTransactionTarget(
                      target,
                      at: installedURL,
                      transactionURL: transactionURL
                  ) else {
                succeeded = false
                continue
            }
        }
        for backup in movedBackups.reversed() {
            guard pathEntryExists(backup.backupURL) else {
                if await transactionStableIdentity(
                    at: backup.originalURL
                )
                    != backup.originalIdentity {
                    succeeded = false
                }
                continue
            }
            guard await transactionStableIdentity(
                at: backup.backupURL
            )
                    == backup.originalIdentity,
                  !pathEntryExists(backup.originalURL) else {
                succeeded = false
                continue
            }
            do {
                try fileManager.moveItem(
                    at: backup.backupURL,
                    to: backup.originalURL
                )
                try synchronizeDirectory(at: transactionURL)
                try synchronizeDirectory(at: desktopURL)
                guard await transactionStableIdentity(
                    at: backup.originalURL
                )
                        == backup.originalIdentity else {
                    succeeded = false
                    continue
                }
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private func routeIndexSnapshot() throws -> Data? {
        let routesURL = rootURL.appendingPathComponent(
            "routes-v1.json"
        )
        var status = stat()
        guard Darwin.lstat(routesURL.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        guard status.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG),
              let data = boundedRegularFileData(
                  at: routesURL,
                  maximumByteCount:
                    WineDesktopShortcutPersistenceLimits
                        .maximumRouteIndexByteCount
              ) else {
            throw POSIXError(.EIO)
        }
        return data
    }

    private func restoreRouteIndex(
        _ previousData: Data?
    ) -> Bool {
        let routesURL = rootURL.appendingPathComponent(
            "routes-v1.json"
        )
        do {
            if let previousData {
                try writeDurableRouteData(
                    previousData,
                    to: routesURL
                )
            } else if pathEntryExists(routesURL) {
                try fileManager.removeItem(at: routesURL)
                try synchronizeDirectory(at: rootURL)
            }
            return true
        } catch {
            return false
        }
    }

    private func isStagedPlacementCurrent(
        _ staged: StagedPlacement
    ) -> Bool {
        guard let signatureSnapshot =
            staged.signatureSnapshot else {
            return false
        }
        return WineDesktopShortcutHelperIdentityReader.fileSnapshot(
            at: staged.executableURL
        ) == staged.helperAnalysis.fileSnapshot
            && bundleMetadataMatches(
                at: staged.temporaryURL,
                desired: staged.placement.desired,
                helperDigest: staged.helperDigest,
                iconDigest: staged.iconDigest
            )
            && WineDesktopShortcutBundleSignatureVerifier
                .snapshot(at: staged.temporaryURL)
                == signatureSnapshot
    }

    private func writeBundleIcon(
        from sourceURL: URL?,
        to bundleURL: URL
    ) async throws -> Bool {
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let iconsetURL = resourcesURL.appendingPathComponent("Shortcut.iconset", isDirectory: true)
        let outputURL = resourcesURL.appendingPathComponent("Shortcut.icns")
        try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: iconsetURL) }

        let representations: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1_024)
        ]
        let pixelSizes = Set(
            representations.map(\.pixels)
        )
        var renderedData: [Int: Data]?
        if let sourceURL {
            let renderTask = Task.detached(
                priority: .utility
            ) {
                WineDesktopShortcutIconRenderer.pngDataBySize(
                    at: sourceURL,
                    pixelSizes: pixelSizes
                )
            }
            renderedData = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            try Task.checkCancellation()
        }
        if renderedData == nil {
            let image = fallbackIcon()
            var proposedRect = NSRect(
                origin: .zero,
                size: image.size
            )
            guard let sourceImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            ) else {
                return false
            }
            let sendableImage =
                WineDesktopShortcutSendableImage(
                    value: sourceImage
                )
            let fallbackRenderTask = Task.detached(
                priority: .utility
            ) {
                WineDesktopShortcutIconRenderer.pngDataBySize(
                    for: sendableImage,
                    pixelSizes: pixelSizes
                )
            }
            renderedData = await withTaskCancellationHandler {
                await fallbackRenderTask.value
            } onCancel: {
                fallbackRenderTask.cancel()
            }
        }
        try Task.checkCancellation()
        guard let dataBySize = renderedData else {
            return false
        }
        for representation in representations {
            guard let data = dataBySize[
                representation.pixels
            ] else { return false }
            try data.write(
                to: iconsetURL.appendingPathComponent(representation.name),
                options: [.atomic]
            )
        }

        let status = try await WineDesktopShortcutSubprocessRunner.run(
            executableURL: URL(
                fileURLWithPath: "/usr/bin/iconutil"
            ),
            arguments: [
                "--convert",
                "icns",
                iconsetURL.path,
                "--output",
                outputURL.path
            ]
        )
        if status != 0 {
            try? fileManager.removeItem(at: outputURL)
            return false
        }
        return fileManager.fileExists(atPath: outputURL.path)
    }

    private func fallbackIcon() -> NSImage {
        guard let applicationIcon = NSApplication.shared.applicationIconImage,
              applicationIcon.size.width > 0,
              applicationIcon.size.height > 0 else {
            let image = NSImage(size: NSSize(width: 512, height: 512))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 24, y: 24, width: 464, height: 464),
                xRadius: 96,
                yRadius: 96
            ).fill()
            image.unlockFocus()
            return image
        }
        return applicationIcon
    }

    private func bundleMetadataMatches(
        at url: URL,
        desired: DesiredShortcut,
        helperDigest: String,
        iconDigest: String?
    ) -> Bool {
        guard let info = infoDictionary(at: url) else {
            return false
        }
        let includesIcon: Bool
        switch info["CFBundleIconFile"] {
        case let value as String
        where value == "Shortcut.icns":
            includesIcon = true
        case nil:
            includesIcon = false
        default:
            return false
        }
        let expected = expectedInfoDictionary(
            desired: desired,
            helperDigest: helperDigest,
            iconDigest: iconDigest,
            includesIcon: includesIcon
        )
        return NSDictionary(dictionary: info).isEqual(
            to: expected
        ) && bundleLayoutMatches(
            at: url,
            includesIcon: includesIcon
        )
    }

    private func expectedInfoDictionary(
        desired: DesiredShortcut,
        helperDigest: String,
        iconDigest: String?,
        includesIcon: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleDisplayName": desired.displayName,
            "CFBundleExecutable":
                "switchyard-shortcut-handler",
            "CFBundleIdentifier":
                bundleIdentifier(for: desired.id),
            "CFBundleName": desired.displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "SwitchyardDesktopShortcutID": desired.id,
            "SwitchyardDesktopShortcutOwner": "dev.switchyard",
            "SwitchyardShortcutHelperSHA256": helperDigest
        ]
        if includesIcon {
            info["CFBundleIconFile"] = "Shortcut.icns"
        }
        if let iconDigest {
            info["SwitchyardShortcutIconSHA256"] = iconDigest
        }
        return info
    }

    private func bundleLayoutMatches(
        at bundleURL: URL,
        includesIcon: Bool
    ) -> Bool {
        WineDesktopShortcutBundleSignatureVerifier.layoutIsSafe(
            at: bundleURL,
            includesIcon: includesIcon
        )
    }

    private func directoryEntryNames(
        at url: URL,
        maximumEntryCount: Int
    ) -> Set<String>? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0,
              let directory = Darwin.fdopendir(descriptor) else {
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            return nil
        }
        defer { Darwin.closedir(directory) }

        var names: Set<String> = []
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(
                to: entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < maximumEntryCount,
                  names.insert(name).inserted else {
                return nil
            }
        }
        return names
    }

    private func removeManagedBundles(excluding desiredIDs: Set<String>) throws -> [String] {
        var removed: [String] = []
        for bundle in try managedBundles() where !desiredIDs.contains(bundle.id) {
            removed.append(bundle.url.deletingPathExtension().lastPathComponent)
            try fileManager.removeItem(at: bundle.url)
        }
        return removed
    }

    private func removeDuplicateBundles(keeping keptURLs: [String: URL]) throws -> [String] {
        var removed: [String] = []
        for bundle in try managedBundles() {
            guard let keptURL = keptURLs[bundle.id],
                  pathKey(bundle.url) != pathKey(keptURL) else {
                continue
            }
            removed.append(bundle.url.deletingPathExtension().lastPathComponent)
            try fileManager.removeItem(at: bundle.url)
        }
        return removed
    }

    private func managedBundles() throws -> [(id: String, url: URL)] {
        let entries = try fileManager.contentsOfDirectory(
            at: desktopURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        return entries.compactMap { url in
            guard !url.lastPathComponent.hasPrefix(
                ".switchyard-shortcut-"
            ),
                  url.pathExtension.caseInsensitiveCompare("app")
                    == .orderedSame,
                  let id = managedShortcutID(at: url) else {
                return nil
            }
            return (id, url)
        }
    }

    private func managedShortcutID(at url: URL) -> String? {
        guard let info = infoDictionary(at: url),
              info["SwitchyardDesktopShortcutOwner"] as? String == "dev.switchyard",
              let id = info["SwitchyardDesktopShortcutID"] as? String,
              id.count == 64,
              id.allSatisfy(\.isHexDigit),
              info["CFBundleIdentifier"] as? String == bundleIdentifier(for: id) else {
            return nil
        }
        return id
    }

    private func infoDictionary(at bundleURL: URL) -> [String: Any]? {
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let infoURL = contentsURL.appendingPathComponent(
            "Info.plist"
        )
        guard isDirectoryWithoutSymbolicLink(bundleURL),
              isDirectoryWithoutSymbolicLink(contentsURL),
              let data = boundedRegularFileData(
                  at: infoURL,
                  maximumByteCount: 64 * 1_024
              ),
              let info = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            return nil
        }
        return info
    }

    private func writeRouteIndex(_ index: WineDesktopShortcutRouteIndex) throws {
        let routesURL = rootURL.appendingPathComponent("routes-v1.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        guard data.count
                <= WineDesktopShortcutPersistenceLimits
                    .maximumRouteIndexByteCount else {
            throw POSIXError(.EFBIG)
        }
        var status = stat()
        if Darwin.lstat(routesURL.path, &status) == 0,
           status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
           status.st_mode & mode_t(0o777)
                == mode_t(S_IRUSR | S_IWUSR),
           boundedRegularFileData(
               at: routesURL,
               maximumByteCount:
                WineDesktopShortcutPersistenceLimits
                    .maximumRouteIndexByteCount
           ) == data {
            return
        }
        try writeDurableRouteData(data, to: routesURL)
    }

    private func writeDurableRouteData(
        _ data: Data,
        to routesURL: URL
    ) throws {
        guard !data.isEmpty,
              data.count
                <= WineDesktopShortcutPersistenceLimits
                    .maximumRouteIndexByteCount else {
            throw POSIXError(.EFBIG)
        }
        let temporaryURL = rootURL.appendingPathComponent(
            ".routes-v1.json.tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
                | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        var keepTemporaryFile = true
        defer {
            Darwin.close(descriptor)
            if keepTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        guard Darwin.fchmod(
            descriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0 else {
            throw POSIXError(.EACCES)
        }
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        guard wroteAll,
              Darwin.fsync(descriptor) == 0,
              Darwin.rename(
                  temporaryURL.path,
                  routesURL.path
              ) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        keepTemporaryFile = false
        try synchronizeDirectory(at: rootURL)
    }

    private func discardRecoverableRouteTemporaryFile()
        -> Bool
    {
        let temporaryURL = rootURL.appendingPathComponent(
            ".routes-v1.json.tmp"
        )
        var status = stat()
        guard Darwin.lstat(
            temporaryURL.path,
            &status
        ) == 0 else {
            return errno == ENOENT
        }
        guard status.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <=
                WineDesktopShortcutPersistenceLimits
                    .maximumRouteIndexByteCount else {
            return false
        }
        do {
            try fileManager.removeItem(at: temporaryURL)
            try synchronizeDirectory(at: rootURL)
            return true
        } catch {
            return false
        }
    }

    private func locateShortcutHandler() throws -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("switchyard-shortcut-handler")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }

        if let override = ProcessInfo.processInfo.environment["SWITCHYARD_SHORTCUT_HANDLER_PATH"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let fallback = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/debug/switchyard-shortcut-handler")
        if fileManager.isExecutableFile(atPath: fallback.path) { return fallback }
        throw WineDesktopShortcutBridgeError.missingShortcutHandler
    }

    private func signBundle(
        at url: URL,
        displayName: String
    ) async throws {
        let status = try await WineDesktopShortcutSubprocessRunner.run(
            executableURL: URL(
                fileURLWithPath: "/usr/bin/codesign"
            ),
            arguments: ["--force", "--sign", "-", url.path]
        )
        guard status == 0 else {
            throw WineDesktopShortcutBridgeError.couldNotSignShortcut(displayName)
        }
    }

    private func shortcutID(containerID: UUID, windowsPath: String) -> String {
        let input = containerID.uuidString.lowercased() + "\u{0}" + windowsPath.lowercased()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func bundleIdentifier(for id: String) -> String {
        "dev.switchyard.desktop-shortcut.\(id.prefix(24))"
    }

    private func sha256Hex(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func digest(
        of url: URL,
        cachedDigests: [URL: String]
    ) throws -> String {
        let normalizedURL = url.standardizedFileURL
        return try cachedDigests[normalizedURL]
            ?? sha256Hex(of: normalizedURL)
    }

    private func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        var status = stat()
        return Darwin.lstat(url.path, &status) == 0
            && status.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG)
    }

    private func isDirectoryWithoutSymbolicLink(
        _ url: URL
    ) -> Bool {
        var status = stat()
        return Darwin.lstat(url.path, &status) == 0
            && status.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFDIR)
    }

    private func boundedRegularFileData(
        at url: URL,
        maximumByteCount: Int
    ) -> Data? {
        guard maximumByteCount > 0 else { return nil }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              initialStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG),
              initialStatus.st_size > 0,
              initialStatus.st_size
                <= off_t(maximumByteCount) else {
            return nil
        }

        let dataByteCount = Int(initialStatus.st_size)
        var data = Data(count: dataByteCount)
        var consumed = 0
        let readSucceeded = data.withUnsafeMutableBytes {
            bytes -> Bool in
            while consumed < dataByteCount {
                guard !Task.isCancelled else { return false }
                let count = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: consumed),
                    dataByteCount - consumed,
                    off_t(consumed)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                consumed += count
            }
            return true
        }
        guard readSucceeded else { return nil }

        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        guard Darwin.fstat(
            descriptor,
            &finalDescriptorStatus
        ) == 0,
              Darwin.lstat(url.path, &finalPathStatus) == 0,
              sameFileStatus(
                  initialStatus,
                  finalDescriptorStatus
              ),
              sameFileStatus(
                  initialStatus,
                  finalPathStatus
              ) else {
            return nil
        }
        return data
    }

    private func sameFileStatus(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

}
