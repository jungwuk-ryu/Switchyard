import AppCore
import CryptoKit
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

struct WineBridgeFileStamp:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let exists: Bool
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    static let missing = WineBridgeFileStamp(
        exists: false,
        device: 0,
        inode: 0,
        size: 0,
        modificationSeconds: 0,
        modificationNanoseconds: 0,
        changeSeconds: 0,
        changeNanoseconds: 0
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
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec),
            changeSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
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
    typealias ObservedDependenciesChanged =
        @Sendable (Set<URL>) -> Void
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
    private let observedDependenciesChanged: ObservedDependenciesChanged
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
        observedDependenciesChanged:
            @escaping ObservedDependenciesChanged = { _ in },
        refresh: @escaping Refresh
    ) {
        self.configuration = configuration
        self.counters = counters
        self.sleep = sleep
        self.stamp = stamp
        self.observedDependenciesChanged = observedDependenciesChanged
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
        observedDependenciesChanged([])
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
        let previousURLs = Set(observedDependencies.keys)
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
        let updatedURLs = Set(updated.keys)
        if updatedURLs != previousURLs {
            observedDependenciesChanged(updatedURLs)
        }
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

enum WineBridgeFileDigestError: Error {
    case invalidFile
    case fileChangedDuringRead
}

actor WineBridgeFileDigestCache {
    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init?(_ status: stat) {
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_size >= 0 else {
                return nil
            }
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = Int64(status.st_size)
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    private struct Entry: Sendable {
        let identity: FileIdentity
        let digest: String
        var accessSequence: UInt64
    }

    private struct DigestResult: Sendable {
        let identity: FileIdentity
        let digest: String
        let wasCacheHit: Bool
    }

    private let counters: PerformanceCounters
    private let maximumEntryCount: Int
    private var entriesByPath: [String: Entry] = [:]
    private var requestGenerationByPath: [String: UInt64] = [:]
    private var accessSequence: UInt64 = 0

    init(
        counters: PerformanceCounters = .shared,
        maximumEntryCount: Int = 1_024
    ) {
        self.counters = counters
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func sha256Hex(of url: URL) async throws -> String {
        try Task.checkCancellation()
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        let cachedEntry = entriesByPath[path]
        let generation = requestGenerationByPath[path, default: 0] &+ 1
        requestGenerationByPath[path] = generation

        let digestTask = Task.detached(priority: .utility) {
            try Self.readDigest(
                at: normalizedURL,
                cachedEntry: cachedEntry
            )
        }
        let result = try await withTaskCancellationHandler {
            try await digestTask.value
        } onCancel: {
            digestTask.cancel()
        }
        try Task.checkCancellation()

        if result.wasCacheHit {
            counters.increment(.bridgeDigestCacheHits)
        }
        guard requestGenerationByPath[path] == generation else {
            return result.digest
        }

        accessSequence &+= 1
        entriesByPath[path] = Entry(
            identity: result.identity,
            digest: result.digest,
            accessSequence: accessSequence
        )
        evictIfNeeded()
        return result.digest
    }

    func removeAll() {
        entriesByPath.removeAll(keepingCapacity: false)
        requestGenerationByPath.removeAll(keepingCapacity: false)
    }

    private func evictIfNeeded() {
        while entriesByPath.count > maximumEntryCount,
              let oldest = entriesByPath.min(by: {
                  $0.value.accessSequence < $1.value.accessSequence
              }) {
            entriesByPath.removeValue(forKey: oldest.key)
            requestGenerationByPath.removeValue(forKey: oldest.key)
        }
    }

    nonisolated private static func readDigest(
        at url: URL,
        cachedEntry: Entry?
    ) throws -> DigestResult {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              let initialIdentity = FileIdentity(initialStatus) else {
            throw WineBridgeFileDigestError.invalidFile
        }
        if let cachedEntry,
           cachedEntry.identity == initialIdentity {
            return DigestResult(
                identity: initialIdentity,
                digest: cachedEntry.digest,
                wasCacheHit: true
            )
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var bytesReadTotal: Int64 = 0
        while true {
            try Task.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 { break }
            bytesReadTotal += Int64(bytesRead)
            hasher.update(data: Data(buffer.prefix(Int(bytesRead))))
        }

        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              let finalIdentity = FileIdentity(finalStatus),
              initialIdentity == finalIdentity,
              bytesReadTotal == initialIdentity.size else {
            throw WineBridgeFileDigestError.fileChangedDuringRead
        }

        return DigestResult(
            identity: initialIdentity,
            digest: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined(),
            wasCacheHit: false
        )
    }
}

final class WineBridgeFileEventSource: @unchecked Sendable {
    private enum TargetKind: String, Hashable {
        case file
        case directory
    }

    private struct Target: Hashable {
        let kind: TargetKind
        let url: URL

        var key: String {
            "\(kind.rawValue):\(url.path)"
        }
    }

    private struct SourceRecord {
        let source: DispatchSourceFileSystemObject
    }

    private let queue = DispatchQueue(
        label: "dev.switchyard.bridge-file-events",
        qos: .utility
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let cancellationGroup = DispatchGroup()
    private let onEvent: @Sendable () -> Void
    private var requestedDependencyURLs: Set<URL> = []
    private var recordsByKey: [String: SourceRecord] = [:]
    private var isShutdown = false

    init(onEvent: @escaping @Sendable () -> Void) {
        self.onEvent = onEvent
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        shutdown()
    }

    func update(dependencyURLs: Set<URL>) {
        executeOnQueue {
            guard !isShutdown else { return }
            requestedDependencyURLs = Set(
                dependencyURLs.map(\.standardizedFileURL)
            )
            rebuildSources()
        }
    }

    func shutdown() {
        let calledFromQueue = DispatchQueue.getSpecific(key: queueKey) != nil
        executeOnQueue {
            guard !isShutdown else { return }
            isShutdown = true
            requestedDependencyURLs.removeAll()
            let records = recordsByKey.values
            recordsByKey.removeAll()
            records.forEach { $0.source.cancel() }
        }
        if !calledFromQueue {
            cancellationGroup.wait()
        }
    }

    private func executeOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func rebuildSources() {
        guard !isShutdown else { return }
        let targets = desiredTargets()
        let desiredKeys = Set(targets.map(\.key))

        for key in recordsByKey.keys
        where !desiredKeys.contains(key) {
            recordsByKey.removeValue(forKey: key)?.source.cancel()
        }
        for target in targets where recordsByKey[target.key] == nil {
            if let record = makeSource(for: target) {
                recordsByKey[target.key] = record
            }
        }
    }

    private func desiredTargets() -> Set<Target> {
        var targets: Set<Target> = []
        for dependencyURL in requestedDependencyURLs {
            if isExistingItem(
                dependencyURL,
                expectedType: mode_t(S_IFREG)
            ) {
                targets.insert(Target(kind: .file, url: dependencyURL))
            }
            if let directoryURL = nearestExistingDirectory(
                to: dependencyURL.deletingLastPathComponent()
            ) {
                targets.insert(
                    Target(kind: .directory, url: directoryURL)
                )
            }
        }
        return targets
    }

    private func nearestExistingDirectory(to requestedURL: URL) -> URL? {
        var candidate = requestedURL.standardizedFileURL
        while true {
            if isExistingItem(
                candidate,
                expectedType: mode_t(S_IFDIR)
            ) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }

    private func isExistingItem(
        _ url: URL,
        expectedType: mode_t
    ) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & mode_t(S_IFMT) == expectedType
    }

    private func makeSource(for target: Target) -> SourceRecord? {
        let descriptor = target.url.path.withCString {
            Darwin.open(
                $0,
                O_EVTONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { return nil }

        var descriptorStatus = stat()
        var pathStatus = stat()
        let expectedType: mode_t = target.kind == .file
            ? mode_t(S_IFREG)
            : mode_t(S_IFDIR)
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              lstat(target.url.path, &pathStatus) == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_mode & mode_t(S_IFMT) == expectedType,
              pathStatus.st_mode & mode_t(S_IFMT) == expectedType else {
            Darwin.close(descriptor)
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [
                .write,
                .extend,
                .attrib,
                .delete,
                .rename,
                .revoke,
            ],
            queue: queue
        )
        cancellationGroup.enter()
        source.setCancelHandler { [cancellationGroup] in
            Darwin.close(descriptor)
            cancellationGroup.leave()
        }
        source.setEventHandler { [weak self, weak source] in
            guard let self, !isShutdown else { return }
            let destructiveEvents: DispatchSource.FileSystemEvent = [
                .delete,
                .rename,
                .revoke,
            ]
            if let source,
               !source.data.intersection(destructiveEvents).isEmpty {
                recordsByKey.removeValue(forKey: target.key)?
                    .source.cancel()
            }
            onEvent()
            rebuildSources()
        }
        source.resume()
        return SourceRecord(source: source)
    }
}

final class WineBridgeRefreshEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var monitor: WineBridgeRefreshMonitor?

    func connect(_ monitor: WineBridgeRefreshMonitor) {
        lock.withLock {
            self.monitor = monitor
        }
    }

    func disconnect() {
        lock.withLock {
            monitor = nil
        }
    }

    func handleFileSystemEvent() {
        let monitor = lock.withLock { self.monitor }
        guard let monitor else { return }
        Task {
            await monitor.handleFileSystemEvent()
        }
    }
}

final class WineBridgeRefreshHandlerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var refresh:
        WineBridgeRefreshMonitor.Refresh?

    func connect(
        _ refresh: @escaping WineBridgeRefreshMonitor.Refresh
    ) {
        lock.withLock {
            self.refresh = refresh
        }
    }

    func disconnect() {
        lock.withLock {
            refresh = nil
        }
    }

    func refresh(
        _ request: WineBridgeRefreshRequest
    ) async throws -> WineBridgeRefreshResult {
        guard let refresh = lock.withLock({ self.refresh }) else {
            throw CancellationError()
        }
        return try await refresh(request)
    }
}
