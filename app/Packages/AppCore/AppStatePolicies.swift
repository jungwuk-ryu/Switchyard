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

public enum LiveLogPolicy {
    public static func merging(
        chronological incoming: [LogLine],
        before existing: [LogLine],
        limit: Int
    ) -> [LogLine] {
        guard limit > 0, !incoming.isEmpty else {
            return limit > 0 ? Array(existing.prefix(limit)) : []
        }

        let retainedIncoming = incoming.suffix(limit)
        let existingLimit = limit - retainedIncoming.count
        var merged: [LogLine] = []
        merged.reserveCapacity(min(limit, retainedIncoming.count + existing.count))
        merged.append(contentsOf: retainedIncoming.reversed())
        if existingLimit > 0 {
            merged.append(contentsOf: existing.prefix(existingLimit))
        }
        return merged
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
