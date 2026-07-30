import AppCore
import Darwin
import Foundation

struct WineBridgeRefreshScope:
    OptionSet,
    Hashable,
    Sendable
{
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let protocols = Self(rawValue: 1 << 0)
    static let shortcuts = Self(rawValue: 1 << 1)
    static let all: Self = [.protocols, .shortcuts]

    fileprivate var knownScopes: Self {
        intersection(.all)
    }
}

enum WineBridgeRefreshMode: Equatable, Sendable {
    case incremental
    case forcedSafety
}

struct WineBridgeFileStamp: Equatable, Hashable, Sendable {
    let exists: Bool
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    static let missing = WineBridgeFileStamp(
        exists: false,
        device: 0,
        inode: 0,
        size: 0,
        modificationSeconds: 0,
        modificationNanoseconds: 0
    )

    static func read(from url: URL) -> WineBridgeFileStamp {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            return .missing
        }

        return WineBridgeFileStamp(
            exists: true,
            device: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino),
            size: UInt64(max(0, fileStatus.st_size)),
            modificationSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec)
        )
    }
}

struct WineBridgeObservedDependency: Hashable, Sendable {
    let url: URL
    let scope: WineBridgeRefreshScope

    init(
        url: URL,
        scope: WineBridgeRefreshScope
    ) {
        self.url = url
        self.scope = scope.knownScopes
    }
}

struct WineBridgeRefreshRequest: Equatable, Sendable {
    let scope: WineBridgeRefreshScope
    let mode: WineBridgeRefreshMode
}

struct WineBridgeRefreshResult: Equatable, Sendable {
    var observedDependencies: [WineBridgeObservedDependency]

    init(
        observedDependencies: [WineBridgeObservedDependency] = []
    ) {
        self.observedDependencies = observedDependencies
    }
}

struct WineBridgeRefreshMonitorConfiguration: Equatable, Sendable {
    var coalescingInterval: TimeInterval
    var safetyResyncInterval: TimeInterval

    init(
        coalescingInterval: TimeInterval = 0.2,
        safetyResyncInterval: TimeInterval = 45
    ) {
        self.coalescingInterval = max(0, coalescingInterval)
        self.safetyResyncInterval = min(
            60,
            max(30, safetyResyncInterval)
        )
    }
}

struct WineBridgeRefreshMonitorMetrics: Equatable, Sendable {
    fileprivate(set) var protocolInvalidations: UInt64 = 0
    fileprivate(set) var shortcutInvalidations: UInt64 = 0
    fileprivate(set) var coalescedInvalidations: UInt64 = 0
    fileprivate(set) var refreshExecutions: UInt64 = 0
    fileprivate(set) var safetyResyncs: UInt64 = 0
}

struct WineBridgeRefreshMonitorSnapshot: Equatable, Sendable {
    let isRunning: Bool
    let isRefreshInFlight: Bool
    let pendingScope: WineBridgeRefreshScope
    let observedDependencies: Set<WineBridgeObservedDependency>
    let lastRefreshErrorDescription: String?
    let metrics: WineBridgeRefreshMonitorMetrics
}

private final class WineBridgeRefreshMonitorMetricsRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value = WineBridgeRefreshMonitorMetrics()

    func recordInvalidation(
        _ scope: WineBridgeRefreshScope,
        wasCoalesced: Bool
    ) {
        lock.withLock {
            if wasCoalesced {
                Self.increment(&value.coalescedInvalidations)
            }
            if scope.contains(.protocols) {
                Self.increment(&value.protocolInvalidations)
            }
            if scope.contains(.shortcuts) {
                Self.increment(&value.shortcutInvalidations)
            }
        }
    }

    func recordExecution(_ request: WineBridgeRefreshRequest) {
        lock.withLock {
            Self.increment(&value.refreshExecutions)
            if request.mode == .forcedSafety {
                Self.increment(&value.safetyResyncs)
            }
        }
    }

    func snapshot() -> WineBridgeRefreshMonitorMetrics {
        lock.withLock { value }
    }

    private static func increment(_ value: inout UInt64) {
        let (updated, overflowed) = value.addingReportingOverflow(1)
        value = overflowed ? .max : updated
    }
}

actor WineBridgeRefreshMonitor {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias Stamp = @Sendable (URL) async -> WineBridgeFileStamp
    typealias Refresh = @Sendable (
        WineBridgeRefreshRequest
    ) async throws -> WineBridgeRefreshResult

    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    private enum RefreshTaskOutcome: Sendable {
        case success(
            WineBridgeRefreshResult,
            [URL: WineBridgeFileStamp]
        )
        case failure(String)
        case cancelled
    }

    private struct ObservedDependencyState: Equatable {
        var protocolStamp: WineBridgeFileStamp?
        var shortcutStamp: WineBridgeFileStamp?

        var scope: WineBridgeRefreshScope {
            var scope: WineBridgeRefreshScope = []
            if protocolStamp != nil {
                scope.insert(.protocols)
            }
            if shortcutStamp != nil {
                scope.insert(.shortcuts)
            }
            return scope
        }

        mutating func remove(_ scope: WineBridgeRefreshScope) {
            if scope.contains(.protocols) {
                protocolStamp = nil
            }
            if scope.contains(.shortcuts) {
                shortcutStamp = nil
            }
        }

        mutating func set(
            _ stamp: WineBridgeFileStamp,
            for scope: WineBridgeRefreshScope
        ) {
            if scope.contains(.protocols) {
                protocolStamp = stamp
            }
            if scope.contains(.shortcuts) {
                shortcutStamp = stamp
            }
        }

        func changedScope(
            for newStamp: WineBridgeFileStamp
        ) -> WineBridgeRefreshScope {
            var changedScope: WineBridgeRefreshScope = []
            if let protocolStamp,
               protocolStamp != newStamp {
                changedScope.insert(.protocols)
            }
            if let shortcutStamp,
               shortcutStamp != newStamp {
                changedScope.insert(.shortcuts)
            }
            return changedScope
        }
    }

    private struct ScheduledTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct ActiveRefresh {
        let id: UUID
        let generation: UInt64
        let request: WineBridgeRefreshRequest
        let task: Task<RefreshTaskOutcome, Never>
    }

    private let configuration: WineBridgeRefreshMonitorConfiguration
    private let counters: PerformanceCounters
    private let sleep: Sleep
    private let stamp: Stamp
    private let refresh: Refresh

    private var lifecycle: Lifecycle = .idle
    private var lifecycleGeneration: UInt64 = 0
    private var dependencyGeneration: UInt64 = 0
    private var observedDependencies:
        [URL: ObservedDependencyState] = [:]
    private var pendingScope: WineBridgeRefreshScope = []
    private var pendingForcedSafety = false
    private var refreshDelayTask: ScheduledTask?
    private var safetyTask: ScheduledTask?
    private var activeRefresh: ActiveRefresh?
    private var lastRefreshErrorDescription: String?
    private let metricsRecorder = WineBridgeRefreshMonitorMetricsRecorder()

    init(
        configuration: WineBridgeRefreshMonitorConfiguration =
            WineBridgeRefreshMonitorConfiguration(),
        counters: PerformanceCounters = .shared,
        sleep: @escaping Sleep = { interval in
            try await Task.sleep(for: .seconds(max(0, interval)))
        },
        stamp: @escaping Stamp = { url in
            WineBridgeFileStamp.read(from: url)
        },
        refresh: @escaping Refresh
    ) {
        self.configuration = configuration
        self.counters = counters
        self.sleep = sleep
        self.stamp = stamp
        self.refresh = refresh
    }

    deinit {
        refreshDelayTask?.task.cancel()
        safetyTask?.task.cancel()
        activeRefresh?.task.cancel()
    }

    func start() async {
        guard lifecycle == .idle else { return }

        lifecycle = .running
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        enqueue(scope: .all, mode: .incremental)
        await executePendingRefresh()

        guard lifecycle == .running,
              lifecycleGeneration == generation else {
            return
        }
        startSafetyTimer(for: generation)
    }

    func shutdown() async {
        guard lifecycle == .running else { return }

        lifecycle = .stopped
        lifecycleGeneration &+= 1
        pendingScope = []
        pendingForcedSafety = false

        let refreshDelay = refreshDelayTask?.task
        let safety = safetyTask?.task
        let refreshExecution = activeRefresh?.task
        refreshDelay?.cancel()
        safety?.cancel()
        refreshExecution?.cancel()

        if let refreshDelay {
            await refreshDelay.value
        }
        if let safety {
            await safety.value
        }
        if let refreshExecution {
            _ = await refreshExecution.value
        }

        refreshDelayTask = nil
        safetyTask = nil
        activeRefresh = nil
        observedDependencies.removeAll()
        dependencyGeneration &+= 1
    }

    func invalidate(_ scope: WineBridgeRefreshScope) {
        let scope = scope.knownScopes
        guard lifecycle == .running, !scope.isEmpty else { return }

        recordInvalidation(scope)
        enqueue(scope: scope, mode: .incremental)
        if activeRefresh == nil {
            schedulePendingRefresh()
        }
    }

    func handleFileSystemEvent() async {
        await probeObservedDependencies()
    }

    func probeObservedDependencies() async {
        guard lifecycle == .running,
              !observedDependencies.isEmpty else {
            return
        }

        let lifecycleGeneration = lifecycleGeneration
        let dependencyGeneration = dependencyGeneration
        let dependencies = observedDependencies
            .map { (url: $0.key, state: $0.value) }
            .sorted { $0.url.path < $1.url.path }
        var probedStamps: [URL: WineBridgeFileStamp] = [:]
        probedStamps.reserveCapacity(dependencies.count)

        for dependency in dependencies {
            guard !Task.isCancelled else { return }
            probedStamps[dependency.url] = await stamp(dependency.url)
        }

        guard !Task.isCancelled,
              lifecycle == .running,
              self.lifecycleGeneration == lifecycleGeneration,
              self.dependencyGeneration == dependencyGeneration else {
            return
        }

        var changedScope: WineBridgeRefreshScope = []
        for dependency in dependencies {
            guard let current = observedDependencies[dependency.url],
                  current == dependency.state,
                  let newStamp = probedStamps[dependency.url],
                  current.changedScope(for: newStamp).isEmpty == false else {
                continue
            }
            let changedDependencyScope = current.changedScope(
                for: newStamp
            )
            observedDependencies[dependency.url]?.set(
                newStamp,
                for: changedDependencyScope
            )
            changedScope.formUnion(changedDependencyScope)
        }

        guard !changedScope.isEmpty else { return }
        self.dependencyGeneration &+= 1
        recordInvalidation(changedScope)
        enqueue(scope: changedScope, mode: .incremental)
        if activeRefresh == nil {
            schedulePendingRefresh()
        }
    }

    func flushPendingRefresh() async {
        guard lifecycle == .running else { return }
        await cancelRefreshDelay()
        guard activeRefresh == nil else { return }
        await executePendingRefresh()
    }

    func performSafetyResyncNow() async {
        guard lifecycle == .running else { return }

        enqueue(scope: .all, mode: .forcedSafety)
        guard activeRefresh == nil else { return }
        await cancelRefreshDelay()
        await executePendingRefresh()
    }

    func snapshot() -> WineBridgeRefreshMonitorSnapshot {
        WineBridgeRefreshMonitorSnapshot(
            isRunning: lifecycle == .running,
            isRefreshInFlight: activeRefresh != nil,
            pendingScope: pendingScope,
            observedDependencies: Set(
                observedDependencies.map {
                    WineBridgeObservedDependency(
                        url: $0.key,
                        scope: $0.value.scope
                    )
                }
            ),
            lastRefreshErrorDescription: lastRefreshErrorDescription,
            metrics: metricsRecorder.snapshot()
        )
    }

    func observedParentDirectories() -> Set<URL> {
        Set(
            observedDependencies.keys.map {
                $0.deletingLastPathComponent().standardizedFileURL
            }
        )
    }

    private func enqueue(
        scope: WineBridgeRefreshScope,
        mode: WineBridgeRefreshMode
    ) {
        pendingScope.formUnion(scope.knownScopes)
        if mode == .forcedSafety {
            pendingForcedSafety = true
        }
    }

    private func schedulePendingRefresh() {
        guard lifecycle == .running,
              activeRefresh == nil,
              refreshDelayTask == nil,
              !pendingScope.isEmpty else {
            return
        }

        let id = UUID()
        let generation = lifecycleGeneration
        let interval = configuration.coalescingInterval
        let sleep = sleep
        let task = Task { [weak self] in
            do {
                try await sleep(interval)
            } catch {
                return
            }
            await self?.refreshDelayDidFinish(
                id: id,
                generation: generation
            )
        }
        refreshDelayTask = ScheduledTask(id: id, task: task)
    }

    private func refreshDelayDidFinish(
        id: UUID,
        generation: UInt64
    ) async {
        guard lifecycle == .running,
              lifecycleGeneration == generation,
              refreshDelayTask?.id == id else {
            return
        }
        refreshDelayTask = nil
        await executePendingRefresh()
    }

    private func cancelRefreshDelay() async {
        guard let task = refreshDelayTask?.task else { return }
        refreshDelayTask = nil
        task.cancel()
        await task.value
    }

    private func executePendingRefresh() async {
        guard lifecycle == .running,
              activeRefresh == nil,
              !pendingScope.isEmpty else {
            return
        }

        let request = WineBridgeRefreshRequest(
            scope: pendingScope,
            mode: pendingForcedSafety ? .forcedSafety : .incremental
        )
        pendingScope = []
        pendingForcedSafety = false

        let id = UUID()
        let generation = lifecycleGeneration
        let refresh = refresh
        let stamp = stamp
        let counters = counters
        let metricsRecorder = metricsRecorder
        let task = Task<RefreshTaskOutcome, Never> {
            do {
                try Task.checkCancellation()
                metricsRecorder.recordExecution(request)
                if request.scope.contains(.protocols) {
                    counters.increment(.protocolBridgeRefreshes)
                }
                if request.scope.contains(.shortcuts) {
                    counters.increment(.shortcutBridgeRefreshes)
                }
                if request.mode == .forcedSafety {
                    counters.increment(.bridgeSafetyResyncs)
                }
                let result = try await refresh(request)
                try Task.checkCancellation()
                let dependencyURLs = Set(
                    result.observedDependencies.map {
                        Self.normalizedURL($0.url)
                    }
                ).sorted { $0.path < $1.path }
                var stamps: [URL: WineBridgeFileStamp] = [:]
                stamps.reserveCapacity(dependencyURLs.count)
                for url in dependencyURLs {
                    try Task.checkCancellation()
                    stamps[url] = await stamp(url)
                }
                try Task.checkCancellation()
                return RefreshTaskOutcome.success(result, stamps)
            } catch is CancellationError {
                return RefreshTaskOutcome.cancelled
            } catch {
                return RefreshTaskOutcome.failure(String(describing: error))
            }
        }
        activeRefresh = ActiveRefresh(
            id: id,
            generation: generation,
            request: request,
            task: task
        )

        let outcome = await task.value
        finishRefresh(
            id: id,
            generation: generation,
            request: request,
            outcome: outcome
        )
    }

    private func finishRefresh(
        id: UUID,
        generation: UInt64,
        request: WineBridgeRefreshRequest,
        outcome: RefreshTaskOutcome
    ) {
        guard activeRefresh?.id == id else { return }
        activeRefresh = nil

        guard lifecycle == .running,
              lifecycleGeneration == generation else {
            return
        }

        switch outcome {
        case let .success(result, stamps):
            let additionallyInvalidatedScope = replaceObservedDependencies(
                for: request.scope,
                with: result.observedDependencies,
                stamps: stamps
            )
            if !additionallyInvalidatedScope.isEmpty {
                recordInvalidation(additionallyInvalidatedScope)
                enqueue(
                    scope: additionallyInvalidatedScope,
                    mode: .incremental
                )
            }
            lastRefreshErrorDescription = nil
        case let .failure(description):
            lastRefreshErrorDescription = description
        case .cancelled:
            break
        }

        if !pendingScope.isEmpty {
            schedulePendingRefresh()
        }
    }

    private func replaceObservedDependencies(
        for refreshedScope: WineBridgeRefreshScope,
        with dependencies: [WineBridgeObservedDependency],
        stamps: [URL: WineBridgeFileStamp]
    ) -> WineBridgeRefreshScope {
        var updated = observedDependencies
        var additionallyInvalidatedScope: WineBridgeRefreshScope = []

        for url in updated.keys {
            updated[url]?.remove(refreshedScope)
            if updated[url]?.scope.isEmpty == true {
                updated.removeValue(forKey: url)
            }
        }

        for dependency in dependencies {
            let scope = dependency.scope.intersection(refreshedScope)
            guard !scope.isEmpty else { continue }

            let url = Self.normalizedURL(dependency.url)
            var state = updated[url] ?? ObservedDependencyState(
                protocolStamp: nil,
                shortcutStamp: nil
            )
            let refreshedStamp = stamps[url] ?? .missing
            additionallyInvalidatedScope.formUnion(
                state.changedScope(for: refreshedStamp)
            )
            state.set(refreshedStamp, for: scope)
            updated[url] = state
        }

        observedDependencies = updated
        dependencyGeneration &+= 1
        return additionallyInvalidatedScope
    }

    private func startSafetyTimer(for generation: UInt64) {
        guard safetyTask == nil else { return }

        let id = UUID()
        let interval = configuration.safetyResyncInterval
        let sleep = sleep
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard await self?.safetyIntervalDidElapse(
                    generation: generation
                ) == true else {
                    return
                }
            }
        }
        safetyTask = ScheduledTask(id: id, task: task)
    }

    private func safetyIntervalDidElapse(
        generation: UInt64
    ) async -> Bool {
        guard lifecycle == .running,
              lifecycleGeneration == generation else {
            return false
        }
        await performSafetyResyncNow()
        return lifecycle == .running
            && lifecycleGeneration == generation
    }

    private func recordInvalidation(
        _ scope: WineBridgeRefreshScope
    ) {
        metricsRecorder.recordInvalidation(
            scope,
            wasCoalesced: activeRefresh != nil || !pendingScope.isEmpty
        )
    }

    nonisolated private static func normalizedURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }
}
