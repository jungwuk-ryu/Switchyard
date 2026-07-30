import AppCore
import CryptoKit
import Darwin
import Foundation

public enum RuntimeGPUIdentityEvidenceSubject: String, Equatable, Hashable, Sendable {
    case runtimeRoot
    case helper
    case policy
}

public enum RuntimeGPUIdentityEvidenceBuilderError: Error, Equatable, Hashable, Sendable {
    case invalidLimits
    case invalidRuntimeRoot
    case nonCanonicalPath(RuntimeGPUIdentityEvidenceSubject)
    case pathOutsideRuntimeRoot(RuntimeGPUIdentityEvidenceSubject)
    case unavailable(RuntimeGPUIdentityEvidenceSubject)
    case symbolicLinkNotAllowed(RuntimeGPUIdentityEvidenceSubject)
    case invalidPathComponent(RuntimeGPUIdentityEvidenceSubject)
    case notDirectory(RuntimeGPUIdentityEvidenceSubject)
    case notRegularFile(RuntimeGPUIdentityEvidenceSubject)
    case ownerMismatch(RuntimeGPUIdentityEvidenceSubject)
    case hardLinkNotAllowed(RuntimeGPUIdentityEvidenceSubject)
    case invalidPermissions(RuntimeGPUIdentityEvidenceSubject)
    case fileTooLarge(RuntimeGPUIdentityEvidenceSubject)
    case invalidMetadata(RuntimeGPUIdentityEvidenceSubject)
    case readFailed(RuntimeGPUIdentityEvidenceSubject)
    case fileChanged(RuntimeGPUIdentityEvidenceSubject)
}

public struct RuntimeGPUIdentityEvidenceBuilder: Sendable {
    public struct Limits: Equatable, Hashable, Sendable {
        public var maximumHelperBytes: UInt64
        public var maximumPolicyBytes: UInt64

        public init(
            maximumHelperBytes: UInt64 = 64 * 1_024 * 1_024,
            maximumPolicyBytes: UInt64 = 4 * 1_024 * 1_024
        ) {
            self.maximumHelperBytes = maximumHelperBytes
            self.maximumPolicyBytes = maximumPolicyBytes
        }
    }

    private let limits: Limits
    private let expectedOwnerUID: uid_t
    private let descriptorReader: any RuntimeGPUIdentityDescriptorReading

    public init(limits: Limits = Limits()) {
        self.limits = limits
        self.expectedOwnerUID = Darwin.geteuid()
        self.descriptorReader = RuntimeGPUIdentityPOSIXDescriptorReader()
    }

    init(
        limits: Limits = Limits(),
        expectedOwnerUID: uid_t = Darwin.geteuid(),
        descriptorReader: any RuntimeGPUIdentityDescriptorReading
    ) {
        self.limits = limits
        self.expectedOwnerUID = expectedOwnerUID
        self.descriptorReader = descriptorReader
    }

    public func build(
        runtimeID: String,
        runtimeRootURL: URL,
        runtimeContentFingerprint: String,
        helperURL: URL,
        policyURL: URL
    ) async throws -> RuntimeGPUIdentityEvidence {
        let work = RuntimeGPUIdentityEvidenceBuildWork(
            limits: limits,
            expectedOwnerUID: expectedOwnerUID,
            descriptorReader: descriptorReader,
            runtimeID: runtimeID,
            runtimeRootURL: runtimeRootURL,
            runtimeContentFingerprint: runtimeContentFingerprint,
            helperURL: helperURL,
            policyURL: policyURL
        )
        let detachedTask = Task.detached(priority: .utility) {
            try work.build()
        }
        return try await withTaskCancellationHandler {
            try await detachedTask.value
        } onCancel: {
            detachedTask.cancel()
        }
    }
}

struct RuntimeGPUIdentityDescriptorDigest: Equatable, Sendable {
    let sha256: String
    let byteCount: UInt64
}

protocol RuntimeGPUIdentityDescriptorReading: Sendable {
    func digest(
        descriptor: Int32,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) throws -> RuntimeGPUIdentityDescriptorDigest
}

enum RuntimeGPUIdentityDescriptorReadError: Error {
    case exceededLimit
    case sizeMismatch
    case ioFailure
}

struct RuntimeGPUIdentityPOSIXDescriptorReader: RuntimeGPUIdentityDescriptorReading {
    private let bufferSize: Int
    private let didReadChunk: @Sendable (UInt64) -> Void

    init(
        bufferSize: Int = 64 * 1_024,
        didReadChunk: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.bufferSize = max(1, min(bufferSize, 1_024 * 1_024))
        self.didReadChunk = didReadChunk
    }

    func digest(
        descriptor: Int32,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) throws -> RuntimeGPUIdentityDescriptorDigest {
        try Task.checkCancellation()
        guard expectedSize <= maximumBytes else {
            throw RuntimeGPUIdentityDescriptorReadError.exceededLimit
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw RuntimeGPUIdentityDescriptorReadError.ioFailure
        }

        var hasher = SHA256()
        var totalBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            try Task.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw RuntimeGPUIdentityDescriptorReadError.ioFailure
            }
            if bytesRead == 0 {
                break
            }

            let chunkSize = UInt64(bytesRead)
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(chunkSize)
            guard !overflow, newTotal <= maximumBytes else {
                throw RuntimeGPUIdentityDescriptorReadError.exceededLimit
            }
            guard newTotal <= expectedSize else {
                throw RuntimeGPUIdentityDescriptorReadError.sizeMismatch
            }

            hasher.update(data: Data(buffer.prefix(bytesRead)))
            totalBytes = newTotal
            didReadChunk(totalBytes)
            try Task.checkCancellation()
        }

        try Task.checkCancellation()
        guard totalBytes == expectedSize else {
            throw RuntimeGPUIdentityDescriptorReadError.sizeMismatch
        }
        let sha256 = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return RuntimeGPUIdentityDescriptorDigest(
            sha256: sha256,
            byteCount: totalBytes
        )
    }
}

private struct RuntimeGPUIdentityEvidenceBuildWork: Sendable {
    let limits: RuntimeGPUIdentityEvidenceBuilder.Limits
    let expectedOwnerUID: uid_t
    let descriptorReader: any RuntimeGPUIdentityDescriptorReading
    let runtimeID: String
    let runtimeRootURL: URL
    let runtimeContentFingerprint: String
    let helperURL: URL
    let policyURL: URL

    func build() throws -> RuntimeGPUIdentityEvidence {
        try Task.checkCancellation()
        guard limits.maximumHelperBytes > 0,
              limits.maximumPolicyBytes > 0 else {
            throw RuntimeGPUIdentityEvidenceBuilderError.invalidLimits
        }
        guard runtimeRootURL.isFileURL,
              runtimeRootURL.path.first == "/",
              !runtimeRootURL.path.unicodeScalars.contains(where: {
                  $0.value == 0
              }),
              let descriptorRootPath = Self.realPath(runtimeRootURL.path),
              descriptorRootPath != "/" else {
            throw RuntimeGPUIdentityEvidenceBuilderError.invalidRuntimeRoot
        }
        let evidenceRootPath = URL(fileURLWithPath: descriptorRootPath)
            .standardizedFileURL.path
        guard evidenceRootPath != "/",
              URL(fileURLWithPath: evidenceRootPath)
                .standardizedFileURL.path == evidenceRootPath else {
            throw RuntimeGPUIdentityEvidenceBuilderError.invalidRuntimeRoot
        }
        try Task.checkCancellation()

        let helperComponents = try relativeComponents(
            for: helperURL,
            subject: .helper,
            descriptorRootPath: descriptorRootPath,
            evidenceRootPath: evidenceRootPath
        )
        let policyComponents = try relativeComponents(
            for: policyURL,
            subject: .policy,
            descriptorRootPath: descriptorRootPath,
            evidenceRootPath: evidenceRootPath
        )
        try Task.checkCancellation()

        let root = try Self.openCanonicalDirectory(
            at: descriptorRootPath,
            subject: .runtimeRoot
        )
        defer { Darwin.close(root.descriptor) }
        guard root.metadata.ownerUID == expectedOwnerUID else {
            throw RuntimeGPUIdentityEvidenceBuilderError.ownerMismatch(.runtimeRoot)
        }
        guard !root.metadata.isGroupOrOtherWritable else {
            throw RuntimeGPUIdentityEvidenceBuilderError
                .invalidPermissions(.runtimeRoot)
        }
        try Task.checkCancellation()

        let helper = try fileEvidence(
            rootDescriptor: root.descriptor,
            evidenceRootPath: evidenceRootPath,
            relativeComponents: helperComponents,
            subject: .helper,
            maximumBytes: limits.maximumHelperBytes,
            mustBeExecutable: true
        )
        try Task.checkCancellation()
        let policy = try fileEvidence(
            rootDescriptor: root.descriptor,
            evidenceRootPath: evidenceRootPath,
            relativeComponents: policyComponents,
            subject: .policy,
            maximumBytes: limits.maximumPolicyBytes,
            mustBeExecutable: false
        )
        try Task.checkCancellation()

        try validateFinalFileIdentity(
            rootDescriptor: root.descriptor,
            relativeComponents: helperComponents,
            subject: .helper,
            expectedMetadata: helper.metadata
        )
        try Task.checkCancellation()
        try validateFinalFileIdentity(
            rootDescriptor: root.descriptor,
            relativeComponents: policyComponents,
            subject: .policy,
            expectedMetadata: policy.metadata
        )
        try Task.checkCancellation()

        let currentRoot = try Self.openCanonicalDirectory(
            at: descriptorRootPath,
            subject: .runtimeRoot
        )
        defer { Darwin.close(currentRoot.descriptor) }
        guard root.metadata.matchesStableIdentity(of: currentRoot.metadata) else {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileChanged(.runtimeRoot)
        }
        try Task.checkCancellation()

        return try RuntimeGPUIdentityEvidence(
            runtimeID: runtimeID,
            runtimeRoot: evidenceRootPath,
            runtimeContentFingerprint: runtimeContentFingerprint,
            helper: helper.evidence,
            policy: policy.evidence
        )
    }

    private func relativeComponents(
        for fileURL: URL,
        subject: RuntimeGPUIdentityEvidenceSubject,
        descriptorRootPath: String,
        evidenceRootPath: String
    ) throws -> [String] {
        guard fileURL.isFileURL,
              fileURL.path.first == "/",
              !fileURL.path.unicodeScalars.contains(where: {
                  $0.value == 0
              }) else {
            throw RuntimeGPUIdentityEvidenceBuilderError.nonCanonicalPath(subject)
        }

        let listedPath = fileURL.path
        let standardizedPath = fileURL.standardizedFileURL.path
        guard listedPath == standardizedPath else {
            throw RuntimeGPUIdentityEvidenceBuilderError.nonCanonicalPath(subject)
        }

        let listedRootPath = runtimeRootURL.standardizedFileURL.path
        let relativePath: String
        if let relative = Self.strictRelativePath(
            of: standardizedPath,
            under: listedRootPath
        ) {
            relativePath = relative
        } else if let relative = Self.strictRelativePath(
            of: standardizedPath,
            under: descriptorRootPath
        ) {
            relativePath = relative
        } else if let relative = Self.strictRelativePath(
            of: standardizedPath,
            under: evidenceRootPath
        ) {
            relativePath = relative
        } else {
            throw RuntimeGPUIdentityEvidenceBuilderError
                .pathOutsideRuntimeRoot(subject)
        }

        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw RuntimeGPUIdentityEvidenceBuilderError.nonCanonicalPath(subject)
        }
        return components
    }

    private func fileEvidence(
        rootDescriptor: Int32,
        evidenceRootPath: String,
        relativeComponents: [String],
        subject: RuntimeGPUIdentityEvidenceSubject,
        maximumBytes: UInt64,
        mustBeExecutable: Bool
    ) throws -> BuiltFileEvidence {
        try Task.checkCancellation()
        let opened = try Self.openRelativeFile(
            rootDescriptor: rootDescriptor,
            relativeComponents: relativeComponents,
            expectedOwnerUID: expectedOwnerUID,
            subject: subject
        )
        defer { Darwin.close(opened.descriptor) }
        let initial = opened.metadata

        try Self.validateFileMetadata(
            initial,
            subject: subject,
            maximumBytes: maximumBytes,
            mustBeExecutable: mustBeExecutable
        )
        try Task.checkCancellation()

        let digest: RuntimeGPUIdentityDescriptorDigest
        do {
            digest = try descriptorReader.digest(
                descriptor: opened.descriptor,
                expectedSize: initial.size,
                maximumBytes: maximumBytes
            )
        } catch RuntimeGPUIdentityDescriptorReadError.exceededLimit {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileTooLarge(subject)
        } catch RuntimeGPUIdentityDescriptorReadError.sizeMismatch {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileChanged(subject)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RuntimeGPUIdentityEvidenceBuilderError.readFailed(subject)
        }
        guard digest.byteCount == initial.size else {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileChanged(subject)
        }

        let afterRead = try Self.metadata(
            for: opened.descriptor,
            subject: subject
        )
        guard initial.matchesStableIdentity(of: afterRead) else {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileChanged(subject)
        }

        let reopened = try Self.openRelativeFile(
            rootDescriptor: rootDescriptor,
            relativeComponents: relativeComponents,
            expectedOwnerUID: expectedOwnerUID,
            subject: subject
        )
        defer { Darwin.close(reopened.descriptor) }
        guard initial.matchesStableIdentity(of: reopened.metadata) else {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileChanged(subject)
        }
        try Task.checkCancellation()

        let canonicalPath = evidenceRootPath + "/"
            + relativeComponents.joined(separator: "/")
        return BuiltFileEvidence(
            evidence: try RuntimeGPUIdentityFileEvidence(
                canonicalPath: canonicalPath,
                device: initial.device,
                inode: initial.inode,
                size: initial.size,
                modificationTimeNanoseconds: initial.modificationTimeNanoseconds,
                mode: initial.mode,
                sha256: digest.sha256
            ),
            metadata: initial
        )
    }

    private func validateFinalFileIdentity(
        rootDescriptor: Int32,
        relativeComponents: [String],
        subject: RuntimeGPUIdentityEvidenceSubject,
        expectedMetadata: FileMetadata
    ) throws {
        try Task.checkCancellation()
        let reopened = try Self.openRelativeFile(
            rootDescriptor: rootDescriptor,
            relativeComponents: relativeComponents,
            expectedOwnerUID: expectedOwnerUID,
            subject: subject
        )
        defer { Darwin.close(reopened.descriptor) }
        guard expectedMetadata.matchesStableIdentity(of: reopened.metadata) else {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileChanged(subject)
        }
        try Task.checkCancellation()
    }

    private static func validateFileMetadata(
        _ metadata: FileMetadata,
        subject: RuntimeGPUIdentityEvidenceSubject,
        maximumBytes: UInt64,
        mustBeExecutable: Bool
    ) throws {
        guard metadata.fileType == UInt32(S_IFREG) else {
            throw RuntimeGPUIdentityEvidenceBuilderError.notRegularFile(subject)
        }
        guard metadata.linkCount == 1 else {
            throw RuntimeGPUIdentityEvidenceBuilderError.hardLinkNotAllowed(subject)
        }
        guard metadata.size <= maximumBytes else {
            throw RuntimeGPUIdentityEvidenceBuilderError.fileTooLarge(subject)
        }
        guard !metadata.isGroupOrOtherWritable else {
            throw RuntimeGPUIdentityEvidenceBuilderError.invalidPermissions(subject)
        }

        let executableBits = UInt32(S_IXUSR | S_IXGRP | S_IXOTH)
        if mustBeExecutable {
            guard metadata.mode & UInt32(S_IXUSR) != 0 else {
                throw RuntimeGPUIdentityEvidenceBuilderError.invalidPermissions(subject)
            }
        } else {
            guard metadata.mode & executableBits == 0 else {
                throw RuntimeGPUIdentityEvidenceBuilderError.invalidPermissions(subject)
            }
        }
    }

    private static func openCanonicalDirectory(
        at canonicalPath: String,
        subject: RuntimeGPUIdentityEvidenceSubject
    ) throws -> OpenedEntry {
        let components = canonicalPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw RuntimeGPUIdentityEvidenceBuilderError.invalidRuntimeRoot
        }

        var currentDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard currentDescriptor >= 0 else {
            throw RuntimeGPUIdentityEvidenceBuilderError.unavailable(subject)
        }

        do {
            for component in components {
                try Task.checkCancellation()
                try validateDirectoryComponent(
                    component,
                    parentDescriptor: currentDescriptor,
                    subject: subject
                )
                let nextDescriptor = component.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard nextDescriptor >= 0 else {
                    if errno == ELOOP {
                        throw RuntimeGPUIdentityEvidenceBuilderError
                            .symbolicLinkNotAllowed(subject)
                    }
                    throw RuntimeGPUIdentityEvidenceBuilderError.unavailable(subject)
                }
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }

            let metadata = try metadata(
                for: currentDescriptor,
                subject: subject
            )
            guard metadata.fileType == UInt32(S_IFDIR) else {
                throw RuntimeGPUIdentityEvidenceBuilderError.notDirectory(subject)
            }
            return OpenedEntry(
                descriptor: currentDescriptor,
                metadata: metadata
            )
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private static func openRelativeFile(
        rootDescriptor: Int32,
        relativeComponents: [String],
        expectedOwnerUID: uid_t,
        subject: RuntimeGPUIdentityEvidenceSubject
    ) throws -> OpenedEntry {
        guard let finalComponent = relativeComponents.last else {
            throw RuntimeGPUIdentityEvidenceBuilderError.nonCanonicalPath(subject)
        }
        let parentComponents = relativeComponents.dropLast()
        var currentDescriptor = Darwin.dup(rootDescriptor)
        guard currentDescriptor >= 0 else {
            throw RuntimeGPUIdentityEvidenceBuilderError.unavailable(subject)
        }

        do {
            for component in parentComponents {
                try Task.checkCancellation()
                try validateDirectoryComponent(
                    component,
                    parentDescriptor: currentDescriptor,
                    subject: subject
                )
                let nextDescriptor = component.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard nextDescriptor >= 0 else {
                    if errno == ELOOP {
                        throw RuntimeGPUIdentityEvidenceBuilderError
                            .symbolicLinkNotAllowed(subject)
                    }
                    throw RuntimeGPUIdentityEvidenceBuilderError.unavailable(subject)
                }
                let directoryMetadata = try metadata(
                    for: nextDescriptor,
                    subject: subject
                )
                guard directoryMetadata.ownerUID == expectedOwnerUID else {
                    Darwin.close(nextDescriptor)
                    throw RuntimeGPUIdentityEvidenceBuilderError
                        .ownerMismatch(subject)
                }
                guard !directoryMetadata.isGroupOrOtherWritable else {
                    Darwin.close(nextDescriptor)
                    throw RuntimeGPUIdentityEvidenceBuilderError
                        .invalidPermissions(subject)
                }
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }

            try validateFinalComponent(
                finalComponent,
                parentDescriptor: currentDescriptor,
                subject: subject
            )
            let fileDescriptor = finalComponent.withCString {
                Darwin.openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard fileDescriptor >= 0 else {
                if errno == ELOOP {
                    throw RuntimeGPUIdentityEvidenceBuilderError
                        .symbolicLinkNotAllowed(subject)
                }
                throw RuntimeGPUIdentityEvidenceBuilderError.unavailable(subject)
            }
            let fileMetadata: FileMetadata
            do {
                fileMetadata = try metadata(
                    for: fileDescriptor,
                    subject: subject
                )
            } catch {
                Darwin.close(fileDescriptor)
                throw error
            }
            guard fileMetadata.ownerUID == expectedOwnerUID else {
                Darwin.close(fileDescriptor)
                throw RuntimeGPUIdentityEvidenceBuilderError.ownerMismatch(subject)
            }
            Darwin.close(currentDescriptor)
            return OpenedEntry(
                descriptor: fileDescriptor,
                metadata: fileMetadata
            )
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private static func validateDirectoryComponent(
        _ component: String,
        parentDescriptor: Int32,
        subject: RuntimeGPUIdentityEvidenceSubject
    ) throws {
        var information = stat()
        let status = component.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard status == 0 else {
            throw RuntimeGPUIdentityEvidenceBuilderError.unavailable(subject)
        }
        let type = information.st_mode & S_IFMT
        if type == S_IFLNK {
            throw RuntimeGPUIdentityEvidenceBuilderError
                .symbolicLinkNotAllowed(subject)
        }
        guard type == S_IFDIR else {
            throw RuntimeGPUIdentityEvidenceBuilderError
                .invalidPathComponent(subject)
        }
    }

    private static func validateFinalComponent(
        _ component: String,
        parentDescriptor: Int32,
        subject: RuntimeGPUIdentityEvidenceSubject
    ) throws {
        var information = stat()
        let status = component.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard status == 0 else {
            throw RuntimeGPUIdentityEvidenceBuilderError.unavailable(subject)
        }
        if information.st_mode & S_IFMT == S_IFLNK {
            throw RuntimeGPUIdentityEvidenceBuilderError
                .symbolicLinkNotAllowed(subject)
        }
    }

    private static func metadata(
        for descriptor: Int32,
        subject: RuntimeGPUIdentityEvidenceSubject
    ) throws -> FileMetadata {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_size >= 0 else {
            throw RuntimeGPUIdentityEvidenceBuilderError.invalidMetadata(subject)
        }

        let seconds = Int64(information.st_mtimespec.tv_sec)
        let nanoseconds = Int64(information.st_mtimespec.tv_nsec)
        let modificationTime = try nanosecondTimestamp(
            seconds: seconds,
            nanoseconds: nanoseconds,
            subject: subject
        )
        let changeTime = try nanosecondTimestamp(
            seconds: Int64(information.st_ctimespec.tv_sec),
            nanoseconds: Int64(information.st_ctimespec.tv_nsec),
            subject: subject
        )

        return FileMetadata(
            device: UInt64(bitPattern: Int64(information.st_dev)),
            inode: UInt64(information.st_ino),
            size: UInt64(information.st_size),
            modificationTimeNanoseconds: modificationTime,
            changeTimeNanoseconds: changeTime,
            mode: UInt32(information.st_mode),
            ownerUID: information.st_uid,
            linkCount: UInt64(information.st_nlink)
        )
    }

    private static func nanosecondTimestamp(
        seconds: Int64,
        nanoseconds: Int64,
        subject: RuntimeGPUIdentityEvidenceSubject
    ) throws -> Int64 {
        let (wholeSeconds, multiplicationOverflow) = seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        let (timestamp, additionOverflow) = wholeSeconds
            .addingReportingOverflow(nanoseconds)
        guard !multiplicationOverflow, !additionOverflow else {
            throw RuntimeGPUIdentityEvidenceBuilderError.invalidMetadata(subject)
        }
        return timestamp
    }

    private static func strictRelativePath(
        of candidatePath: String,
        under rootPath: String
    ) -> String? {
        guard candidatePath != rootPath,
              candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(candidatePath.dropFirst(rootPath.count + 1))
    }

    private static func realPath(_ path: String) -> String? {
        path.withCString { pathPointer in
            guard let resolved = Darwin.realpath(pathPointer, nil) else {
                return nil
            }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
    }

    private struct OpenedEntry {
        let descriptor: Int32
        let metadata: FileMetadata
    }

    private struct BuiltFileEvidence {
        let evidence: RuntimeGPUIdentityFileEvidence
        let metadata: FileMetadata
    }

    private struct FileMetadata {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationTimeNanoseconds: Int64
        let changeTimeNanoseconds: Int64
        let mode: UInt32
        let ownerUID: uid_t
        let linkCount: UInt64

        var fileType: UInt32 {
            mode & UInt32(S_IFMT)
        }

        var isGroupOrOtherWritable: Bool {
            mode & UInt32(S_IWGRP | S_IWOTH) != 0
        }

        func matchesStableIdentity(of other: FileMetadata) -> Bool {
            device == other.device
                && inode == other.inode
                && size == other.size
                && modificationTimeNanoseconds
                    == other.modificationTimeNanoseconds
                && changeTimeNanoseconds == other.changeTimeNanoseconds
                && mode == other.mode
                && ownerUID == other.ownerUID
                && linkCount == other.linkCount
        }
    }
}
