import AppCore
import Foundation
import Testing
@testable import Switchyard

@Suite("Session Monitor")
struct SessionMonitorTests {
    @Test(
        "uses the inspection TTL and records cache behavior",
        .timeLimit(.minutes(1))
    )
    func inspectionTTL() async {
        let key = SessionMonitorKey(winePath: "/wine", prefixPath: "/prefix")
        let clock = SessionMonitorTestClock(now: 100)
        let inspector = SessionMonitorInspectorFake()
        let counters = PerformanceCounters()
        let monitor = SessionMonitor(
            inspector: inspector,
            configuration: SessionMonitorConfiguration(inspectionTTL: 1),
            counters: counters,
            clock: clock
        )

        let first = await monitor.snapshot(for: key, demand: .summary)
        let second = await monitor.snapshot(for: key, demand: .summary)
        clock.advance(by: 1)
        let third = await monitor.snapshot(for: key, demand: .summary)

        #expect(first.inspection == second.inspection)
        #expect(first.processDetails == second.processDetails)
        #expect(third.inspection == first.inspection)
        #expect(await inspector.inspectionCount(for: key) == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.sessionInspectionRequests] == 3)
        #expect(metrics[.sessionInspectionExecutions] == 2)
        #expect(metrics[.sessionInspectionCacheHits] == 1)
        #expect(metrics[.sessionInspectionCoalescedRequests] == 0)
        await monitor.shutdown()
    }

    @Test(
        "coalesces concurrent callers without transferring cancellation",
        .timeLimit(.minutes(1))
    )
    func coalescesConcurrentCallers() async throws {
        let key = SessionMonitorKey(winePath: "/wine", prefixPath: "/prefix")
        let inspector = SessionMonitorInspectorFake()
        await inspector.blockInspections()
        let counters = PerformanceCounters()
        let monitor = SessionMonitor(
            inspector: inspector,
            counters: counters
        )

        let first = Task {
            await monitor.snapshot(for: key, demand: .summary)
        }
        await inspector.waitForInspectionCount(1)
        let second = Task {
            await monitor.snapshot(for: key, demand: .summary)
        }
        try await waitUntil {
            counters.snapshot()[.sessionInspectionCoalescedRequests] == 1
        }

        first.cancel()
        await inspector.releaseInspections()
        let firstResult = await first.value
        let secondResult = await second.value

        #expect(firstResult.inspection == secondResult.inspection)
        #expect(await inspector.inspectionCount(for: key) == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.sessionInspectionRequests] == 2)
        #expect(metrics[.sessionInspectionExecutions] == 1)
        #expect(metrics[.sessionInspectionCoalescedRequests] == 1)
        await monitor.shutdown()
    }

    @Test(
        "keeps different prefix keys independent",
        .timeLimit(.minutes(1))
    )
    func doesNotCoalesceDifferentKeys() async {
        let firstKey = SessionMonitorKey(
            winePath: "/wine",
            prefixPath: "/prefix-a"
        )
        let secondKey = SessionMonitorKey(
            winePath: "/wine",
            prefixPath: "/prefix-b"
        )
        let inspector = SessionMonitorInspectorFake()
        let counters = PerformanceCounters()
        let monitor = SessionMonitor(
            inspector: inspector,
            counters: counters
        )

        async let first = monitor.snapshot(
            for: firstKey,
            demand: .summary
        )
        async let second = monitor.snapshot(
            for: secondKey,
            demand: .summary
        )
        _ = await (first, second)

        #expect(await inspector.totalInspectionCount() == 2)
        #expect(
            counters.snapshot()[.sessionInspectionCoalescedRequests] == 0
        )
        await monitor.shutdown()
    }

    @Test(
        "runs process details only for active detail demand",
        .timeLimit(.minutes(1))
    )
    func processDetailsAreDemandDriven() async {
        let activeKey = SessionMonitorKey(
            winePath: "/wine",
            prefixPath: "/active"
        )
        let inactiveKey = SessionMonitorKey(
            winePath: "/wine",
            prefixPath: "/inactive"
        )
        let inspector = SessionMonitorInspectorFake()
        await inspector.setInspection(
            WinePrefixSessionInspection(
                state: .active,
                hostProcessIDs: [41, 42]
            ),
            for: activeKey
        )
        await inspector.setProcesses(
            [RunningWindowsProcess(executablePath: "C:\\Game.exe", processID: 7)],
            for: activeKey
        )
        await inspector.setInspection(
            WinePrefixSessionInspection(
                state: .inactive,
                hostProcessIDs: [99]
            ),
            for: inactiveKey
        )
        let monitor = SessionMonitor(
            inspector: inspector,
            counters: PerformanceCounters()
        )

        let summary = await monitor.snapshot(
            for: activeKey,
            demand: .summary
        )
        let detailed = await monitor.snapshot(
            for: activeKey,
            demand: .details
        )
        let inactive = await monitor.snapshot(
            for: inactiveKey,
            demand: .details
        )

        #expect(summary.processDetails == .notRequested)
        #expect(
            detailed.processDetails == .available([
                RunningWindowsProcess(
                    executablePath: "C:\\Game.exe",
                    processID: 7
                )
            ])
        )
        #expect(inactive.processDetails == .available([]))
        #expect(inactive.inspection?.hostProcessIDs == [])
        #expect(await inspector.processCount(for: activeKey) == 1)
        #expect(await inspector.processCount(for: inactiveKey) == 0)
        await monitor.shutdown()
    }

    @Test(
        "retains base state when process details fail",
        .timeLimit(.minutes(1))
    )
    func detailFailureRetainsBaseState() async {
        let key = SessionMonitorKey(winePath: "/wine", prefixPath: "/prefix")
        let inspector = SessionMonitorInspectorFake()
        let expectedInspection = WinePrefixSessionInspection(
            state: .active,
            hostProcessIDs: [71]
        )
        await inspector.setInspection(expectedInspection, for: key)
        await inspector.failProcessDetails(for: key)
        let monitor = SessionMonitor(
            inspector: inspector,
            counters: PerformanceCounters()
        )

        let snapshot = await monitor.snapshot(for: key, demand: .details)

        #expect(snapshot.inspection == expectedInspection)
        #expect(snapshot.processDetails == .unavailable)
        await monitor.shutdown()
    }

    @Test(
        "does not return stale active state after details race a newer inspection",
        .timeLimit(.minutes(1))
    )
    func processDetailRaceUsesLatestInspection() async {
        let key = SessionMonitorKey(winePath: "/wine", prefixPath: "/prefix")
        let inspector = SessionMonitorInspectorFake()
        await inspector.setInspection(
            WinePrefixSessionInspection(state: .active, hostProcessIDs: [71]),
            for: key
        )
        await inspector.blockProcessDetails()
        let monitor = SessionMonitor(
            inspector: inspector,
            counters: PerformanceCounters()
        )

        let staleDetailSnapshot = Task {
            await monitor.snapshot(for: key, demand: .details, force: true)
        }
        await inspector.waitForProcessCount(1)
        await inspector.setInspection(
            WinePrefixSessionInspection(state: .inactive, hostProcessIDs: []),
            for: key
        )
        let latestSnapshot = await monitor.snapshot(
            for: key,
            demand: .summary,
            force: true
        )

        await inspector.releaseProcessDetails()
        let racedSnapshot = await staleDetailSnapshot.value

        #expect(latestSnapshot.inspection?.state == .inactive)
        #expect(racedSnapshot.inspection?.state == .inactive)
        #expect(racedSnapshot.processDetails == .available([]))
        await monitor.shutdown()
    }

    @Test(
        "uses one poller with subscriber-driven cadence and stops on demand",
        .timeLimit(.minutes(1))
    )
    func subscriberDemandControlsCadence() async throws {
        let key = SessionMonitorKey(winePath: "/wine", prefixPath: "/prefix")
        let clock = SessionMonitorTestClock()
        let inspector = SessionMonitorInspectorFake()
        let counters = PerformanceCounters()
        let monitor = SessionMonitor(
            inspector: inspector,
            configuration: SessionMonitorConfiguration(
                inspectionTTL: 1,
                processDetailsTTL: 1,
                summaryActiveCadence: 3,
                detailActiveCadence: 2,
                inactiveCadence: 8,
                startupCadence: 0.25
            ),
            counters: counters,
            clock: clock
        )

        let summaryStream = await monitor.updates(
            for: key,
            demand: .summary
        )
        let summaryConsumer = consume(summaryStream)
        try await waitUntil {
            clock.requestedIntervals().contains(3)
        }

        let detailStream = await monitor.updates(
            for: key,
            demand: .details
        )
        let detailConsumer = consume(detailStream)
        try await waitUntil {
            let processCount = await inspector.processCount(for: key)
            return clock.requestedIntervals().contains(2)
                && processCount == 1
        }

        let startupStream = await monitor.updates(
            for: key,
            demand: .startup
        )
        let startupConsumer = consume(startupStream)
        try await waitUntil {
            clock.requestedIntervals().contains(0.25)
        }

        #expect(await monitor.subscriberCount(for: key) == 3)
        #expect(await monitor.isPolling(key))
        #expect(await inspector.processCount(for: key) == 1)
        #expect(counters.snapshot()[.sessionInspectionExecutions] == 1)

        summaryConsumer.cancel()
        detailConsumer.cancel()
        startupConsumer.cancel()
        await summaryConsumer.value
        await detailConsumer.value
        await startupConsumer.value
        try await waitUntil {
            let subscriberCount = await monitor.subscriberCount(for: key)
            let isPolling = await monitor.isPolling(key)
            return subscriberCount == 0
                && !isPolling
                && clock.pendingSleepCount() == 0
        }

        let inspectionCount = await inspector.totalInspectionCount()
        clock.advance(by: 100)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await inspector.totalInspectionCount() == inspectionCount)
        await monitor.shutdown()
    }
}

private enum SessionMonitorTestError: Error {
    case processDetails
    case conditionWasNotMet
}

private actor SessionMonitorInspectorFake: WineSessionInspecting {
    private var inspections: [SessionMonitorKey: WinePrefixSessionInspection] = [:]
    private var processes: [SessionMonitorKey: [RunningWindowsProcess]] = [:]
    private var failingProcessKeys: Set<SessionMonitorKey> = []
    private var inspectionCounts: [SessionMonitorKey: Int] = [:]
    private var processCounts: [SessionMonitorKey: Int] = [:]
    private var shouldBlockInspections = false
    private var shouldBlockProcessDetails = false
    private var blockedInspections: [CheckedContinuation<Void, Never>] = []
    private var blockedProcessDetails: [CheckedContinuation<Void, Never>] = []
    private var inspectionCountWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var processCountWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func setInspection(
        _ inspection: WinePrefixSessionInspection,
        for key: SessionMonitorKey
    ) {
        inspections[key] = inspection
    }

    func setProcesses(
        _ value: [RunningWindowsProcess],
        for key: SessionMonitorKey
    ) {
        processes[key] = value
    }

    func failProcessDetails(for key: SessionMonitorKey) {
        failingProcessKeys.insert(key)
    }

    func blockInspections() {
        shouldBlockInspections = true
    }

    func releaseInspections() {
        shouldBlockInspections = false
        let continuations = blockedInspections
        blockedInspections.removeAll()
        continuations.forEach { $0.resume() }
    }

    func blockProcessDetails() {
        shouldBlockProcessDetails = true
    }

    func releaseProcessDetails() {
        shouldBlockProcessDetails = false
        let continuations = blockedProcessDetails
        blockedProcessDetails.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForInspectionCount(_ target: Int) async {
        if inspectionCounts.values.reduce(0, +) >= target {
            return
        }
        await withCheckedContinuation { continuation in
            inspectionCountWaiters.append((target, continuation))
        }
    }

    func waitForProcessCount(_ target: Int) async {
        if processCounts.values.reduce(0, +) >= target {
            return
        }
        await withCheckedContinuation { continuation in
            processCountWaiters.append((target, continuation))
        }
    }

    func inspectionCount(for key: SessionMonitorKey) -> Int {
        inspectionCounts[key, default: 0]
    }

    func totalInspectionCount() -> Int {
        inspectionCounts.values.reduce(0, +)
    }

    func processCount(for key: SessionMonitorKey) -> Int {
        processCounts[key, default: 0]
    }

    func inspectSession(
        winePath: String,
        prefixPath: String
    ) async throws -> WinePrefixSessionInspection {
        let key = SessionMonitorKey(
            winePath: winePath,
            prefixPath: prefixPath
        )
        inspectionCounts[key, default: 0] += 1
        resumeInspectionCountWaiters()
        if shouldBlockInspections {
            await withCheckedContinuation { continuation in
                blockedInspections.append(continuation)
            }
        }
        return inspections[key] ?? WinePrefixSessionInspection(
            state: .active,
            hostProcessIDs: [11]
        )
    }

    func runningWindowsProcessesAsync(
        winePath: String,
        prefixPath: String
    ) async throws -> [RunningWindowsProcess] {
        let key = SessionMonitorKey(
            winePath: winePath,
            prefixPath: prefixPath
        )
        processCounts[key, default: 0] += 1
        resumeProcessCountWaiters()
        if shouldBlockProcessDetails {
            await withCheckedContinuation { continuation in
                blockedProcessDetails.append(continuation)
            }
        }
        if failingProcessKeys.contains(key) {
            throw SessionMonitorTestError.processDetails
        }
        return processes[key] ?? []
    }

    private func resumeInspectionCountWaiters() {
        let count = inspectionCounts.values.reduce(0, +)
        let ready = inspectionCountWaiters.filter { $0.target <= count }
        inspectionCountWaiters.removeAll { $0.target <= count }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumeProcessCountWaiters() {
        let count = processCounts.values.reduce(0, +)
        let ready = processCountWaiters.filter { $0.target <= count }
        processCountWaiters.removeAll { $0.target <= count }
        ready.forEach { $0.continuation.resume() }
    }
}

private final class SessionMonitorTestClock:
    SessionMonitorClock,
    @unchecked Sendable
{
    private struct SleepRequest {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentTime: TimeInterval
    private var sleepRequests: [UUID: SleepRequest] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var intervals: [TimeInterval] = []

    init(now: TimeInterval = 0) {
        currentTime = now
    }

    func now() -> TimeInterval {
        lock.withLock { currentTime }
    }

    func sleep(for interval: TimeInterval) async throws {
        let requestID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock {
                    intervals.append(interval)
                    if cancelledBeforeRegistration.remove(requestID) != nil {
                        return true
                    }
                    sleepRequests[requestID] = SleepRequest(
                        deadline: currentTime + interval,
                        continuation: continuation
                    )
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelSleep(requestID)
        }
    }

    func advance(by interval: TimeInterval) {
        let continuations = lock.withLock {
            currentTime += interval
            let readyIDs = sleepRequests.compactMap { id, request in
                request.deadline <= currentTime ? id : nil
            }
            return readyIDs.compactMap {
                sleepRequests.removeValue(forKey: $0)?.continuation
            }
        }
        continuations.forEach { $0.resume() }
    }

    func requestedIntervals() -> [TimeInterval] {
        lock.withLock { intervals }
    }

    func pendingSleepCount() -> Int {
        lock.withLock { sleepRequests.count }
    }

    private func cancelSleep(_ requestID: UUID) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            if let request = sleepRequests.removeValue(forKey: requestID) {
                return request.continuation
            }
            cancelledBeforeRegistration.insert(requestID)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private func consume(
    _ stream: AsyncStream<SessionMonitorSnapshot>
) -> Task<Void, Never> {
    Task {
        for await _ in stream {
            if Task.isCancelled {
                return
            }
        }
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<10_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw SessionMonitorTestError.conditionWasNotMet
}
