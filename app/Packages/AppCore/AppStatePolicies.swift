import Foundation

public enum RunCompletionPolicy {
    public static func normalizedOutcome(
        _ outcome: OperationState,
        stoppedByUser: Bool
    ) -> OperationState {
        stoppedByUser ? .cancelled : outcome
    }

    public static func containerStatus(for outcome: OperationState) -> ContainerStatus {
        switch outcome {
        case .succeeded:
            .succeeded
        case .cancelled:
            .ready
        case .queued, .running, .failed:
            .failed
        }
    }
}

public enum LogClearPolicy {
    public static func clearing(
        _ logs: [LogLine],
        for containerID: UUID? = nil
    ) -> [LogLine] {
        guard let containerID else { return [] }
        return logs.filter { $0.containerID != containerID }
    }
}

public enum WineDebugLoggingProfile: String, Sendable {
    case standard
    case verbose

    public var environmentValue: String {
        switch self {
        case .standard:
            "-all,+timestamp,err+all,warn+all"
        case .verbose:
            "-all,+timestamp,err+all,warn+all,fixme+all,trace+seh,trace+dcomp,trace+macdrv,trace+dxgi,trace+wined3d"
        }
    }
}

public struct DebugRunLogRetentionPolicy: Equatable, Sendable {
    public static let defaultRetentionDays = 14
    public static let defaultMaximumFileCount = 50
    public static let supportedRetentionDays = [1, 7, 14, 30]
    public static let supportedMaximumFileCounts = [10, 25, 50, 100]

    public var retentionDays: Int
    public var maximumFileCount: Int

    public init(
        retentionDays: Int = Self.defaultRetentionDays,
        maximumFileCount: Int = Self.defaultMaximumFileCount
    ) {
        self.retentionDays = Self.supportedRetentionDays.contains(retentionDays)
            ? retentionDays
            : Self.defaultRetentionDays
        self.maximumFileCount = Self.supportedMaximumFileCounts.contains(maximumFileCount)
            ? maximumFileCount
            : Self.defaultMaximumFileCount
    }
}

public enum ProcessLogLevelPolicy {
    public static func normalizedLevel(
        for message: String,
        fallbackLevel: String
    ) -> String {
        if message.contains(":err:") {
            return "error"
        }
        if message.contains(":warn:") || message.contains(":fixme:") {
            return "warning"
        }
        if message.contains(":trace:") {
            return "debug"
        }
        return fallbackLevel
    }
}

public struct LiveLogEventKey: Hashable, Sendable {
    fileprivate var containerID: UUID?
    fileprivate var level: String
    fileprivate var source: String
    fileprivate var normalizedMessage: String
}

public enum LiveLogJournalFormat {
    public static let resetGenerationSuffix = ".generation"
    public static let resetGenerationByteCount = 16

    public static func makeResetGeneration() -> Data {
        var bytes = UUID().uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }
}

public enum LiveLogPolicy {
    private static let coalescingInterval: TimeInterval = 1
    private static let maximumExistingCoalescingCandidates = 256
    private static let wineLevelMarkers = [
        ":err:",
        ":warn:",
        ":fixme:",
        ":trace:",
    ]

    private struct Aggregate {
        var line: LogLine
        var lastPosition: Int
    }

    public static func eventKey(
        containerID: UUID?,
        level: String,
        source: String,
        message: String
    ) -> LiveLogEventKey {
        LiveLogEventKey(
            containerID: containerID,
            level: level,
            source: source,
            normalizedMessage: normalizedMessage(message)
        )
    }

    public static func eventKey(for line: LogLine) -> LiveLogEventKey {
        eventKey(
            containerID: line.containerID,
            level: line.level,
            source: line.source,
            message: line.message
        )
    }

    public static func compacting(chronological lines: [LogLine]) -> [LogLine] {
        guard lines.count > 1 else { return lines }

        var aggregates: [Aggregate] = []
        aggregates.reserveCapacity(lines.count)
        var latestAggregateByKey: [LiveLogEventKey: Int] = [:]
        latestAggregateByKey.reserveCapacity(min(lines.count, 256))

        for (position, line) in lines.enumerated() {
            let key = eventKey(for: line)
            if let aggregateIndex = latestAggregateByKey[key],
               isWithinCoalescingInterval(
                   older: aggregates[aggregateIndex].line,
                   newer: line
               ) {
                let retainedID = aggregates[aggregateIndex].line.id
                let combinedCount = aggregates[aggregateIndex].line.effectiveOccurrenceCount
                    + line.effectiveOccurrenceCount
                var combined = line
                combined.id = retainedID
                combined.occurrenceCount = combinedCount
                aggregates[aggregateIndex] = Aggregate(
                    line: combined,
                    lastPosition: position
                )
            } else {
                latestAggregateByKey[key] = aggregates.count
                aggregates.append(Aggregate(line: line, lastPosition: position))
            }
        }

        return aggregates
            .sorted { $0.lastPosition < $1.lastPosition }
            .map(\.line)
    }

    public static func merging(
        chronological incoming: [LogLine],
        before existing: [LogLine],
        limit: Int
    ) -> [LogLine] {
        guard limit > 0, !incoming.isEmpty else {
            return limit > 0 ? Array(existing.prefix(limit)) : []
        }

        let existingCandidateCount = min(
            existing.count,
            maximumExistingCoalescingCandidates
        )
        var chronologicalCandidates = Array(
            existing.prefix(existingCandidateCount).reversed()
        )
        chronologicalCandidates.append(contentsOf: incoming)

        let compacted = compacting(chronological: chronologicalCandidates)
        var merged = Array(compacted.reversed())
        if existingCandidateCount < existing.count {
            merged.append(contentsOf: existing.dropFirst(existingCandidateCount))
        }
        return Array(merged.prefix(limit))
    }

    private static func isWithinCoalescingInterval(
        older: LogLine,
        newer: LogLine
    ) -> Bool {
        let interval = newer.timestamp.timeIntervalSince(older.timestamp)
        return interval >= 0
            && interval <= coalescingInterval
    }

    private static func normalizedMessage(_ message: String) -> String {
        var earliestMarkerRange: Range<String.Index>?
        for marker in wineLevelMarkers {
            guard let range = message.range(of: marker) else { continue }
            if earliestMarkerRange == nil
                || range.lowerBound < earliestMarkerRange!.lowerBound {
                earliestMarkerRange = range
            }
        }
        guard let earliestMarkerRange else { return message }
        return String(message[earliestMarkerRange.lowerBound...])
    }
}

public enum LogFilterPolicy {
    public static func filtering(
        _ logs: [LogLine],
        containerID: UUID? = nil,
        level: String? = nil,
        searchText: String = ""
    ) -> [LogLine] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasQuery = !query.isEmpty

        return logs.filter { line in
            if let containerID, line.containerID != containerID {
                return false
            }
            if let level, line.level != level {
                return false
            }
            guard hasQuery else { return true }
            return line.message.localizedCaseInsensitiveContains(query)
                || line.source.localizedCaseInsensitiveContains(query)
        }
    }
}
