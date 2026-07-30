import Foundation
import Testing
@testable import AppCore

@Suite("Performance Counters")
struct PerformanceCountersTests {
    @Test("increments and snapshots stable metric names")
    func snapshotsStableMetricNames() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_234)
        let counters = PerformanceCounters(now: { capturedAt })

        counters.increment(.sessionInspectionRequests)
        counters.increment(.sessionInspectionRequests, by: 2)
        counters.increment(.windowCaptureEvictedBytes, by: 4_096)
        counters.increment(.containerIndexScans, by: 0)

        let snapshot = counters.snapshot()
        let expectedMetricNames: Set<String> = [
            "session_inspection.requests",
            "session_inspection.executions",
            "session_inspection.cache_hits",
            "session_inspection.coalesced_requests",
            "window_observation.requests",
            "window_observation.content_enumerations",
            "window_observation.capture_executions",
            "window_observation.capture_cache_hits",
            "window_observation.coalesced_requests",
            "window_observation.evicted_bytes",
            "bridge.protocol_refreshes",
            "bridge.shortcut_refreshes",
            "bridge.safety_resyncs",
            "bridge.digest_cache_hits",
            "container_index.requests",
            "container_index.scans",
            "container_index.cache_hits",
            "container_index.coalesced_requests",
            "container_index.storage_scans",
            "partial_log.truncations",
            "partial_log.discarded_bytes",
            "gptk_gpu_identity.requests",
            "gptk_gpu_identity.helper_executions",
            "gptk_gpu_identity.cache_hits",
        ]

        #expect(snapshot.capturedAt == capturedAt)
        #expect(snapshot[.sessionInspectionRequests] == 3)
        #expect(snapshot[.windowCaptureEvictedBytes] == 4_096)
        #expect(snapshot[.containerIndexScans] == 0)
        #expect(snapshot.values["session_inspection.requests"] == 3)
        #expect(snapshot.values.count == PerformanceCounter.allCases.count)
        #expect(snapshot.values["container_index.scans"] == 0)
        #expect(Set(PerformanceCounter.allCases.map(\.rawValue)) == expectedMetricNames)
        #expect(Set(snapshot.values.keys) == expectedMetricNames)

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            PerformanceCounterSnapshot.self,
            from: encoded
        )
        #expect(decoded == snapshot)
    }

    @Test("concurrent increments are not lost")
    func concurrentIncrementsAreNotLost() async {
        let counters = PerformanceCounters()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    for _ in 0..<1_000 {
                        counters.increment(.windowObservationRequests)
                    }
                }
            }
        }

        #expect(counters.snapshot()[.windowObservationRequests] == 64_000)
    }

    @Test("reset returns the previous values and starts a new interval")
    func resetStartsNewInterval() {
        let resetAt = Date(timeIntervalSince1970: 5_678)
        let counters = PerformanceCounters(now: { resetAt })

        counters.increment(.gptkGPUIdentityRequests, by: 7)
        let previous = counters.reset()

        #expect(previous.capturedAt == resetAt)
        #expect(previous[.gptkGPUIdentityRequests] == 7)
        #expect(counters.snapshot()[.gptkGPUIdentityRequests] == 0)
    }

    @Test("counters saturate instead of wrapping")
    func incrementsSaturate() {
        let counters = PerformanceCounters()

        counters.increment(.partialLogDiscardedBytes, by: .max - 2)
        counters.increment(.partialLogDiscardedBytes, by: 3)

        #expect(counters.snapshot()[.partialLogDiscardedBytes] == .max)

        counters.reset()
        counters.increment(.partialLogDiscardedBytes, by: 2)
        #expect(counters.snapshot()[.partialLogDiscardedBytes] == 2)
    }
}
