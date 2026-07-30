import AppCore
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Testing
@testable import RuntimeCatalog

@Suite("Runtime GPU identity evidence builder")
struct RuntimeGPUIdentityEvidenceBuilderTests {
    @Test("builds stable evidence from descriptor-verified runtime files")
    func buildsStableEvidence() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let builder = RuntimeGPUIdentityEvidenceBuilder()

        let first = try await fixture.build(using: builder)
        let second = try await fixture.build(using: builder)
        let canonicalRoot = fixture.runtimeRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let helperMetadata = try posixMetadata(at: fixture.helper)
        let policyMetadata = try posixMetadata(at: fixture.policy)

        #expect(first == second)
        #expect(first.runtimeID == "runtime-test")
        #expect(first.runtimeRoot == canonicalRoot)
        #expect(first.runtimeContentFingerprint == "content-tree-test")
        #expect(
            first.helper.canonicalPath
                == canonicalRoot + "/libexec/switchyard-host-gpu-info"
        )
        #expect(
            first.policy.canonicalPath
                == canonicalRoot
                    + "/share/switchyard/gpu_capability_policy.sh"
        )
        #expect(first.helper.size == UInt64(fixture.helperData.count))
        #expect(first.policy.size == UInt64(fixture.policyData.count))
        #expect(first.helper.device == helperMetadata.device)
        #expect(first.helper.inode == helperMetadata.inode)
        #expect(first.helper.mode == helperMetadata.mode)
        #expect(
            first.helper.modificationTimeNanoseconds
                == helperMetadata.modificationTimeNanoseconds
        )
        #expect(first.policy.device == policyMetadata.device)
        #expect(first.policy.inode == policyMetadata.inode)
        #expect(first.policy.mode == policyMetadata.mode)
        #expect(
            first.policy.modificationTimeNanoseconds
                == policyMetadata.modificationTimeNanoseconds
        )
        #expect(first.helper.mode & UInt32(S_IXUSR) != 0)
        #expect(first.policy.mode & UInt32(S_IXUSR | S_IXGRP | S_IXOTH) == 0)
        #expect(first.helper.sha256 == sha256(fixture.helperData))
        #expect(first.policy.sha256 == sha256(fixture.policyData))
    }

    @Test("rejects paths outside the runtime root")
    func rejectsOutsidePath() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let outsideHelper = fixture.base.appendingPathComponent("outside-helper")
        try fixture.helperData.write(to: outsideHelper)
        try setPermissions(0o700, at: outsideHelper)

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .pathOutsideRuntimeRoot(.helper)
        ) {
            _ = try await fixture.build(
                using: RuntimeGPUIdentityEvidenceBuilder(),
                helperURL: outsideHelper
            )
        }
    }

    @Test("rejects symbolic links in final and intermediate components")
    func rejectsSymbolicLinks() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let actualHelper = fixture.runtimeRoot
            .appendingPathComponent("actual-helper")
        try fixture.helperData.write(to: actualHelper)
        try setPermissions(0o700, at: actualHelper)
        try FileManager.default.removeItem(at: fixture.helper)
        try FileManager.default.createSymbolicLink(
            at: fixture.helper,
            withDestinationURL: actualHelper
        )

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .symbolicLinkNotAllowed(.helper)
        ) {
            _ = try await fixture.build(
                using: RuntimeGPUIdentityEvidenceBuilder()
            )
        }

        try FileManager.default.removeItem(at: fixture.helper)
        let realDirectory = fixture.runtimeRoot
            .appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        let nestedHelper = realDirectory.appendingPathComponent("gpu-helper")
        try fixture.helperData.write(to: nestedHelper)
        try setPermissions(0o700, at: nestedHelper)
        let linkedDirectory = fixture.runtimeRoot
            .appendingPathComponent("linked-bin", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .symbolicLinkNotAllowed(.helper)
        ) {
            _ = try await fixture.build(
                using: RuntimeGPUIdentityEvidenceBuilder(),
                helperURL: linkedDirectory.appendingPathComponent("gpu-helper")
            )
        }
    }

    @Test("enforces helper and policy execution modes")
    func enforcesExecutionModes() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let builder = RuntimeGPUIdentityEvidenceBuilder()
        try setPermissions(0o600, at: fixture.helper)

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .invalidPermissions(.helper)
        ) {
            _ = try await fixture.build(using: builder)
        }

        try setPermissions(0o700, at: fixture.helper)
        try setPermissions(0o700, at: fixture.policy)
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .invalidPermissions(.policy)
        ) {
            _ = try await fixture.build(using: builder)
        }
    }

    @Test("rejects group- or other-writable runtime evidence paths")
    func rejectsWritableRuntimePaths() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let builder = RuntimeGPUIdentityEvidenceBuilder()

        try setPermissions(0o770, at: fixture.runtimeRoot)
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .invalidPermissions(.runtimeRoot)
        ) {
            _ = try await fixture.build(using: builder)
        }

        try setPermissions(0o700, at: fixture.runtimeRoot)
        try setPermissions(
            0o770,
            at: fixture.helper.deletingLastPathComponent()
        )
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .invalidPermissions(.helper)
        ) {
            _ = try await fixture.build(using: builder)
        }

        try setPermissions(
            0o700,
            at: fixture.helper.deletingLastPathComponent()
        )
        try setPermissions(0o720, at: fixture.helper)
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .invalidPermissions(.helper)
        ) {
            _ = try await fixture.build(using: builder)
        }

        try setPermissions(0o700, at: fixture.helper)
        try setPermissions(0o620, at: fixture.policy)
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .invalidPermissions(.policy)
        ) {
            _ = try await fixture.build(using: builder)
        }
    }

    @Test("rejects oversized, hard-linked, and special files")
    func rejectsUnsafeFileKinds() async throws {
        let oversizedFixture = try EvidenceFixture()
        defer { oversizedFixture.remove() }
        let smallLimitBuilder = RuntimeGPUIdentityEvidenceBuilder(
            limits: .init(
                maximumHelperBytes: UInt64(
                    oversizedFixture.helperData.count - 1
                ),
                maximumPolicyBytes: 1_024
            )
        )
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .fileTooLarge(.helper)
        ) {
            _ = try await oversizedFixture.build(using: smallLimitBuilder)
        }

        let hardLinkFixture = try EvidenceFixture()
        defer { hardLinkFixture.remove() }
        try FileManager.default.linkItem(
            at: hardLinkFixture.helper,
            to: hardLinkFixture.runtimeRoot
                .appendingPathComponent("helper-hard-link")
        )
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .hardLinkNotAllowed(.helper)
        ) {
            _ = try await hardLinkFixture.build(
                using: RuntimeGPUIdentityEvidenceBuilder()
            )
        }

        let specialFixture = try EvidenceFixture()
        defer { specialFixture.remove() }
        try FileManager.default.removeItem(at: specialFixture.helper)
        let fifoResult = specialFixture.helper.path.withCString {
            Darwin.mkfifo($0, 0o700)
        }
        #expect(fifoResult == 0)
        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .notRegularFile(.helper)
        ) {
            _ = try await specialFixture.build(
                using: RuntimeGPUIdentityEvidenceBuilder()
            )
        }
    }

    @Test("rejects a runtime tree owned by a different expected user")
    func rejectsOwnerMismatch() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let builder = RuntimeGPUIdentityEvidenceBuilder(
            expectedOwnerUID: Darwin.geteuid() &+ 1,
            descriptorReader: RuntimeGPUIdentityPOSIXDescriptorReader()
        )

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .ownerMismatch(.runtimeRoot)
        ) {
            _ = try await fixture.build(using: builder)
        }
    }

    @Test("rejects in-place mutation during streaming")
    func rejectsMutationDuringRead() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let helper = fixture.helper
        let reader = MutatingDescriptorReader {
            let handle = try FileHandle(forWritingTo: helper)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("-changed".utf8))
        }
        let builder = RuntimeGPUIdentityEvidenceBuilder(
            descriptorReader: reader
        )

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .fileChanged(.helper)
        ) {
            _ = try await fixture.build(using: builder)
        }
    }

    @Test("rejects rename-and-replace identity changes")
    func rejectsIdentityReplacement() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let helper = fixture.helper
        let replacement = fixture.runtimeRoot
            .appendingPathComponent("replacement-helper")
        try fixture.helperData.write(to: replacement)
        try setPermissions(0o700, at: replacement)

        let reader = MutatingDescriptorReader {
            let result = replacement.path.withCString { replacementPath in
                helper.path.withCString { helperPath in
                    Darwin.rename(replacementPath, helperPath)
                }
            }
            guard result == 0 else {
                throw TestMutationError.renameFailed
            }
        }
        let builder = RuntimeGPUIdentityEvidenceBuilder(
            descriptorReader: reader
        )

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .fileChanged(.helper)
        ) {
            _ = try await fixture.build(using: builder)
        }
    }

    @Test("revalidates helper identity after policy hashing")
    func rejectsHelperReplacementDuringPolicyRead() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        let helper = fixture.helper
        let replacement = fixture.runtimeRoot
            .appendingPathComponent("policy-triggered-replacement")
        try fixture.helperData.write(to: replacement)
        try setPermissions(0o700, at: replacement)

        let reader = ReadIndexedMutatingDescriptorReader(
            mutationReadIndex: 2
        ) {
            let result = replacement.path.withCString { replacementPath in
                helper.path.withCString { helperPath in
                    Darwin.rename(replacementPath, helperPath)
                }
            }
            guard result == 0 else {
                throw TestMutationError.renameFailed
            }
        }
        let builder = RuntimeGPUIdentityEvidenceBuilder(
            descriptorReader: reader
        )

        await #expect(
            throws: RuntimeGPUIdentityEvidenceBuilderError
                .fileChanged(.helper)
        ) {
            _ = try await fixture.build(using: builder)
        }
    }

    @Test("parent cancellation stops descriptor hashing after its current chunk")
    func cancellationStopsHashing() async throws {
        let fixture = try EvidenceFixture()
        defer { fixture.remove() }
        try Data(repeating: 0xA5, count: 256 * 1_024)
            .write(to: fixture.helper)
        try setPermissions(0o700, at: fixture.helper)

        let probe = DescriptorReadCancellationProbe()
        let reader = RuntimeGPUIdentityPOSIXDescriptorReader(
            bufferSize: 4 * 1_024,
            didReadChunk: { _ in
                probe.didReadChunk()
            }
        )
        let builder = RuntimeGPUIdentityEvidenceBuilder(
            descriptorReader: reader
        )
        let buildTask = Task {
            try await fixture.build(using: builder)
        }

        let reachedFirstChunk = await Task.detached {
            probe.waitForFirstChunk()
        }.value
        #expect(reachedFirstChunk)
        buildTask.cancel()
        probe.releaseReader()

        await #expect(throws: CancellationError.self) {
            _ = try await buildTask.value
        }
        #expect(probe.chunkCount == 1)
    }
}

private final class EvidenceFixture: @unchecked Sendable {
    let base: URL
    let runtimeRoot: URL
    let helper: URL
    let policy: URL
    let helperData = Data("gpu-helper-fixture-v1".utf8)
    let policyData = Data(#"{"policy":"fixture-v1"}"#.utf8)

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "switchyard-gpu-evidence-\(UUID().uuidString)",
                isDirectory: true
            )
        runtimeRoot = base.appendingPathComponent("runtime", isDirectory: true)
        helper = runtimeRoot.appendingPathComponent(
            "libexec/switchyard-host-gpu-info"
        )
        policy = runtimeRoot.appendingPathComponent(
            "share/switchyard/gpu_capability_policy.sh"
        )
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: policy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try setPermissions(0o700, at: runtimeRoot)
        try setPermissions(
            0o700,
            at: helper.deletingLastPathComponent()
        )
        try setPermissions(
            0o700,
            at: runtimeRoot.appendingPathComponent("share")
        )
        try setPermissions(
            0o700,
            at: policy.deletingLastPathComponent()
        )
        try helperData.write(to: helper)
        try policyData.write(to: policy)
        try setPermissions(0o700, at: helper)
        try setPermissions(0o600, at: policy)
    }

    func build(
        using builder: RuntimeGPUIdentityEvidenceBuilder,
        helperURL: URL? = nil,
        policyURL: URL? = nil
    ) async throws -> RuntimeGPUIdentityEvidence {
        try await builder.build(
            runtimeID: "runtime-test",
            runtimeRootURL: runtimeRoot,
            runtimeContentFingerprint: "content-tree-test",
            helperURL: helperURL ?? helper,
            policyURL: policyURL ?? policy
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private struct MutatingDescriptorReader: RuntimeGPUIdentityDescriptorReading {
    let mutation: @Sendable () throws -> Void

    init(mutation: @escaping @Sendable () throws -> Void) {
        self.mutation = mutation
    }

    func digest(
        descriptor: Int32,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) throws -> RuntimeGPUIdentityDescriptorDigest {
        let digest = try RuntimeGPUIdentityPOSIXDescriptorReader().digest(
            descriptor: descriptor,
            expectedSize: expectedSize,
            maximumBytes: maximumBytes
        )
        try mutation()
        return digest
    }
}

private final class ReadIndexedMutatingDescriptorReader:
    RuntimeGPUIdentityDescriptorReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let mutationReadIndex: Int
    private let mutation: @Sendable () throws -> Void
    private var readCount = 0

    init(
        mutationReadIndex: Int,
        mutation: @escaping @Sendable () throws -> Void
    ) {
        self.mutationReadIndex = mutationReadIndex
        self.mutation = mutation
    }

    func digest(
        descriptor: Int32,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) throws -> RuntimeGPUIdentityDescriptorDigest {
        let digest = try RuntimeGPUIdentityPOSIXDescriptorReader().digest(
            descriptor: descriptor,
            expectedSize: expectedSize,
            maximumBytes: maximumBytes
        )
        lock.lock()
        readCount += 1
        let shouldMutate = readCount == mutationReadIndex
        lock.unlock()
        if shouldMutate {
            try mutation()
        }
        return digest
    }
}

private final class DescriptorReadCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstChunk = DispatchSemaphore(value: 0)
    private let readerRelease = DispatchSemaphore(value: 0)
    private var recordedChunkCount = 0

    var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedChunkCount
    }

    func didReadChunk() {
        lock.lock()
        recordedChunkCount += 1
        let isFirstChunk = recordedChunkCount == 1
        lock.unlock()
        guard isFirstChunk else { return }

        firstChunk.signal()
        _ = readerRelease.wait(timeout: .now() + 5)
    }

    func waitForFirstChunk() -> Bool {
        firstChunk.wait(timeout: .now() + 2) == .success
    }

    func releaseReader() {
        readerRelease.signal()
    }
}

private enum TestMutationError: Error {
    case renameFailed
    case statFailed
}

private func setPermissions(_ permissions: Int, at url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: url.path
    )
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}

private struct ExpectedFileMetadata {
    let device: UInt64
    let inode: UInt64
    let modificationTimeNanoseconds: Int64
    let mode: UInt32
}

private func posixMetadata(at url: URL) throws -> ExpectedFileMetadata {
    var information = stat()
    let result = url.path.withCString {
        Darwin.lstat($0, &information)
    }
    guard result == 0 else {
        throw TestMutationError.statFailed
    }
    let seconds = Int64(information.st_mtimespec.tv_sec)
    let nanoseconds = Int64(information.st_mtimespec.tv_nsec)
    return ExpectedFileMetadata(
        device: UInt64(bitPattern: Int64(information.st_dev)),
        inode: UInt64(information.st_ino),
        modificationTimeNanoseconds: seconds * 1_000_000_000 + nanoseconds,
        mode: UInt32(information.st_mode)
    )
}
