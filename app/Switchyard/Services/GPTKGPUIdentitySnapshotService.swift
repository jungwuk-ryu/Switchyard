import AppCore
import Darwin
import Foundation
import Metal
import RuntimeCatalog

struct GPTKGPUIdentitySystemContext: Equatable, Sendable {
    let operatingSystemBuild: String
    let defaultGPURegistryID: UInt64
}

enum GPTKGPUIdentitySystemContextError: Error, Equatable, Sendable {
    case operatingSystemBuildUnavailable
    case defaultGPUUnavailable
}

protocol GPTKGPUIdentitySystemContextProviding: Sendable {
    func currentContext() async throws -> GPTKGPUIdentitySystemContext
}

struct MetalGPTKGPUIdentitySystemContextProvider:
    GPTKGPUIdentitySystemContextProviding,
    Sendable
{
    func currentContext() async throws -> GPTKGPUIdentitySystemContext {
        let task = Task.detached(priority: .utility) {
            let operatingSystemBuild = try Self.operatingSystemBuild()
            guard let registryID = MTLCreateSystemDefaultDevice()?.registryID,
                  registryID != 0 else {
                throw GPTKGPUIdentitySystemContextError.defaultGPUUnavailable
            }
            return GPTKGPUIdentitySystemContext(
                operatingSystemBuild: operatingSystemBuild,
                defaultGPURegistryID: registryID
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func operatingSystemBuild() throws -> String {
        var byteCount = 0
        guard Darwin.sysctlbyname(
            "kern.osversion",
            nil,
            &byteCount,
            nil,
            0
        ) == 0,
        byteCount > 1 else {
            throw GPTKGPUIdentitySystemContextError
                .operatingSystemBuildUnavailable
        }

        var bytes = [CChar](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes { buffer in
            Darwin.sysctlbyname(
                "kern.osversion",
                buffer.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0,
              let terminator = bytes.firstIndex(of: 0),
              terminator > bytes.startIndex else {
            throw GPTKGPUIdentitySystemContextError
                .operatingSystemBuildUnavailable
        }

        let build = String(
            decoding: bytes[..<terminator].map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
        guard !build.isEmpty else {
            throw GPTKGPUIdentitySystemContextError
                .operatingSystemBuildUnavailable
        }
        return build
    }
}

protocol RuntimeGPUIdentityEvidenceBuilding: Sendable {
    func build(
        runtimeID: String,
        runtimeRootURL: URL,
        runtimeContentFingerprint: String,
        helperURL: URL,
        policyURL: URL
    ) async throws -> RuntimeGPUIdentityEvidence
}

extension RuntimeGPUIdentityEvidenceBuilder:
    RuntimeGPUIdentityEvidenceBuilding {}

enum GPTKGPUIdentitySnapshotServiceError: Error, Equatable, Sendable {
    case invalidRuntimeWinePath
    case runtimeRootMismatch
    case systemContextUnavailable
    case invalidSystemContext(RuntimeGPUIdentityEvidenceError)
    case untrustedRuntimeEvidence(RuntimeGPUIdentityEvidenceBuilderError)
    case runtimeEvidenceEvaluationFailed
    case helperExecutionFailed
    case helperTimedOut
    case helperExited(Int32)
    case helperOutputTruncated
    case helperStandardError
    case helperOutputTooLarge
    case invalidHelperOutput(HostGPUIdentityError)
    case runtimeEvidenceChanged
}

final class GPTKGPUIdentitySnapshotService: @unchecked Sendable {
    static let helperRelativePath = "libexec/switchyard-host-gpu-info"
    static let policyRelativePath =
        "share/switchyard/gpu_capability_policy.sh"
    static let maximumHelperOutputBytes =
        HostGPUIdentity.maximumCanonicalTSVBytes
    static let maximumHelperDeadline: Duration = .seconds(5)

    private let contextProvider: any GPTKGPUIdentitySystemContextProviding
    private let evidenceBuilder: any RuntimeGPUIdentityEvidenceBuilding
    private let cache: GPTKGPUIdentityCache

    init(
        contextProvider: any GPTKGPUIdentitySystemContextProviding =
            MetalGPTKGPUIdentitySystemContextProvider(),
        evidenceBuilder: any RuntimeGPUIdentityEvidenceBuilding =
            RuntimeGPUIdentityEvidenceBuilder(),
        commandExecutor: any RunnerCommandExecuting = RunnerCommandExecutor(
            outputByteLimit: maximumHelperOutputBytes
        ),
        helperDeadline: Duration = maximumHelperDeadline,
        maximumCacheEntryCount: Int = 8,
        counters: PerformanceCounters = .shared
    ) {
        let boundedDeadline = Self.boundedDeadline(helperDeadline)
        self.contextProvider = contextProvider
        self.evidenceBuilder = evidenceBuilder

        let loader = GPTKGPUIdentitySnapshotLoader(
            evidenceBuilder: evidenceBuilder,
            commandExecutor: commandExecutor,
            helperDeadline: boundedDeadline
        )
        self.cache = GPTKGPUIdentityCache(
            maximumEntryCount: maximumCacheEntryCount,
            counters: counters
        ) { key in
            try await loader.load(key)
        }
    }

    func snapshotIfNeeded(
        forGPTKLaunch isGPTKLaunch: Bool,
        runtime: RuntimeBuild,
        runtimeRootURL: URL,
        runtimeContentFingerprint: String
    ) async throws -> GPTKGPUIdentitySnapshot? {
        guard isGPTKLaunch else { return nil }
        try Task.checkCancellation()

        let canonicalRuntimeRootURL = try Self.validatedRuntimeRoot(
            for: runtime,
            suppliedRootURL: runtimeRootURL
        )
        let helperURL = canonicalRuntimeRootURL.appendingPathComponent(
            Self.helperRelativePath,
            isDirectory: false
        )
        let policyURL = canonicalRuntimeRootURL.appendingPathComponent(
            Self.policyRelativePath,
            isDirectory: false
        )
        let evidence = try await trustedEvidence(
            runtime: runtime,
            runtimeRootURL: canonicalRuntimeRootURL,
            runtimeContentFingerprint: runtimeContentFingerprint,
            helperURL: helperURL,
            policyURL: policyURL
        )
        let context: GPTKGPUIdentitySystemContext
        do {
            context = try await contextProvider.currentContext()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GPTKGPUIdentitySnapshotServiceError
                .systemContextUnavailable
        }

        let key: GPTKGPUIdentityCacheKey
        do {
            key = try GPTKGPUIdentityCacheKey(
                operatingSystemBuild: context.operatingSystemBuild,
                defaultGPURegistryID: context.defaultGPURegistryID,
                runtime: evidence
            )
        } catch let error as RuntimeGPUIdentityEvidenceError {
            throw GPTKGPUIdentitySnapshotServiceError
                .invalidSystemContext(error)
        } catch {
            throw GPTKGPUIdentitySnapshotServiceError
                .systemContextUnavailable
        }
        return try await cache.snapshot(for: key)
    }

    func invalidateAll() async {
        await cache.invalidateAll()
    }

    private func trustedEvidence(
        runtime: RuntimeBuild,
        runtimeRootURL: URL,
        runtimeContentFingerprint: String,
        helperURL: URL,
        policyURL: URL
    ) async throws -> RuntimeGPUIdentityEvidence {
        do {
            return try await evidenceBuilder.build(
                runtimeID: runtime.id,
                runtimeRootURL: runtimeRootURL,
                runtimeContentFingerprint: runtimeContentFingerprint,
                helperURL: helperURL,
                policyURL: policyURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RuntimeGPUIdentityEvidenceBuilderError {
            throw GPTKGPUIdentitySnapshotServiceError
                .untrustedRuntimeEvidence(error)
        } catch {
            throw GPTKGPUIdentitySnapshotServiceError
                .runtimeEvidenceEvaluationFailed
        }
    }

    private static func boundedDeadline(_ deadline: Duration) -> Duration {
        min(max(deadline, .milliseconds(1)), maximumHelperDeadline)
    }

    private static func validatedRuntimeRoot(
        for runtime: RuntimeBuild,
        suppliedRootURL: URL
    ) throws -> URL {
        guard runtime.winePath.first == "/",
              !runtime.winePath.unicodeScalars.contains(where: {
                  $0.value <= 0x1F || $0.value == 0x7F
              }) else {
            throw GPTKGPUIdentitySnapshotServiceError
                .invalidRuntimeWinePath
        }

        let canonicalWineURL = URL(fileURLWithPath: runtime.winePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let wineDirectoryURL = canonicalWineURL
            .deletingLastPathComponent()
        let derivedRootURL = (
            wineDirectoryURL.lastPathComponent == "bin"
                ? wineDirectoryURL.deletingLastPathComponent()
                : wineDirectoryURL
        )
        .standardizedFileURL
        guard derivedRootURL.path != "/" else {
            throw GPTKGPUIdentitySnapshotServiceError
                .invalidRuntimeWinePath
        }

        let canonicalSuppliedRootURL = suppliedRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard canonicalSuppliedRootURL.path == derivedRootURL.path else {
            throw GPTKGPUIdentitySnapshotServiceError.runtimeRootMismatch
        }
        return derivedRootURL
    }
}

private struct GPTKGPUIdentitySnapshotLoader: Sendable {
    let evidenceBuilder: any RuntimeGPUIdentityEvidenceBuilding
    let commandExecutor: any RunnerCommandExecuting
    let helperDeadline: Duration

    func load(
        _ key: GPTKGPUIdentityCacheKey
    ) async throws -> GPTKGPUIdentitySnapshot {
        let result: RunnerCommandResult
        do {
            result = try await commandExecutor.execute(
                executableURL: URL(
                    fileURLWithPath: key.runtime.helper.canonicalPath
                ),
                arguments: [],
                deadline: helperDeadline
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch RunnerCommandExecutorError.timedOut {
            throw GPTKGPUIdentitySnapshotServiceError.helperTimedOut
        } catch {
            throw GPTKGPUIdentitySnapshotServiceError.helperExecutionFailed
        }

        guard result.terminationStatus == 0 else {
            throw GPTKGPUIdentitySnapshotServiceError.helperExited(
                result.terminationStatus
            )
        }
        guard !result.didTruncateStandardOutput,
              !result.didTruncateStandardError else {
            throw GPTKGPUIdentitySnapshotServiceError.helperOutputTruncated
        }
        guard result.standardError.isEmpty else {
            throw GPTKGPUIdentitySnapshotServiceError.helperStandardError
        }
        guard result.standardOutput.count <=
                GPTKGPUIdentitySnapshotService.maximumHelperOutputBytes else {
            throw GPTKGPUIdentitySnapshotServiceError.helperOutputTooLarge
        }

        let identity: HostGPUIdentity
        do {
            identity = try HostGPUIdentity(
                tsvData: result.standardOutput
            )
        } catch let error as HostGPUIdentityError {
            throw GPTKGPUIdentitySnapshotServiceError
                .invalidHelperOutput(error)
        } catch {
            throw GPTKGPUIdentitySnapshotServiceError
                .helperExecutionFailed
        }

        let currentEvidence: RuntimeGPUIdentityEvidence
        do {
            currentEvidence = try await evidenceBuilder.build(
                runtimeID: key.runtime.runtimeID,
                runtimeRootURL: URL(
                    fileURLWithPath: key.runtime.runtimeRoot,
                    isDirectory: true
                ),
                runtimeContentFingerprint:
                    key.runtime.runtimeContentFingerprint,
                helperURL: URL(
                    fileURLWithPath: key.runtime.helper.canonicalPath
                ),
                policyURL: URL(
                    fileURLWithPath: key.runtime.policy.canonicalPath
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RuntimeGPUIdentityEvidenceBuilderError {
            throw GPTKGPUIdentitySnapshotServiceError
                .untrustedRuntimeEvidence(error)
        } catch {
            throw GPTKGPUIdentitySnapshotServiceError
                .runtimeEvidenceEvaluationFailed
        }
        guard currentEvidence == key.runtime else {
            throw GPTKGPUIdentitySnapshotServiceError.runtimeEvidenceChanged
        }

        return GPTKGPUIdentitySnapshot(
            cacheKey: key,
            identity: identity
        )
    }
}
