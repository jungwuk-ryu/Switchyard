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
