import Darwin
import Foundation
import Testing
@testable import Switchyard

@Test func wineSessionResourceMetricsAggregateAvailableProcesses() {
    let samples: [pid_t: WineSessionResourceMetricsService.ProcessSample] = [
        101: .init(
            physicalFootprintBytes: 192,
            residentMemoryBytes: 128,
            virtualMemoryBytes: 1_024,
            threadCount: 3
        ),
        303: .init(
            physicalFootprintBytes: 320,
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

    #expect(snapshot.physicalFootprintBytes == 512)
    #expect(snapshot.residentMemoryBytes == 384)
    #expect(snapshot.virtualMemoryBytes == 3_072)
    #expect(snapshot.threadCount == 8)
    #expect(snapshot.sampledProcessCount == 2)
    #expect(snapshot.footprintSampledProcessCount == 2)
    #expect(snapshot.sampledAt == sampledAt)
    #expect(!snapshot.isEmpty)
    #expect(snapshot.hasCompletePhysicalFootprint)
}

@Test func wineSessionResourceMetricsSkipInvalidAndUnavailableProcesses() {
    let sampledAt = Date(timeIntervalSince1970: 84)
    let service = WineSessionResourceMetricsService(
        processSampler: { _ in nil },
        now: { sampledAt }
    )

    let snapshot = service.sample(processIDs: [-1, 0, 404])

    #expect(snapshot.physicalFootprintBytes == nil)
    #expect(snapshot.residentMemoryBytes == 0)
    #expect(snapshot.virtualMemoryBytes == 0)
    #expect(snapshot.threadCount == 0)
    #expect(snapshot.sampledProcessCount == 0)
    #expect(snapshot.footprintSampledProcessCount == 0)
    #expect(snapshot.sampledAt == sampledAt)
    #expect(snapshot.isEmpty)
    #expect(!snapshot.hasCompletePhysicalFootprint)
}

@Test func wineSessionResourceMetricsSaturateOverflowingTotals() {
    let samples: [pid_t: WineSessionResourceMetricsService.ProcessSample] = [
        1: .init(
            physicalFootprintBytes: .max,
            residentMemoryBytes: .max,
            virtualMemoryBytes: .max,
            threadCount: .max
        ),
        2: .init(
            physicalFootprintBytes: 1,
            residentMemoryBytes: 1,
            virtualMemoryBytes: 1,
            threadCount: 1
        ),
    ]
    let service = WineSessionResourceMetricsService(
        processSampler: { samples[$0] }
    )

    let snapshot = service.sample(processIDs: [1, 2])

    #expect(snapshot.physicalFootprintBytes == .max)
    #expect(snapshot.residentMemoryBytes == .max)
    #expect(snapshot.virtualMemoryBytes == .max)
    #expect(snapshot.threadCount == .max)
    #expect(snapshot.sampledProcessCount == 2)
    #expect(snapshot.footprintSampledProcessCount == 2)
    #expect(snapshot.hasCompletePhysicalFootprint)
}

@Test func wineSessionResourceMetricsDoNotPresentPartialFootprintAsTotal() {
    let samples: [pid_t: WineSessionResourceMetricsService.ProcessSample] = [
        10: .init(
            physicalFootprintBytes: 300,
            residentMemoryBytes: 200,
            virtualMemoryBytes: 2_000,
            threadCount: 2
        ),
        20: .init(
            physicalFootprintBytes: nil,
            residentMemoryBytes: 400,
            virtualMemoryBytes: 4_000,
            threadCount: 4
        ),
    ]
    let service = WineSessionResourceMetricsService(
        processSampler: { samples[$0] }
    )

    let snapshot = service.sample(processIDs: [10, 20])

    #expect(snapshot.physicalFootprintBytes == nil)
    #expect(snapshot.residentMemoryBytes == 600)
    #expect(snapshot.sampledProcessCount == 2)
    #expect(snapshot.footprintSampledProcessCount == 1)
    #expect(!snapshot.hasCompletePhysicalFootprint)
}

@Test func wineSessionResourceMetricsSampleCurrentProcessWithSystemAPIs() {
    let snapshot = WineSessionResourceMetricsService().sample(
        processIDs: [getpid()]
    )

    #expect(snapshot.sampledProcessCount == 1)
    #expect(snapshot.residentMemoryBytes > 0)
    #expect(snapshot.virtualMemoryBytes > 0)
    #expect(snapshot.threadCount > 0)
    #expect(snapshot.physicalFootprintBytes.map { $0 > 0 } == true)
    #expect(snapshot.hasCompletePhysicalFootprint)
}
