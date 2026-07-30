import AppCore
import Foundation
import Testing
@testable import Switchyard

@Suite("GPTK GPU Identity Cache")
struct GPTKGPUIdentityCacheTests {
    @Test("caches a validated result and records before-after counters")
    func cachesValidatedResult() async throws {
        let key = try makeGPUIdentityCacheKey()
        let beforeLoader = GPUIdentityImmediateLoader()
        let beforeCounters = PerformanceCounters()
        let uncached = GPTKGPUIdentityCache(
            maximumEntryCount: 0,
            counters: beforeCounters
        ) { key in
            try await beforeLoader.load(key)
        }

        _ = try await uncached.snapshot(for: key)
        _ = try await uncached.snapshot(for: key)

        #expect(await beforeLoader.executionCount == 2)
        let beforeMetrics = beforeCounters.snapshot()
        #expect(beforeMetrics[.gptkGPUIdentityRequests] == 2)
        #expect(beforeMetrics[.gptkGPUIdentityHelperExecutions] == 2)
        #expect(beforeMetrics[.gptkGPUIdentityCacheHits] == 0)

        let afterLoader = GPUIdentityImmediateLoader()
        let afterCounters = PerformanceCounters()
        let cached = GPTKGPUIdentityCache(counters: afterCounters) { key in
            try await afterLoader.load(key)
        }

        let first = try await cached.snapshot(for: key)
        let second = try await cached.snapshot(for: key)

        #expect(first == second)
        #expect(await afterLoader.executionCount == 1)
        let afterMetrics = afterCounters.snapshot()
        #expect(afterMetrics[.gptkGPUIdentityRequests] == 2)
        #expect(afterMetrics[.gptkGPUIdentityHelperExecutions] == 1)
        #expect(afterMetrics[.gptkGPUIdentityCacheHits] == 1)
    }

    @Test(
        "coalesces concurrent requests for the same complete key",
        .timeLimit(.minutes(1))
    )
    func coalescesSameKey() async throws {
        let key = try makeGPUIdentityCacheKey()
        let loader = ControlledGPUIdentityLoader()
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(counters: counters) { key in
            try await loader.load(key)
        }

        let first = Task {
            try await cache.snapshot(for: key)
        }
        await loader.waitForExecutionCount(1)
        let second = Task {
            try await cache.snapshot(for: key)
        }
        await waitForGPUIdentityCondition {
            counters.snapshot()[.gptkGPUIdentityRequests] == 2
        }

        try await loader.succeed(0, description: "Shared")
        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value

        #expect(firstSnapshot == secondSnapshot)
        #expect(await loader.executionCount == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 2)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 1)
        #expect(metrics[.gptkGPUIdentityCacheHits] == 0)
    }

    @Test(
        "does not share work across cache keys",
        .timeLimit(.minutes(1))
    )
    func isolatesDifferentKeys() async throws {
        let firstKey = try makeGPUIdentityCacheKey(
            operatingSystemBuild: "24G90"
        )
        let secondKey = try makeGPUIdentityCacheKey(
            operatingSystemBuild: "24G91"
        )
        let loader = ControlledGPUIdentityLoader()
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(counters: counters) { key in
            try await loader.load(key)
        }

        let first = Task {
            try await cache.snapshot(for: firstKey)
        }
        let second = Task {
            try await cache.snapshot(for: secondKey)
        }
        await loader.waitForExecutionCount(2)

        try await loader.succeed(1, description: "Second")
        try await loader.succeed(0, description: "First")
        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value

        #expect(firstSnapshot.cacheKey == firstKey)
        #expect(secondSnapshot.cacheKey == secondKey)
        #expect(firstSnapshot != secondSnapshot)
        #expect(await loader.executionCount == 2)
        #expect(
            counters.snapshot()[.gptkGPUIdentityHelperExecutions] == 2
        )
    }

    @Test(
        "cancelling one waiter leaves shared work available to another",
        .timeLimit(.minutes(1))
    )
    func waiterCancellationDoesNotCancelSharedWork() async throws {
        let key = try makeGPUIdentityCacheKey()
        let loader = ControlledGPUIdentityLoader()
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(counters: counters) { key in
            try await loader.load(key)
        }

        let cancelledWaiter = Task {
            try await cache.snapshot(for: key)
        }
        await loader.waitForExecutionCount(1)
        let survivingWaiter = Task {
            try await cache.snapshot(for: key)
        }
        await waitForGPUIdentityCondition {
            counters.snapshot()[.gptkGPUIdentityRequests] == 2
        }

        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }

        try await loader.succeed(0, description: "Survivor")
        let survivingSnapshot = try await survivingWaiter.value
        let cachedSnapshot = try await cache.snapshot(for: key)

        #expect(survivingSnapshot == cachedSnapshot)
        #expect(await loader.executionCount == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 3)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 1)
        #expect(metrics[.gptkGPUIdentityCacheHits] == 1)
    }

    @Test("rejects a helper result carrying a different cache key")
    func rejectsMismatchedReturnedKey() async throws {
        let requestedKey = try makeGPUIdentityCacheKey(
            operatingSystemBuild: "24G90"
        )
        let returnedKey = try makeGPUIdentityCacheKey(
            operatingSystemBuild: "24G91"
        )
        let loader = GPUIdentityMismatchedLoader(returnedKey: returnedKey)
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(counters: counters) { key in
            try await loader.load(key)
        }

        for _ in 0..<2 {
            await #expect(
                throws: GPTKGPUIdentityCacheError.cacheKeyMismatch
            ) {
                try await cache.snapshot(for: requestedKey)
            }
        }

        #expect(await loader.executionCount == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 2)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 2)
        #expect(metrics[.gptkGPUIdentityCacheHits] == 0)
    }

    @Test(
        "does not cache a failed helper execution",
        .timeLimit(.minutes(1))
    )
    func retriesAfterFailure() async throws {
        let key = try makeGPUIdentityCacheKey()
        let loader = ControlledGPUIdentityLoader()
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(counters: counters) { key in
            try await loader.load(key)
        }

        let failed = Task {
            try await cache.snapshot(for: key)
        }
        await loader.waitForExecutionCount(1)
        await loader.fail(0)
        await #expect(throws: GPUIdentityCacheTestError.loaderFailed) {
            try await failed.value
        }

        let recovered = Task {
            try await cache.snapshot(for: key)
        }
        await loader.waitForExecutionCount(2)
        try await loader.succeed(1, description: "Recovered")
        let recoveredSnapshot = try await recovered.value
        let cachedSnapshot = try await cache.snapshot(for: key)

        #expect(recoveredSnapshot == cachedSnapshot)
        #expect(await loader.executionCount == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 3)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 2)
        #expect(metrics[.gptkGPUIdentityCacheHits] == 1)
    }

    @Test(
        "invalidation prevents a late task from repopulating the cache",
        .timeLimit(.minutes(1))
    )
    func invalidationRejectsLateCompletion() async throws {
        let key = try makeGPUIdentityCacheKey()
        let loader = ControlledGPUIdentityLoader()
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(counters: counters) { key in
            try await loader.load(key)
        }

        let staleRequest = Task {
            try await cache.snapshot(for: key)
        }
        await loader.waitForExecutionCount(1)
        await cache.invalidate(key)

        let freshRequest = Task {
            try await cache.snapshot(for: key)
        }
        await loader.waitForExecutionCount(2)
        try await loader.succeed(1, description: "Fresh")
        let freshSnapshot = try await freshRequest.value

        try await loader.succeed(0, description: "Stale")
        let staleSnapshot = try await staleRequest.value
        let cachedSnapshot = try await cache.snapshot(for: key)

        #expect(staleSnapshot.identity.description == "Stale")
        #expect(freshSnapshot.identity.description == "Fresh")
        #expect(cachedSnapshot == freshSnapshot)
        #expect(await loader.executionCount == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 3)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 2)
        #expect(metrics[.gptkGPUIdentityCacheHits] == 1)
    }

    @Test("evicts the least recently used entry at the count limit")
    func boundedLRUEviction() async throws {
        let firstKey = try makeGPUIdentityCacheKey(
            operatingSystemBuild: "24G90"
        )
        let secondKey = try makeGPUIdentityCacheKey(
            operatingSystemBuild: "24G91"
        )
        let thirdKey = try makeGPUIdentityCacheKey(
            operatingSystemBuild: "24G92"
        )
        let loader = GPUIdentityImmediateLoader()
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(
            maximumEntryCount: 2,
            counters: counters
        ) { key in
            try await loader.load(key)
        }

        _ = try await cache.snapshot(for: firstKey)
        _ = try await cache.snapshot(for: secondKey)
        _ = try await cache.snapshot(for: firstKey)
        _ = try await cache.snapshot(for: thirdKey)
        _ = try await cache.snapshot(for: firstKey)
        _ = try await cache.snapshot(for: secondKey)

        #expect(await loader.executionCount == 4)
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 6)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 4)
        #expect(metrics[.gptkGPUIdentityCacheHits] == 2)
    }

    @Test("isolates every helper identity dependency")
    func isolatesIdentityDependencies() async throws {
        let changedKeys = [
            try makeGPUIdentityCacheKey(operatingSystemBuild: "24G91"),
            try makeGPUIdentityCacheKey(defaultGPURegistryID: 0x200),
            try makeGPUIdentityCacheKey(runtimeRoot: "/private/runtime-b"),
            try makeGPUIdentityCacheKey(
                runtimeContentFingerprint: "runtime-fingerprint-b"
            ),
            try makeGPUIdentityCacheKey(
                helperPath: "/private/runtime/libexec/gpu-helper-b"
            ),
            try makeGPUIdentityCacheKey(helperHash: "c"),
            try makeGPUIdentityCacheKey(
                policyPath: "/private/runtime/share/gpu-policy-b.json"
            ),
            try makeGPUIdentityCacheKey(policyHash: "d"),
        ]
        let baseKey = try makeGPUIdentityCacheKey()
        let loader = GPUIdentityImmediateLoader()
        let counters = PerformanceCounters()
        let cache = GPTKGPUIdentityCache(counters: counters) { key in
            try await loader.load(key)
        }

        _ = try await cache.snapshot(for: baseKey)
        for changedKey in changedKeys {
            _ = try await cache.snapshot(for: changedKey)
            #expect(changedKey != baseKey)
        }

        #expect(await loader.executionCount == 1 + changedKeys.count)
        let metrics = counters.snapshot()
        #expect(
            metrics[.gptkGPUIdentityHelperExecutions]
                == UInt64(1 + changedKeys.count)
        )
        #expect(metrics[.gptkGPUIdentityCacheHits] == 0)
    }
}

private enum GPUIdentityCacheTestError: Error, Equatable {
    case loaderFailed
}

private actor GPUIdentityImmediateLoader {
    private(set) var executionCount = 0

    func load(
        _ key: GPTKGPUIdentityCacheKey
    ) throws -> GPTKGPUIdentitySnapshot {
        executionCount += 1
        return try makeGPUIdentitySnapshot(
            key: key,
            description: "Execution \(executionCount)"
        )
    }
}

private actor GPUIdentityMismatchedLoader {
    private let returnedKey: GPTKGPUIdentityCacheKey
    private(set) var executionCount = 0

    init(returnedKey: GPTKGPUIdentityCacheKey) {
        self.returnedKey = returnedKey
    }

    func load(
        _ requestedKey: GPTKGPUIdentityCacheKey
    ) throws -> GPTKGPUIdentitySnapshot {
        _ = requestedKey
        executionCount += 1
        return try makeGPUIdentitySnapshot(
            key: returnedKey,
            description: "Mismatched \(executionCount)"
        )
    }
}

private actor ControlledGPUIdentityLoader {
    private struct Pending {
        let key: GPTKGPUIdentityCacheKey
        let continuation: CheckedContinuation<
            GPTKGPUIdentitySnapshot,
            any Error
        >
    }

    private var pending: [Int: Pending] = [:]
    private(set) var executionCount = 0

    func load(
        _ key: GPTKGPUIdentityCacheKey
    ) async throws -> GPTKGPUIdentitySnapshot {
        let index = executionCount
        executionCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = Pending(
                key: key,
                continuation: continuation
            )
        }
    }

    func waitForExecutionCount(_ expectedCount: Int) async {
        while executionCount < expectedCount {
            await Task.yield()
        }
    }

    func succeed(
        _ index: Int,
        description: String
    ) throws {
        guard let pending = pending.removeValue(forKey: index) else {
            preconditionFailure("No pending GPU identity load at index \(index).")
        }
        pending.continuation.resume(
            returning: try makeGPUIdentitySnapshot(
                key: pending.key,
                description: description
            )
        )
    }

    func fail(_ index: Int) {
        guard let pending = pending.removeValue(forKey: index) else {
            preconditionFailure("No pending GPU identity load at index \(index).")
        }
        pending.continuation.resume(
            throwing: GPUIdentityCacheTestError.loaderFailed
        )
    }
}

private func waitForGPUIdentityCondition(
    _ condition: @escaping @Sendable () -> Bool
) async {
    while !condition() {
        await Task.yield()
    }
}

private func makeGPUIdentitySnapshot(
    key: GPTKGPUIdentityCacheKey,
    description: String
) throws -> GPTKGPUIdentitySnapshot {
    GPTKGPUIdentitySnapshot(
        cacheKey: key,
        identity: try HostGPUIdentity(
            vendorID: 0x106B,
            deviceID: 1,
            subsystemID: 0,
            revisionID: 0,
            description: description
        )
    )
}

private func makeGPUIdentityCacheKey(
    operatingSystemBuild: String = "24G90",
    defaultGPURegistryID: UInt64 = 0x100,
    runtimeRoot: String = "/private/runtime",
    runtimeContentFingerprint: String = "runtime-fingerprint-a",
    helperPath: String = "/private/runtime/libexec/gpu-helper",
    helperHash: String = "a",
    policyPath: String = "/private/runtime/share/gpu-policy.json",
    policyHash: String = "b"
) throws -> GPTKGPUIdentityCacheKey {
    let helper = try RuntimeGPUIdentityFileEvidence(
        canonicalPath: helperPath,
        device: 1,
        inode: 2,
        size: 4_096,
        modificationTimeNanoseconds: 1_000,
        mode: 0o100755,
        sha256: String(repeating: helperHash, count: 64)
    )
    let policy = try RuntimeGPUIdentityFileEvidence(
        canonicalPath: policyPath,
        device: 1,
        inode: 3,
        size: 1_024,
        modificationTimeNanoseconds: 2_000,
        mode: 0o100644,
        sha256: String(repeating: policyHash, count: 64)
    )
    let runtime = try RuntimeGPUIdentityEvidence(
        runtimeID: "switchyard-runtime-0.4.2",
        runtimeRoot: runtimeRoot,
        runtimeContentFingerprint: runtimeContentFingerprint,
        helper: helper,
        policy: policy
    )
    return try GPTKGPUIdentityCacheKey(
        operatingSystemBuild: operatingSystemBuild,
        defaultGPURegistryID: defaultGPURegistryID,
        runtime: runtime
    )
}
