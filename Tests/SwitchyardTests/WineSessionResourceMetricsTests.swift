import Darwin
import Foundation
import Testing
@testable import Switchyard

@Test func wineSessionResourceMetricsAggregateAvailableProcesses() {
    let samples: [pid_t: WineSessionResourceMetricsService.ProcessSample] = [
        101: .init(
            residentMemoryBytes: 128,
            virtualMemoryBytes: 1_024,
            threadCount: 3
        ),
        303: .init(
            residentMemoryBytes: 256,
            virtualMemoryBytes: 2_048,
            threadCount: 5
        ),
    ]
    let sampledAt = Date(timeIntervalSince1970: 42)
    let service = WineSessionResourceMetricsService(
        processSampler: { samples[$0] },
        now: { sampledAt }
    )

    let snapshot = service.sample(processIDs: [101, 202, 303])

    #expect(snapshot.residentMemoryBytes == 384)
    #expect(snapshot.virtualMemoryBytes == 3_072)
    #expect(snapshot.threadCount == 8)
    #expect(snapshot.sampledProcessCount == 2)
    #expect(snapshot.sampledAt == sampledAt)
    #expect(!snapshot.isEmpty)
}

@Test func wineSessionResourceMetricsSkipInvalidAndUnavailableProcesses() {
    let sampledAt = Date(timeIntervalSince1970: 84)
    let service = WineSessionResourceMetricsService(
        processSampler: { _ in nil },
        now: { sampledAt }
    )

    let snapshot = service.sample(processIDs: [-1, 0, 404])

    #expect(snapshot.residentMemoryBytes == 0)
    #expect(snapshot.virtualMemoryBytes == 0)
    #expect(snapshot.threadCount == 0)
    #expect(snapshot.sampledProcessCount == 0)
    #expect(snapshot.sampledAt == sampledAt)
    #expect(snapshot.isEmpty)
}

@Test func wineSessionResourceMetricsSaturateOverflowingTotals() {
    let samples: [pid_t: WineSessionResourceMetricsService.ProcessSample] = [
        1: .init(
            residentMemoryBytes: .max,
            virtualMemoryBytes: .max,
            threadCount: .max
        ),
        2: .init(
            residentMemoryBytes: 1,
            virtualMemoryBytes: 1,
            threadCount: 1
        ),
    ]
    let service = WineSessionResourceMetricsService(
        processSampler: { samples[$0] }
    )

    let snapshot = service.sample(processIDs: [1, 2])

    #expect(snapshot.residentMemoryBytes == .max)
    #expect(snapshot.virtualMemoryBytes == .max)
    #expect(snapshot.threadCount == .max)
    #expect(snapshot.sampledProcessCount == 2)
}
