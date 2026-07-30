import Foundation

public enum PerformanceCounter: String, CaseIterable, Codable, Sendable {
    case sessionInspectionRequests = "session_inspection.requests"
    case sessionInspectionExecutions = "session_inspection.executions"
    case sessionInspectionCacheHits = "session_inspection.cache_hits"
    case sessionInspectionCoalescedRequests = "session_inspection.coalesced_requests"

    case windowObservationRequests = "window_observation.requests"
    case windowContentEnumerations = "window_observation.content_enumerations"
    case windowCaptureExecutions = "window_observation.capture_executions"
    case windowCaptureCacheHits = "window_observation.capture_cache_hits"
    case windowCaptureCoalescedRequests = "window_observation.coalesced_requests"
    case windowCaptureEvictedBytes = "window_observation.evicted_bytes"

    case protocolBridgeRefreshes = "bridge.protocol_refreshes"
    case shortcutBridgeRefreshes = "bridge.shortcut_refreshes"
    case bridgeSafetyResyncs = "bridge.safety_resyncs"
    case bridgeDigestCacheHits = "bridge.digest_cache_hits"

    case containerIndexRequests = "container_index.requests"
    case containerIndexScans = "container_index.scans"
    case containerIndexCacheHits = "container_index.cache_hits"
    case containerIndexCoalescedRequests = "container_index.coalesced_requests"
    case containerStorageScans = "container_index.storage_scans"

    case partialLogTruncations = "partial_log.truncations"
    case partialLogDiscardedBytes = "partial_log.discarded_bytes"

    case gptkGPUIdentityRequests = "gptk_gpu_identity.requests"
    case gptkGPUIdentityHelperExecutions = "gptk_gpu_identity.helper_executions"
    case gptkGPUIdentityCacheHits = "gptk_gpu_identity.cache_hits"
}

public struct PerformanceCounterSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let values: [String: UInt64]

    public init(capturedAt: Date, values: [String: UInt64]) {
        self.capturedAt = capturedAt
        self.values = values
    }

    public subscript(_ counter: PerformanceCounter) -> UInt64 {
        values[counter.rawValue, default: 0]
    }
}

public final class PerformanceCounters: @unchecked Sendable {
    public static let shared = PerformanceCounters()

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var values: [PerformanceCounter: UInt64] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func increment(
        _ counter: PerformanceCounter,
        by amount: UInt64 = 1
    ) {
        guard amount > 0 else { return }

        lock.withLock {
            let current = values[counter, default: 0]
            let (updated, overflowed) = current.addingReportingOverflow(amount)
            values[counter] = overflowed ? .max : updated
        }
    }

    public func snapshot() -> PerformanceCounterSnapshot {
        lock.withLock {
            PerformanceCounterSnapshot(
                capturedAt: now(),
                values: snapshotValues()
            )
        }
    }

    @discardableResult
    public func reset() -> PerformanceCounterSnapshot {
        lock.withLock {
            let snapshot = PerformanceCounterSnapshot(
                capturedAt: now(),
                values: snapshotValues()
            )
            values.removeAll(keepingCapacity: true)
            return snapshot
        }
    }

    private func snapshotValues() -> [String: UInt64] {
        Dictionary(
            uniqueKeysWithValues: PerformanceCounter.allCases.map { counter in
                (counter.rawValue, values[counter, default: 0])
            }
        )
    }
}
