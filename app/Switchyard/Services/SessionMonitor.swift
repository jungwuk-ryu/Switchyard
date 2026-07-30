import AppCore
import Foundation

protocol WineSessionInspecting: Sendable {
    func inspectSession(
        winePath: String,
        prefixPath: String
    ) async throws -> WinePrefixSessionInspection

    func runningWindowsProcessesAsync(
        winePath: String,
        prefixPath: String
    ) async throws -> [RunningWindowsProcess]
}

extension SwitchyardRunnerClient: WineSessionInspecting {}

struct SessionMonitorKey: Hashable, Sendable {
    let winePath: String
    let prefixPath: String
}

enum SessionMonitorDemand: Sendable {
    case summary
    case details
    case startup

    fileprivate var requestsProcessDetails: Bool {
        self == .details
    }
}

enum SessionProcessDetails: Equatable, Sendable {
    case notRequested
    case available([RunningWindowsProcess])
    case unavailable
}

struct SessionMonitorSnapshot: Equatable, Sendable {
    let inspection: WinePrefixSessionInspection?
    let processDetails: SessionProcessDetails
    let refreshedAt: Date
}

struct SessionMonitorConfiguration: Sendable {
    var inspectionTTL: TimeInterval = 0.75
    var processDetailsTTL: TimeInterval = 1.5
    var summaryActiveCadence: TimeInterval = 3
    var detailActiveCadence: TimeInterval = 2
    var inactiveCadence: TimeInterval = 8
    var startupCadence: TimeInterval = 0.25
}

protocol SessionMonitorClock: Sendable {
    func now() -> TimeInterval
    func sleep(for interval: TimeInterval) async throws
}

private struct SystemSessionMonitorClock: SessionMonitorClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, interval)))
    }
}

actor SessionMonitor {
    private enum InspectionOutcome: Equatable, Sendable {
        case available(WinePrefixSessionInspection)
        case unavailable

        var inspection: WinePrefixSessionInspection? {
            guard case let .available(inspection) = self else { return nil }
            return inspection
        }
    }

    private enum ProcessOutcome: Equatable, Sendable {
        case available([RunningWindowsProcess])
        case unavailable
    }

    private struct Cached<Value: Sendable>: Sendable {
        let value: Value
        let observedAt: TimeInterval
    }

    private struct InFlight<Value: Sendable>: Sendable {
        let id: UUID
        let task: Task<Value, Never>
    }

    private struct Subscriber {
        let demand: SessionMonitorDemand
        let continuation: AsyncStream<SessionMonitorSnapshot>.Continuation
    }

    private struct AggregateDemand: Equatable {
        var requestsProcessDetails: Bool
        var isStartingUp: Bool
    }

    private struct PollTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let inspector: any WineSessionInspecting
    private let configuration: SessionMonitorConfiguration
    private let counters: PerformanceCounters
    private let clock: any SessionMonitorClock
    private let wallNow: @Sendable () -> Date

    private var inspectionCache:
        [SessionMonitorKey: Cached<InspectionOutcome>] = [:]
    private var processCache:
        [SessionMonitorKey: Cached<ProcessOutcome>] = [:]
    private var inspectionTasks:
        [SessionMonitorKey: InFlight<InspectionOutcome>] = [:]
    private var processTasks:
        [SessionMonitorKey: InFlight<ProcessOutcome>] = [:]
    private var subscribers:
        [SessionMonitorKey: [UUID: Subscriber]] = [:]
    private var pollTasks: [SessionMonitorKey: PollTask] = [:]

    init(
        inspector: any WineSessionInspecting,
        configuration: SessionMonitorConfiguration = SessionMonitorConfiguration(),
        counters: PerformanceCounters = .shared,
        clock: any SessionMonitorClock = SystemSessionMonitorClock(),
        wallNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inspector = inspector
        self.configuration = configuration
        self.counters = counters
        self.clock = clock
        self.wallNow = wallNow
    }

    func snapshot(
        for key: SessionMonitorKey,
        demand: SessionMonitorDemand,
        force: Bool = false
    ) async -> SessionMonitorSnapshot {
        await makeSnapshot(
            for: key,
            requestsProcessDetails: demand.requestsProcessDetails,
            forceInspection: force,
            forceProcessDetails: force
        )
    }

    func updates(
        for key: SessionMonitorKey,
        demand: SessionMonitorDemand
    ) -> AsyncStream<SessionMonitorSnapshot> {
        let subscriberID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SessionMonitorSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID, for: key)
            }
        }

        let previousDemand = aggregateDemand(for: key)
        subscribers[key, default: [:]][subscriberID] = Subscriber(
            demand: demand,
            continuation: continuation
        )
        let updatedDemand = aggregateDemand(for: key)
        if pollTasks[key] == nil || previousDemand != updatedDemand {
            restartPolling(for: key)
        }
        return stream
    }

    func invalidate(_ key: SessionMonitorKey) {
        inspectionCache.removeValue(forKey: key)
        processCache.removeValue(forKey: key)
        inspectionTasks.removeValue(forKey: key)?.task.cancel()
        processTasks.removeValue(forKey: key)?.task.cancel()
        if subscribers[key]?.isEmpty == false {
            restartPolling(for: key)
        }
    }

    func invalidateAll() {
        let keys = Set(inspectionCache.keys)
            .union(processCache.keys)
            .union(inspectionTasks.keys)
            .union(processTasks.keys)
            .union(subscribers.keys)
        for key in keys {
            invalidate(key)
        }
    }

    func shutdown() {
        for pollTask in pollTasks.values {
            pollTask.task.cancel()
        }
        for task in inspectionTasks.values {
            task.task.cancel()
        }
        for task in processTasks.values {
            task.task.cancel()
        }
        for subscriberGroup in subscribers.values {
            for subscriber in subscriberGroup.values {
                subscriber.continuation.finish()
            }
        }
        pollTasks.removeAll()
        inspectionTasks.removeAll()
        processTasks.removeAll()
        subscribers.removeAll()
        inspectionCache.removeAll()
        processCache.removeAll()
    }

    func subscriberCount(for key: SessionMonitorKey) -> Int {
        subscribers[key]?.count ?? 0
    }

    func isPolling(_ key: SessionMonitorKey) -> Bool {
        pollTasks[key] != nil
    }

    private func makeSnapshot(
        for key: SessionMonitorKey,
        requestsProcessDetails: Bool,
        forceInspection: Bool,
        forceProcessDetails: Bool
    ) async -> SessionMonitorSnapshot {
        counters.increment(.sessionInspectionRequests)
        let inspection = await inspectionOutcome(
            for: key,
            force: forceInspection
        )

        let details: SessionProcessDetails
        switch inspection {
        case let .available(value) where
            value.state == .active && requestsProcessDetails:
            switch await processOutcome(
                for: key,
                force: forceProcessDetails
            ) {
            case let .available(processes):
                details = .available(processes)
            case .unavailable:
                details = .unavailable
            }
            if let latestInspection = inspectionCache[key]?.value,
               latestInspection != inspection {
                return makeSnapshot(
                    from: latestInspection,
                    refreshedAt: wallNow(),
                    requestsProcessDetails: requestsProcessDetails
                )
            }
        case .available:
            details = requestsProcessDetails ? .available([]) : .notRequested
        case .unavailable:
            details = .notRequested
        }

        return makeSnapshot(
            from: inspection,
            processDetails: details,
            refreshedAt: wallNow()
        )
    }

    private func makeSnapshot(
        from inspection: InspectionOutcome,
        refreshedAt: Date,
        requestsProcessDetails: Bool
    ) -> SessionMonitorSnapshot {
        let details: SessionProcessDetails
        switch inspection {
        case let .available(value) where value.state == .active:
            details = requestsProcessDetails ? .unavailable : .notRequested
        case .available:
            details = requestsProcessDetails ? .available([]) : .notRequested
        case .unavailable:
            details = .notRequested
        }
        return makeSnapshot(
            from: inspection,
            processDetails: details,
            refreshedAt: refreshedAt
        )
    }

    private func makeSnapshot(
        from inspection: InspectionOutcome,
        processDetails: SessionProcessDetails,
        refreshedAt: Date
    ) -> SessionMonitorSnapshot {
        return SessionMonitorSnapshot(
            inspection: inspection.inspection,
            processDetails: processDetails,
            refreshedAt: refreshedAt
        )
    }

    private func inspectionOutcome(
        for key: SessionMonitorKey,
        force: Bool
    ) async -> InspectionOutcome {
        if let inFlight = inspectionTasks[key] {
            counters.increment(.sessionInspectionCoalescedRequests)
            return await inFlight.task.value
        }
        let now = clock.now()
        if !force,
           let cached = inspectionCache[key],
           isFresh(cached.observedAt, ttl: configuration.inspectionTTL, now: now) {
            counters.increment(.sessionInspectionCacheHits)
            return cached.value
        }

        counters.increment(.sessionInspectionExecutions)
        let taskID = UUID()
        let inspector = inspector
        let task = Task<InspectionOutcome, Never> {
            do {
                return .available(
                    try await inspector.inspectSession(
                        winePath: key.winePath,
                        prefixPath: key.prefixPath
                    )
                )
            } catch {
                return .unavailable
            }
        }
        inspectionTasks[key] = InFlight(id: taskID, task: task)
        let result = await task.value
        guard inspectionTasks[key]?.id == taskID else {
            return result
        }

        inspectionTasks.removeValue(forKey: key)
        if inspectionCache[key]?.value != result {
            processCache.removeValue(forKey: key)
            processTasks.removeValue(forKey: key)?.task.cancel()
        }
        inspectionCache[key] = Cached(
            value: result,
            observedAt: clock.now()
        )
        if case let .available(inspection) = result,
           inspection.state == .active {
            return result
        }
        processCache.removeValue(forKey: key)
        processTasks.removeValue(forKey: key)?.task.cancel()
        return result
    }

    private func processOutcome(
        for key: SessionMonitorKey,
        force: Bool
    ) async -> ProcessOutcome {
        if let inFlight = processTasks[key] {
            return await inFlight.task.value
        }
        let now = clock.now()
        if !force,
           let cached = processCache[key],
           isFresh(
               cached.observedAt,
               ttl: configuration.processDetailsTTL,
               now: now
            ) {
            return cached.value
        }

        let taskID = UUID()
        let inspector = inspector
        let task = Task<ProcessOutcome, Never> {
            do {
                return .available(
                    try await inspector.runningWindowsProcessesAsync(
                        winePath: key.winePath,
                        prefixPath: key.prefixPath
                    )
                )
            } catch {
                return .unavailable
            }
        }
        processTasks[key] = InFlight(id: taskID, task: task)
        let result = await task.value
        guard processTasks[key]?.id == taskID else {
            return result
        }
        processTasks.removeValue(forKey: key)
        processCache[key] = Cached(
            value: result,
            observedAt: clock.now()
        )
        return result
    }

    private func isFresh(
        _ observedAt: TimeInterval,
        ttl: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        let age = now - observedAt
        return age >= 0 && age < max(0, ttl)
    }

    private func aggregateDemand(
        for key: SessionMonitorKey
    ) -> AggregateDemand? {
        guard let subscriberGroup = subscribers[key],
              !subscriberGroup.isEmpty else {
            return nil
        }
        return AggregateDemand(
            requestsProcessDetails: subscriberGroup.values.contains {
                $0.demand == .details
            },
            isStartingUp: subscriberGroup.values.contains {
                $0.demand == .startup
            }
        )
    }

    private func restartPolling(for key: SessionMonitorKey) {
        pollTasks.removeValue(forKey: key)?.task.cancel()
        guard aggregateDemand(for: key) != nil else { return }

        let pollID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.poll(key, id: pollID)
        }
        pollTasks[key] = PollTask(id: pollID, task: task)
    }

    private func poll(_ key: SessionMonitorKey, id: UUID) async {
        var isFirstObservation = true
        while !Task.isCancelled,
              pollTasks[key]?.id == id,
              let demand = aggregateDemand(for: key) {
            let snapshot = await makeSnapshot(
                for: key,
                requestsProcessDetails: demand.requestsProcessDetails,
                forceInspection: !isFirstObservation,
                forceProcessDetails: false
            )
            isFirstObservation = false
            guard !Task.isCancelled, pollTasks[key]?.id == id else {
                return
            }
            for subscriber in subscribers[key]?.values ?? [:].values {
                subscriber.continuation.yield(snapshot)
            }

            let cadence = cadence(
                for: snapshot.inspection,
                demand: demand
            )
            do {
                try await clock.sleep(for: cadence)
            } catch {
                return
            }
        }
    }

    private func cadence(
        for inspection: WinePrefixSessionInspection?,
        demand: AggregateDemand
    ) -> TimeInterval {
        if demand.isStartingUp {
            return configuration.startupCadence
        }
        guard inspection?.state == .active else {
            return configuration.inactiveCadence
        }
        return demand.requestsProcessDetails
            ? configuration.detailActiveCadence
            : configuration.summaryActiveCadence
    }

    private func removeSubscriber(
        _ subscriberID: UUID,
        for key: SessionMonitorKey
    ) {
        let previousDemand = aggregateDemand(for: key)
        subscribers[key]?.removeValue(forKey: subscriberID)
        if subscribers[key]?.isEmpty == true {
            subscribers.removeValue(forKey: key)
        }
        let updatedDemand = aggregateDemand(for: key)
        if updatedDemand == nil {
            pollTasks.removeValue(forKey: key)?.task.cancel()
        } else if previousDemand != updatedDemand {
            restartPolling(for: key)
        }
    }
}
