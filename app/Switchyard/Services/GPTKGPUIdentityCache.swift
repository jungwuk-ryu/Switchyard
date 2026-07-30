import AppCore
import Foundation

enum GPTKGPUIdentityCacheError: Error, Equatable, Sendable {
    case cacheKeyMismatch
}

private final class GPTKGPUIdentityTaskWaiter<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completion: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func value(
        of task: Task<Value, any Error>
    ) async throws -> Value {
        Task.detached { [self] in
            complete(with: await task.result)
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            self.complete(with: .failure(CancellationError()))
        }
    }

    private func register(
        _ newContinuation: CheckedContinuation<Value, any Error>
    ) {
        let completedResult: Result<Value, any Error>? = lock.withLock {
            if let completion {
                return completion
            }
            continuation = newContinuation
            return nil
        }
        if let completedResult {
            newContinuation.resume(with: completedResult)
        }
    }

    private func complete(
        with result: Result<Value, any Error>
    ) {
        let pendingContinuation: CheckedContinuation<Value, any Error>? =
            lock.withLock {
                guard completion == nil else { return nil }
                completion = result
                defer { continuation = nil }
                return continuation
            }
        pendingContinuation?.resume(with: result)
    }
}

actor GPTKGPUIdentityCache {
    typealias Loader = @Sendable (
        GPTKGPUIdentityCacheKey
    ) async throws -> GPTKGPUIdentitySnapshot

    private struct CacheEntry: Sendable {
        let snapshot: GPTKGPUIdentitySnapshot
        var lastAccess: UInt64
    }

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<GPTKGPUIdentitySnapshot, any Error>
    }

    private let maximumEntryCount: Int
    private let counters: PerformanceCounters
    private let loader: Loader

    private var cache: [GPTKGPUIdentityCacheKey: CacheEntry] = [:]
    private var inFlight: [GPTKGPUIdentityCacheKey: InFlight] = [:]
    private var accessSequence: UInt64 = 0

    init(
        maximumEntryCount: Int = 8,
        counters: PerformanceCounters = .shared,
        loader: @escaping Loader
    ) {
        precondition(
            maximumEntryCount >= 0,
            "GPU identity cache entry limit must not be negative."
        )
        self.maximumEntryCount = maximumEntryCount
        self.counters = counters
        self.loader = loader
    }

    func snapshot(
        for key: GPTKGPUIdentityCacheKey
    ) async throws -> GPTKGPUIdentitySnapshot {
        counters.increment(.gptkGPUIdentityRequests)
        try Task.checkCancellation()

        if let cached = cachedSnapshot(for: key) {
            counters.increment(.gptkGPUIdentityCacheHits)
            return cached
        }
        if let task = inFlight[key]?.task {
            return try await GPTKGPUIdentityTaskWaiter<
                GPTKGPUIdentitySnapshot
            >().value(of: task)
        }

        let id = UUID()
        let loader = self.loader
        counters.increment(.gptkGPUIdentityHelperExecutions)
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let snapshot = try await loader(key)
                guard snapshot.cacheKey == key else {
                    throw GPTKGPUIdentityCacheError.cacheKeyMismatch
                }
                await self?.complete(
                    .success(snapshot),
                    for: key,
                    id: id
                )
                return snapshot
            } catch {
                await self?.complete(
                    .failure(error),
                    for: key,
                    id: id
                )
                throw error
            }
        }
        inFlight[key] = InFlight(id: id, task: task)

        return try await GPTKGPUIdentityTaskWaiter<
            GPTKGPUIdentitySnapshot
        >().value(of: task)
    }

    func invalidate(_ key: GPTKGPUIdentityCacheKey) {
        cache.removeValue(forKey: key)
        inFlight.removeValue(forKey: key)
    }

    func invalidateAll() {
        cache.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        accessSequence = 0
    }

    private func complete(
        _ result: Result<GPTKGPUIdentitySnapshot, any Error>,
        for key: GPTKGPUIdentityCacheKey,
        id: UUID
    ) {
        guard inFlight[key]?.id == id else {
            return
        }
        inFlight.removeValue(forKey: key)

        guard case let .success(snapshot) = result,
              snapshot.cacheKey == key else {
            return
        }
        insert(snapshot, for: key)
    }

    private func cachedSnapshot(
        for key: GPTKGPUIdentityCacheKey
    ) -> GPTKGPUIdentitySnapshot? {
        guard var entry = cache[key] else {
            return nil
        }
        entry.lastAccess = nextAccessSequence()
        cache[key] = entry
        return entry.snapshot
    }

    private func insert(
        _ snapshot: GPTKGPUIdentitySnapshot,
        for key: GPTKGPUIdentityCacheKey
    ) {
        guard maximumEntryCount > 0 else {
            return
        }

        let lastAccess = nextAccessSequence()
        cache[key] = CacheEntry(
            snapshot: snapshot,
            lastAccess: lastAccess
        )
        while cache.count > maximumEntryCount,
              let leastRecentlyUsedKey = cache.min(
                by: { $0.value.lastAccess < $1.value.lastAccess }
              )?.key {
            cache.removeValue(forKey: leastRecentlyUsedKey)
        }
    }

    private func nextAccessSequence() -> UInt64 {
        if accessSequence == .max {
            let keysByRecency = cache
                .sorted { $0.value.lastAccess < $1.value.lastAccess }
                .map(\.key)
            accessSequence = 0
            for key in keysByRecency {
                accessSequence += 1
                cache[key]?.lastAccess = accessSequence
            }
        }
        accessSequence += 1
        return accessSequence
    }
}
