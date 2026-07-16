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
