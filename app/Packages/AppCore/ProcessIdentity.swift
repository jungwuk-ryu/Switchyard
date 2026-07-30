public struct ProcessInstanceIdentity<
    ProcessID: Hashable & Sendable,
    StartIdentity: Hashable & Sendable
>: Hashable, Sendable {
    public let processID: ProcessID
    public let startIdentity: StartIdentity
    public let executableIdentity: String?

    public init(
        processID: ProcessID,
        startIdentity: StartIdentity,
        executableIdentity: String? = nil
    ) {
        self.processID = processID
        self.startIdentity = startIdentity
        self.executableIdentity = executableIdentity
    }

    public func identifiesSameProcess(
        as current: ProcessInstanceIdentity<ProcessID, StartIdentity>
    ) -> Bool {
        guard processID == current.processID,
              startIdentity == current.startIdentity else {
            return false
        }

        switch executableIdentity {
        case let selected?:
            return current.executableIdentity == selected
        case nil:
            return true
        }
    }
}

public enum ProcessTableSnapshot<Element: Sendable>: Sendable {
    case complete([Element])
    case incomplete([Element])
    case failed

    public func requireComplete() throws -> [Element] {
        switch self {
        case let .complete(elements):
            elements
        case .incomplete:
            throw ProcessTableSnapshotError.incomplete
        case .failed:
            throw ProcessTableSnapshotError.failed
        }
    }
}

public enum ProcessTableSnapshotError: Error, Equatable, Sendable {
    case incomplete
    case failed
}

public enum ProcessIdentitySignalGate {
    @discardableResult
    public static func signal<ProcessID, StartIdentity>(
        selected: ProcessInstanceIdentity<ProcessID, StartIdentity>,
        signal: Int32,
        currentIdentity: () -> ProcessInstanceIdentity<ProcessID, StartIdentity>?,
        send: (ProcessID, Int32) -> Int32
    ) -> Bool where ProcessID: Hashable & Sendable, StartIdentity: Hashable & Sendable {
        guard let current = currentIdentity(),
              selected.identifiesSameProcess(as: current) else {
            return false
        }
        return send(selected.processID, signal) == 0
    }
}
