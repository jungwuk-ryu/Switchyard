import AppCore
import Foundation
import Testing
@testable import Switchyard

@Test func processLogBatcherCoalescesAndFlushesChronologicalLines() {
    let collector = LogBatchCollector()
    let containerID = UUID()
    let batcher = ProcessLogBatcher(
        containerID: containerID,
        source: "Battle.net",
        flushInterval: 60,
        onLogs: collector.append
    )
    let logs = (0..<100).map { index in
        LogLine(
            containerID: containerID,
            level: "debug",
            source: "Battle.net",
            message: "line-\(index)"
        )
    }

    batcher.append(Array(logs.prefix(40)))
    batcher.append(Array(logs.dropFirst(40)))
    batcher.finish()

    #expect(collector.batches.count == 1)
    #expect(collector.batches[0].map(\.message) == logs.map(\.message))
}

@Test func processLogBatcherBoundsPendingOutputAndReportsOmissions() {
    let collector = LogBatchCollector()
    let batcher = ProcessLogBatcher(
        containerID: UUID(),
        source: "Battle.net",
        flushInterval: 60,
        maximumPendingLineCount: 3,
        onLogs: collector.append
    )
    let logs = (0..<5).map { index in
        LogLine(level: "debug", source: "Battle.net", message: "line-\(index)")
    }

    batcher.append(logs)
    batcher.finish()

    #expect(collector.batches.count == 1)
    #expect(collector.batches[0].prefix(3).map(\.message) == ["line-2", "line-3", "line-4"])
    #expect(collector.batches[0].last?.level == "warning")
    #expect(collector.batches[0].last?.message.hasPrefix("2 high-volume") == true)
}

private final class LogBatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[LogLine]] = []

    var batches: [[LogLine]] {
        lock.withLock { storage }
    }

    func append(_ logs: [LogLine]) {
        lock.withLock {
            storage.append(logs)
        }
    }
}
