import AppCore
import Foundation
import Testing
@testable import Switchyard

@Suite("Wine Bridge Refresh Monitor")
struct WineBridgeRefreshMonitorTests {
    @Test("starts with one full refresh and records dynamic dependencies")
    func initialRefreshRunsOnce() async {
        let protocolURL = URL(fileURLWithPath: "/virtual/prefix/protocols.reg")
        let shortcutURL = URL(fileURLWithPath: "/virtual/prefix/game.lnk")
        let harness = WineBridgeRefreshHarness()
        await harness.setStamp(stamp(inode: 11), for: protocolURL)
        await harness.setStamp(stamp(inode: 12), for: shortcutURL)
        await harness.setDependencies([
            WineBridgeObservedDependency(
                url: protocolURL,
                scope: .protocols
            ),
            WineBridgeObservedDependency(
                url: shortcutURL,
                scope: .shortcuts
            ),
        ])
        let counters = PerformanceCounters()
        let monitor = makeMonitor(harness: harness, counters: counters)

        await monitor.start()
        await monitor.start()

        #expect(await harness.requests() == [
            WineBridgeRefreshRequest(
                scope: .all,
                mode: .incremental
            )
        ])
        let snapshot = await monitor.snapshot()
        #expect(snapshot.isRunning)
        #expect(!snapshot.isRefreshInFlight)
        #expect(snapshot.pendingScope.isEmpty)
        #expect(snapshot.observedDependencies == [
            WineBridgeObservedDependency(
                url: protocolURL,
                scope: .protocols
            ),
            WineBridgeObservedDependency(
                url: shortcutURL,
                scope: .shortcuts
            ),
        ])
        #expect(await monitor.observedParentDirectories() == [
            URL(fileURLWithPath: "/virtual/prefix", isDirectory: true)
                .standardizedFileURL
        ])
        #expect(snapshot.metrics.refreshExecutions == 1)
        #expect(snapshot.metrics.protocolInvalidations == 0)
        #expect(snapshot.metrics.shortcutInvalidations == 0)
        #expect(counters.snapshot()[.protocolBridgeRefreshes] == 1)
        #expect(counters.snapshot()[.shortcutBridgeRefreshes] == 1)
        #expect(counters.snapshot()[.bridgeSafetyResyncs] == 0)

        await monitor.shutdown()
    }

    @Test("coalesces burst invalidations into one scoped execution")
    func coalescesBurstInvalidations() async {
        let harness = WineBridgeRefreshHarness()
        let counters = PerformanceCounters()
        let monitor = makeMonitor(harness: harness, counters: counters)
        await monitor.start()

        await monitor.invalidate(.protocols)
        await monitor.invalidate(.protocols)
        await monitor.invalidate(.shortcuts)
        await monitor.flushPendingRefresh()

        #expect(await harness.requests() == [
            WineBridgeRefreshRequest(
                scope: .all,
                mode: .incremental
            ),
            WineBridgeRefreshRequest(
                scope: .all,
                mode: .incremental
            ),
        ])
        let metrics = await monitor.snapshot().metrics
        #expect(metrics.protocolInvalidations == 2)
        #expect(metrics.shortcutInvalidations == 1)
        #expect(metrics.coalescedInvalidations == 2)
        #expect(metrics.refreshExecutions == 2)
        #expect(counters.snapshot()[.protocolBridgeRefreshes] == 2)
        #expect(counters.snapshot()[.shortcutBridgeRefreshes] == 2)

        await monitor.shutdown()
    }

    @Test("queues one follow-up refresh for invalidations during a refresh")
    func coalescesInFlightInvalidations() async throws {
        let harness = WineBridgeRefreshHarness()
        let monitor = makeMonitor(harness: harness)
        await monitor.start()
        harness.blockRefreshes()

        await monitor.invalidate(.protocols)
        let firstRefresh = Task {
            await monitor.flushPendingRefresh()
        }
        try await waitUntil {
            await harness.requestCount() == 2
        }

        await monitor.invalidate(.protocols)
        await monitor.invalidate(.shortcuts)
        harness.releaseRefreshes()
        await firstRefresh.value
        await monitor.flushPendingRefresh()

        #expect(await harness.requests() == [
            WineBridgeRefreshRequest(
                scope: .all,
                mode: .incremental
            ),
            WineBridgeRefreshRequest(
                scope: .protocols,
                mode: .incremental
            ),
            WineBridgeRefreshRequest(
                scope: .all,
                mode: .incremental
            ),
        ])
        #expect(await harness.maximumConcurrentRefreshes() == 1)
        #expect(await monitor.snapshot().metrics.coalescedInvalidations == 2)

        await monitor.shutdown()
    }

    @Test("detects create, atomic replace, and delete through stable stamps")
    func detectsEveryFileIdentityTransition() async {
        let protocolURL = URL(fileURLWithPath: "/virtual/prefix/protocols.reg")
        let shortcutURL = URL(fileURLWithPath: "/virtual/prefix/game.lnk")
        let harness = WineBridgeRefreshHarness()
        await harness.setStamp(.missing, for: protocolURL)
        await harness.setStamp(stamp(inode: 90), for: shortcutURL)
        await harness.setDependencies([
            WineBridgeObservedDependency(
                url: protocolURL,
                scope: .protocols
            ),
            WineBridgeObservedDependency(
                url: shortcutURL,
                scope: .shortcuts
            ),
        ])
        let monitor = makeMonitor(harness: harness)
        await monitor.start()

        let createdStamp = stamp(inode: 41)
        await harness.setStamp(createdStamp, for: protocolURL)
        await monitor.handleFileSystemEvent()
        await monitor.flushPendingRefresh()

        await harness.setStamp(
            stamp(
                inode: 42,
                size: createdStamp.size,
                seconds: createdStamp.modificationSeconds,
                nanoseconds: createdStamp.modificationNanoseconds
            ),
            for: protocolURL
        )
        await monitor.handleFileSystemEvent()
        await monitor.flushPendingRefresh()

        await harness.setStamp(.missing, for: protocolURL)
        await monitor.handleFileSystemEvent()
        await monitor.flushPendingRefresh()

        let requests = await harness.requests()
        #expect(requests.count == 4)
        #expect(requests.dropFirst().allSatisfy {
            $0 == WineBridgeRefreshRequest(
                scope: .protocols,
                mode: .incremental
            )
        })
        let metrics = await monitor.snapshot().metrics
        #expect(metrics.protocolInvalidations == 3)
        #expect(metrics.shortcutInvalidations == 0)

        await monitor.shutdown()
    }

    @Test("a successful scoped refresh replaces only its observed URLs")
    func refreshUpdatesDynamicDependencies() async {
        let oldURL = URL(fileURLWithPath: "/virtual/old/protocols.reg")
        let newURL = URL(fileURLWithPath: "/virtual/new/protocols.reg")
        let shortcutURL = URL(fileURLWithPath: "/virtual/shared/game.lnk")
        let harness = WineBridgeRefreshHarness()
        await harness.setStamp(stamp(inode: 1), for: oldURL)
        await harness.setStamp(stamp(inode: 2), for: newURL)
        await harness.setStamp(stamp(inode: 3), for: shortcutURL)
        await harness.setDependencies([
            WineBridgeObservedDependency(
                url: oldURL,
                scope: .protocols
            ),
            WineBridgeObservedDependency(
                url: shortcutURL,
                scope: .shortcuts
            ),
        ])
        let monitor = makeMonitor(harness: harness)
        await monitor.start()

        await harness.setDependencies([
            WineBridgeObservedDependency(
                url: newURL,
                scope: .protocols
            ),
        ])
        await monitor.invalidate(.protocols)
        await monitor.flushPendingRefresh()

        #expect(await monitor.snapshot().observedDependencies == [
            WineBridgeObservedDependency(
                url: newURL,
                scope: .protocols
            ),
            WineBridgeObservedDependency(
                url: shortcutURL,
                scope: .shortcuts
            ),
        ])

        await harness.setStamp(stamp(inode: 101), for: oldURL)
        await monitor.probeObservedDependencies()
        await monitor.flushPendingRefresh()
        #expect(await harness.requestCount() == 2)

        await harness.setStamp(stamp(inode: 202), for: newURL)
        await monitor.probeObservedDependencies()
        await monitor.flushPendingRefresh()
        #expect(await harness.requestCount() == 3)
        #expect(await harness.requests().last == WineBridgeRefreshRequest(
            scope: .protocols,
            mode: .incremental
        ))

        await monitor.shutdown()
    }

    @Test("a shared URL retains an independent stamp for each scope")
    func sharedDependencyUsesPerScopeStamps() async {
        let sharedURL = URL(
            fileURLWithPath: "/virtual/prefix/shared-manifest.json"
        )
        let harness = WineBridgeRefreshHarness()
        await harness.setStamp(stamp(inode: 1), for: sharedURL)
        await harness.setDependencies([
            WineBridgeObservedDependency(
                url: sharedURL,
                scope: .all
            )
        ])
        let monitor = makeMonitor(harness: harness)
        await monitor.start()

        await harness.setStamp(stamp(inode: 2), for: sharedURL)
        await monitor.invalidate(.protocols)
        await monitor.flushPendingRefresh()
        await monitor.flushPendingRefresh()

        #expect(await harness.requests() == [
            WineBridgeRefreshRequest(
                scope: .all,
                mode: .incremental
            ),
            WineBridgeRefreshRequest(
                scope: .protocols,
                mode: .incremental
            ),
            WineBridgeRefreshRequest(
                scope: .shortcuts,
                mode: .incremental
            ),
        ])
        #expect(await monitor.snapshot().observedDependencies == [
            WineBridgeObservedDependency(
                url: sharedURL,
                scope: .all
            )
        ])
        let metrics = await monitor.snapshot().metrics
        #expect(metrics.protocolInvalidations == 1)
        #expect(metrics.shortcutInvalidations == 1)

        await monitor.shutdown()
    }

    @Test("an unchanged stamp does not retry a persistent refresh error")
    func refreshErrorsDoNotHotLoop() async {
        let dependencyURL = URL(
            fileURLWithPath: "/virtual/prefix/protocols.reg"
        )
        let harness = WineBridgeRefreshHarness()
        await harness.setStamp(stamp(inode: 1), for: dependencyURL)
        await harness.setDependencies([
            WineBridgeObservedDependency(
                url: dependencyURL,
                scope: .protocols
            )
        ])
        let monitor = makeMonitor(harness: harness)
        await monitor.start()

        await harness.setShouldFail(true)
        await harness.setStamp(stamp(inode: 2), for: dependencyURL)
        await monitor.handleFileSystemEvent()
        await monitor.flushPendingRefresh()
        await monitor.handleFileSystemEvent()
        await monitor.flushPendingRefresh()

        #expect(await harness.requestCount() == 2)
        let snapshot = await monitor.snapshot()
        #expect(
            snapshot.lastRefreshErrorDescription?
                .contains("refreshFailed") == true
        )
        #expect(snapshot.pendingScope.isEmpty)
        #expect(!snapshot.isRefreshInFlight)

        await monitor.shutdown()
    }

    @Test("unchanged file events replace per-second bridge polling")
    func unchangedFileEventsDoNotRefresh() async {
        let dependencyURL = URL(
            fileURLWithPath: "/virtual/prefix/protocols.reg"
        )
        let harness = WineBridgeRefreshHarness()
        await harness.setStamp(stamp(inode: 1), for: dependencyURL)
        await harness.setDependencies([
            WineBridgeObservedDependency(
                url: dependencyURL,
                scope: .all
            )
        ])
        let counters = PerformanceCounters()
        let monitor = makeMonitor(
            harness: harness,
            counters: counters
        )
        await monitor.start()

        for _ in 0..<60 {
            await monitor.handleFileSystemEvent()
        }
        await monitor.flushPendingRefresh()

        #expect(await harness.requestCount() == 1)
        #expect(counters.snapshot()[.protocolBridgeRefreshes] == 1)
        #expect(counters.snapshot()[.shortcutBridgeRefreshes] == 1)
        #expect(await monitor.snapshot().metrics.refreshExecutions == 1)

        await monitor.shutdown()
    }

    @Test("the slow timer performs a forced all-scope safety refresh")
    func safetyTimerForcesRefresh() async throws {
        let clock = WineBridgeRefreshManualClock()
        let harness = WineBridgeRefreshHarness()
        let counters = PerformanceCounters()
        let monitor = makeMonitor(
            harness: harness,
            counters: counters,
            configuration: WineBridgeRefreshMonitorConfiguration(
                coalescingInterval: 0.2,
                safetyResyncInterval: 45
            ),
            sleep: { try await clock.sleep(for: $0) }
        )
        await monitor.start()
        try await waitUntil {
            clock.requestedIntervals().contains(45)
        }

        clock.advance(by: 44)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await harness.requestCount() == 1)

        clock.advance(by: 1)
        try await waitUntil {
            await harness.requestCount() == 2
        }

        #expect(await harness.requests().last == WineBridgeRefreshRequest(
            scope: .all,
            mode: .forcedSafety
        ))
        let metrics = await monitor.snapshot().metrics
        #expect(metrics.refreshExecutions == 2)
        #expect(metrics.safetyResyncs == 1)
        #expect(counters.snapshot()[.protocolBridgeRefreshes] == 2)
        #expect(counters.snapshot()[.shortcutBridgeRefreshes] == 2)
        #expect(counters.snapshot()[.bridgeSafetyResyncs] == 1)

        await monitor.shutdown()
        #expect(clock.pendingSleepCount() == 0)
    }

    @Test("cancelling a queued invalidation does not count an execution")
    func cancelledQueueDoesNotIncrementExecutionCounters() async throws {
        let clock = WineBridgeRefreshManualClock()
        let harness = WineBridgeRefreshHarness()
        let counters = PerformanceCounters()
        let monitor = makeMonitor(
            harness: harness,
            counters: counters,
            configuration: WineBridgeRefreshMonitorConfiguration(
                coalescingInterval: 0.2,
                safetyResyncInterval: 45
            ),
            sleep: { try await clock.sleep(for: $0) }
        )
        await monitor.start()
        await monitor.invalidate(.protocols)
        try await waitUntil {
            clock.requestedIntervals().contains(0.2)
        }

        await monitor.shutdown()

        #expect(await harness.requestCount() == 1)
        #expect(counters.snapshot()[.protocolBridgeRefreshes] == 1)
        #expect(counters.snapshot()[.shortcutBridgeRefreshes] == 1)
        #expect(counters.snapshot()[.bridgeSafetyResyncs] == 0)
        #expect(await monitor.snapshot().metrics.refreshExecutions == 1)
        #expect(clock.pendingSleepCount() == 0)
    }

    @Test("shutdown cancels and joins an in-flight refresh")
    func shutdownLeavesNoRefreshTaskBehind() async throws {
        let harness = WineBridgeRefreshHarness()
        let monitor = makeMonitor(harness: harness)
        await monitor.start()
        harness.blockRefreshes()

        await monitor.invalidate(.protocols)
        let refreshTask = Task {
            await monitor.flushPendingRefresh()
        }
        try await waitUntil {
            await harness.requestCount() == 2
        }

        await monitor.shutdown()
        await refreshTask.value

        let snapshot = await monitor.snapshot()
        #expect(!snapshot.isRunning)
        #expect(!snapshot.isRefreshInFlight)
        #expect(snapshot.pendingScope.isEmpty)
        #expect(snapshot.observedDependencies.isEmpty)
        #expect(harness.cancelledWaiterCount() == 1)
        #expect(await harness.activeRefreshCount() == 0)

        await monitor.invalidate(.all)
        await monitor.performSafetyResyncNow()
        #expect(await harness.requestCount() == 2)
    }
}

@Suite("Wine Bridge File Digest Cache")
struct WineBridgeFileDigestCacheTests {
    @Test("reuses a digest only while stable file identity is unchanged")
    func stableIdentityCacheHitAndAtomicReplacementMiss() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "switchyard-bridge-digest-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceURL = root.appendingPathComponent("Shortcut.ico")
        let replacementURL = root.appendingPathComponent("replacement.ico")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("first-icon".utf8).write(to: sourceURL)

        let counters = PerformanceCounters()
        let cache = WineBridgeFileDigestCache(counters: counters)
        let first = try await cache.sha256Hex(of: sourceURL)
        let second = try await cache.sha256Hex(of: sourceURL)

        #expect(first == second)
        #expect(counters.snapshot()[.bridgeDigestCacheHits] == 1)

        try Data("other-icon".utf8).write(to: replacementURL)
        try fileManager.removeItem(at: sourceURL)
        try fileManager.moveItem(at: replacementURL, to: sourceURL)

        let replaced = try await cache.sha256Hex(of: sourceURL)
        #expect(replaced != first)
        #expect(counters.snapshot()[.bridgeDigestCacheHits] == 1)
    }

    @Test("does not follow symbolic links")
    func symbolicLinkIsRejected() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "switchyard-bridge-digest-link-\(UUID().uuidString)",
            isDirectory: true
        )
        let targetURL = root.appendingPathComponent("target")
        let linkURL = root.appendingPathComponent("link")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("target".utf8).write(to: targetURL)
        try fileManager.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        let cache = WineBridgeFileDigestCache()
        var rejected = false
        do {
            _ = try await cache.sha256Hex(of: linkURL)
        } catch {
            rejected = true
        }
        #expect(rejected)
    }
}

@Suite("Wine Bridge File Events")
struct WineBridgeFileEventSourceTests {
    @Test("reports an in-place dependency write without periodic polling")
    func reportsDependencyWrite() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "switchyard-bridge-events-\(UUID().uuidString)",
            isDirectory: true
        )
        let dependencyURL = root.appendingPathComponent("protocols.reg")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("before".utf8).write(to: dependencyURL)

        let recorder = WineBridgeFileEventRecorder()
        let source = WineBridgeFileEventSource {
            recorder.record()
        }
        source.update(dependencyURLs: [dependencyURL])
        try Data("after".utf8).write(to: dependencyURL)

        for _ in 0..<200 where recorder.count == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        source.shutdown()
        #expect(recorder.count > 0)
    }
}

@MainActor
@Suite("Wine Bridge Refresh Dependencies")
struct WineBridgeRefreshDependencyTests {
    @Test("tracks manifests, runtime, runner, and learned routes before inputs exist")
    func tracksBaselineInputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "switchyard-bridge-dependencies-\(UUID().uuidString)",
                isDirectory: true
            )
        let prefixURL = root.appendingPathComponent(
            "Test.container",
            isDirectory: true
        )
        let wineURL = root.appendingPathComponent("wine")
        let runnerURL = root.appendingPathComponent("switchyard-runner")
        let protocolRootURL = root.appendingPathComponent(
            "ProtocolBridge",
            isDirectory: true
        )
        let container = Container(
            name: "Test",
            path: prefixURL.path
        )

        let desktopBridge = WineDesktopShortcutBridge(
            rootURL: root.appendingPathComponent("DesktopBridge"),
            desktopURL: root.appendingPathComponent("Desktop")
        )
        let prepared = try desktopBridge.prepareRefresh(
            containers: [container],
            winePath: wineURL.path,
            runnerPath: runnerURL.path
        )
        #expect(prepared.digestURLs.isEmpty)
        #expect(prepared.observedDependencyURLs == [
            WineDesktopShortcutFormat.manifestURL(
                prefixPath: prefixURL.path
            ).standardizedFileURL,
            wineURL.standardizedFileURL,
            runnerURL.standardizedFileURL,
        ])

        let protocolBridge = WineProtocolBridge(
            rootURL: protocolRootURL
        )
        #expect(
            protocolBridge.observedDependencyURLs(
                containers: [container],
                winePath: wineURL.path,
                runnerPath: runnerURL.path
            ) == [
                WineProtocolAssociationFormat.manifestURL(
                    prefixPath: prefixURL.path
                ).standardizedFileURL,
                protocolRootURL.appendingPathComponent(
                    "learned-associations-v1.json"
                ).standardizedFileURL,
                wineURL.standardizedFileURL,
                runnerURL.standardizedFileURL,
            ]
        )
    }
}

private enum WineBridgeRefreshTestError: Error {
    case refreshFailed
    case conditionWasNotMet
}

private actor WineBridgeRefreshHarness {
    private var dependencyStamps: [URL: WineBridgeFileStamp] = [:]
    private var dependencies: [WineBridgeObservedDependency] = []
    private var recordedRequests: [WineBridgeRefreshRequest] = []
    private var shouldFail = false
    private var activeRefreshes = 0
    private var maximumActiveRefreshes = 0
    private let gate = WineBridgeRefreshGate()

    nonisolated func blockRefreshes() {
        gate.block()
    }

    nonisolated func releaseRefreshes() {
        gate.release()
    }

    nonisolated func cancelledWaiterCount() -> Int {
        gate.cancelledCount()
    }

    func setDependencies(
        _ dependencies: [WineBridgeObservedDependency]
    ) {
        self.dependencies = dependencies
    }

    func setStamp(
        _ stamp: WineBridgeFileStamp,
        for url: URL
    ) {
        dependencyStamps[url.standardizedFileURL] = stamp
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func requests() -> [WineBridgeRefreshRequest] {
        recordedRequests
    }

    func requestCount() -> Int {
        recordedRequests.count
    }

    func activeRefreshCount() -> Int {
        activeRefreshes
    }

    func maximumConcurrentRefreshes() -> Int {
        maximumActiveRefreshes
    }

    func stamp(at url: URL) -> WineBridgeFileStamp {
        dependencyStamps[url.standardizedFileURL, default: .missing]
    }

    func refresh(
        _ request: WineBridgeRefreshRequest
    ) async throws -> WineBridgeRefreshResult {
        recordedRequests.append(request)
        activeRefreshes += 1
        maximumActiveRefreshes = max(
            maximumActiveRefreshes,
            activeRefreshes
        )
        defer {
            activeRefreshes -= 1
        }

        try await gate.waitIfBlocked()
        if shouldFail {
            throw WineBridgeRefreshTestError.refreshFailed
        }
        return WineBridgeRefreshResult(
            observedDependencies: dependencies
        )
    }
}

private final class WineBridgeRefreshGate: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var isBlocked = false
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var cancellationCount = 0

    func block() {
        lock.withLock {
            isBlocked = true
        }
    }

    func release() {
        let continuations = lock.withLock {
            isBlocked = false
            let continuations = waiters.values.map(\.continuation)
            waiters.removeAll()
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func waitIfBlocked() async throws {
        let shouldWait = lock.withLock { isBlocked }
        guard shouldWait else {
            try Task.checkCancellation()
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let shouldCancel = lock.withLock {
                    if cancelledBeforeRegistration.remove(id) != nil {
                        return true
                    }
                    if !isBlocked {
                        return false
                    }
                    waiters[id] = Waiter(continuation: continuation)
                    return false
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                } else if lock.withLock({ !isBlocked && waiters[id] == nil }) {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    func cancelledCount() -> Int {
        lock.withLock { cancellationCount }
    }

    private func cancel(_ id: UUID) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            cancellationCount += 1
            if let waiter = waiters.removeValue(forKey: id) {
                return waiter.continuation
            }
            cancelledBeforeRegistration.insert(id)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class WineBridgeRefreshManualClock: @unchecked Sendable {
    private struct SleepRequest {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentTime: TimeInterval = 0
    private var sleepRequests: [UUID: SleepRequest] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var intervals: [TimeInterval] = []

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

private final class WineBridgeFileEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock {
            value += 1
        }
    }
}

private func makeMonitor(
    harness: WineBridgeRefreshHarness,
    counters: PerformanceCounters = PerformanceCounters(),
    configuration: WineBridgeRefreshMonitorConfiguration =
        WineBridgeRefreshMonitorConfiguration(),
    sleep: @escaping WineBridgeRefreshMonitor.Sleep = { interval in
        try await Task.sleep(for: .seconds(max(0, interval)))
    }
) -> WineBridgeRefreshMonitor {
    WineBridgeRefreshMonitor(
        configuration: configuration,
        counters: counters,
        sleep: sleep,
        stamp: { url in
            await harness.stamp(at: url)
        },
        refresh: { request in
            try await harness.refresh(request)
        }
    )
}

private func stamp(
    device: UInt64 = 7,
    inode: UInt64,
    size: UInt64 = 512,
    seconds: Int64 = 1_000,
    nanoseconds: Int64 = 123
) -> WineBridgeFileStamp {
    WineBridgeFileStamp(
        exists: true,
        device: device,
        inode: inode,
        size: size,
        modificationSeconds: seconds,
        modificationNanoseconds: nanoseconds,
        changeSeconds: seconds,
        changeNanoseconds: nanoseconds
    )
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
    throw WineBridgeRefreshTestError.conditionWasNotMet
}
