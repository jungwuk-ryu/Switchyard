import AppCore
import Foundation
import Testing
@testable import Switchyard

@Suite("Container Index Service")
struct ContainerIndexServiceTests {
    @Test(
        "coalesces concurrent requests for the same identity and scope",
        .timeLimit(.minutes(1))
    )
    func coalescesSameScope() async throws {
        let request = makeRequest(path: "/containers/A")
        let programs = [makeProgram(name: "Game")]
        let gate = ContainerIndexScannerGate<[InstalledProgram]>(value: programs)
        let counters = PerformanceCounters()
        let service = makeService(
            counters: counters,
            installedPrograms: { request in
                try await gate.scan(request)
            }
        )

        let first = Task {
            try await service.snapshot(for: request, scopes: .installedPrograms)
        }
        await gate.waitForScanCount(1)
        let second = Task {
            try await service.snapshot(for: request, scopes: .installedPrograms)
        }
        try await waitUntilContainerIndex {
            counters.snapshot()[.containerIndexCoalescedRequests] == 1
        }

        await gate.release()
        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value

        #expect(firstSnapshot.installedPrograms == programs)
        #expect(secondSnapshot.installedPrograms == programs)
        #expect(await gate.scanCount == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.containerIndexRequests] == 2)
        #expect(metrics[.containerIndexScans] == 1)
        #expect(metrics[.containerIndexCoalescedRequests] == 1)
    }

    @Test(
        "overlapping forced refreshes bypass cache without cancelling their shared scan",
        .timeLimit(.minutes(1))
    )
    func overlappingForcedRefreshesCoalesce() async throws {
        let request = makeRequest()
        let gate = ContainerIndexScannerGate<[InstalledProgram]>(
            value: [makeProgram()]
        )
        let counters = PerformanceCounters()
        let service = makeService(
            counters: counters,
            installedPrograms: { request in
                try await gate.scan(request)
            }
        )

        let installerMonitor = Task {
            try await service.snapshot(
                for: request,
                scopes: .installedPrograms,
                bypassCache: true
            )
        }
        await gate.waitForScanCount(1)
        let manualRefresh = Task {
            try await service.snapshot(
                for: request,
                scopes: .installedPrograms,
                bypassCache: true
            )
        }
        try await waitUntilContainerIndex {
            counters.snapshot()[.containerIndexCoalescedRequests] == 1
        }

        await gate.release()
        #expect(try await installerMonitor.value.installedPrograms == [makeProgram()])
        #expect(try await manualRefresh.value.installedPrograms == [makeProgram()])
        #expect(await gate.scanCount == 1)
        #expect(counters.snapshot()[.containerIndexScans] == 1)
    }

    @Test("reuses fresh cached values and expires them at the TTL boundary")
    func cachedHitAndTTL() async throws {
        let request = makeRequest()
        let clock = ContainerIndexTestClock(now: 100)
        let counts = ContainerIndexCallCounts()
        let counters = PerformanceCounters()
        let service = makeService(
            configuration: ContainerIndexConfiguration(
                installedProgramsTTL: 2,
                startMenuEntriesTTL: 2,
                storageByteCountTTL: 2,
                bridgeMetadataTTL: 2,
                storageScanConcurrencyLimit: 2
            ),
            counters: counters,
            clock: clock,
            installedPrograms: { _ in
                let call = await counts.increment(.installedPrograms)
                return [makeProgram(name: "Game \(call)")]
            }
        )

        let first = try await service.snapshot(
            for: request,
            scopes: .installedPrograms
        )
        let second = try await service.snapshot(
            for: request,
            scopes: .installedPrograms
        )
        clock.advance(by: 2)
        let third = try await service.snapshot(
            for: request,
            scopes: .installedPrograms
        )

        #expect(first.installedPrograms == second.installedPrograms)
        #expect(first.installedPrograms != third.installedPrograms)
        #expect(await counts.value(for: .installedPrograms) == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.containerIndexRequests] == 3)
        #expect(metrics[.containerIndexScans] == 2)
        #expect(metrics[.containerIndexCacheHits] == 1)
    }

    @Test("invalidates only the requested scopes")
    func scopedInvalidation() async throws {
        let request = makeRequest()
        let counts = ContainerIndexCallCounts()
        let service = makeService(
            installedPrograms: { _ in
                let call = await counts.increment(.installedPrograms)
                return [makeProgram(name: "Program \(call)")]
            },
            startMenuEntries: { _ in
                _ = await counts.increment(.startMenuEntries)
                return [makeStartMenuEntry()]
            }
        )

        let first = try await service.snapshot(
            for: request,
            scopes: [.installedPrograms, .startMenuEntries]
        )
        await service.invalidate(
            request.identity,
            scopes: .installedPrograms
        )
        let second = try await service.snapshot(
            for: request,
            scopes: [.installedPrograms, .startMenuEntries]
        )

        #expect(first.installedPrograms != second.installedPrograms)
        #expect(first.startMenuEntries == second.startMenuEntries)
        #expect(await counts.value(for: .installedPrograms) == 2)
        #expect(await counts.value(for: .startMenuEntries) == 1)
    }

    @Test(
        "rejects stale in-flight results after invalidation",
        .timeLimit(.minutes(1))
    )
    func invalidationRejectsStaleCompletion() async throws {
        let request = makeRequest()
        let scanner = ContainerIndexInvalidationScanner()
        let service = makeService(
            installedPrograms: { request in
                try await scanner.scan(request)
            }
        )

        let staleRequest = Task {
            try await service.snapshot(
                for: request,
                scopes: .installedPrograms
            )
        }
        await scanner.waitForScanCount(1)
        await service.invalidate(
            request.identity,
            scopes: .installedPrograms
        )

        let fresh = try await service.snapshot(
            for: request,
            scopes: .installedPrograms
        )
        await scanner.releaseFirstScan()
        await #expect(throws: CancellationError.self) {
            try await staleRequest.value
        }
        let cached = try await service.snapshot(
            for: request,
            scopes: .installedPrograms
        )

        #expect(fresh.installedPrograms == [makeProgram(name: "Fresh")])
        #expect(cached.installedPrograms == fresh.installedPrograms)
        #expect(await scanner.scanCount == 2)
    }

    @Test("default request identity ignores unrelated manifest timestamps")
    func defaultIdentityIsStableAcrossLastModifiedChanges() {
        let containerID = UUID()
        let first = ContainerIndexRequest(
            container: Container(
                id: containerID,
                name: "Game",
                path: "/containers/A",
                lastModified: Date(timeIntervalSinceReferenceDate: 1)
            )
        )
        let second = ContainerIndexRequest(
            container: Container(
                id: containerID,
                name: "Renamed in UI",
                path: "/containers/A",
                lastModified: Date(timeIntervalSinceReferenceDate: 9_999)
            )
        )

        #expect(first.identity == second.identity)
    }

    @Test(
        "a moved or deleted container rejects stale scans and prunes old identity state",
        .timeLimit(.minutes(1))
    )
    func movedAndDeletedContainerRejectStaleScans() async throws {
        let containerID = UUID()
        let scanner = ContainerIndexInvalidationScanner()
        let counters = PerformanceCounters()
        let service = makeService(
            counters: counters,
            installedPrograms: { request in
                try await scanner.scan(request)
            }
        )
        let oldRequest = makeRequest(
            id: containerID,
            path: "/containers/Old",
            revision: "stable"
        )
        let movedRequest = makeRequest(
            id: containerID,
            path: "/containers/New",
            revision: "stable"
        )

        let staleMove = Task {
            try await service.snapshot(
                for: oldRequest,
                scopes: .installedPrograms
            )
        }
        await scanner.waitForScanCount(1)
        let moved = try await service.snapshot(
            for: movedRequest,
            scopes: .installedPrograms
        )
        await scanner.releaseFirstScan()
        await #expect(throws: CancellationError.self) {
            try await staleMove.value
        }
        #expect(moved.installedPrograms == [makeProgram(name: "Fresh")])
        #expect(await service.knownIdentityCount(for: containerID) == 1)

        await service.invalidate(containerID: containerID)
        #expect(await service.knownIdentityCount(for: containerID) == 0)
        let afterDelete = try await service.snapshot(
            for: movedRequest,
            scopes: .installedPrograms
        )
        #expect(afterDelete.installedPrograms == [makeProgram(name: "Fresh")])
        #expect(await scanner.scanCount == 3)
        #expect(counters.snapshot()[.containerIndexScans] == 3)
    }

    @Test("isolates path and revision identities while normalizing path spelling")
    func pathAndRevisionIsolation() async throws {
        let containerID = UUID()
        let counts = ContainerIndexCallCounts()
        let service = makeService(
            installedPrograms: { request in
                _ = await counts.increment(.installedPrograms)
                return [makeProgram(name: request.identity.path)]
            }
        )
        let normalized = makeRequest(
            id: containerID,
            path: "/containers/Library/A",
            revision: "1"
        )
        let alternateSpelling = makeRequest(
            id: containerID,
            path: "/containers/Library/../Library/A",
            revision: "1"
        )
        let moved = makeRequest(
            id: containerID,
            path: "/containers/Library/B",
            revision: "1"
        )
        let revised = makeRequest(
            id: containerID,
            path: "/containers/Library/B",
            revision: "2"
        )

        let first = try await service.snapshot(
            for: normalized,
            scopes: .installedPrograms
        )
        let equivalent = try await service.snapshot(
            for: alternateSpelling,
            scopes: .installedPrograms
        )
        let movedSnapshot = try await service.snapshot(
            for: moved,
            scopes: .installedPrograms
        )
        let revisedSnapshot = try await service.snapshot(
            for: revised,
            scopes: .installedPrograms
        )

        #expect(normalized.identity == alternateSpelling.identity)
        #expect(first.installedPrograms == equivalent.installedPrograms)
        #expect(first.installedPrograms != movedSnapshot.installedPrograms)
        #expect(movedSnapshot.identity != revisedSnapshot.identity)
        #expect(await counts.value(for: .installedPrograms) == 3)
    }

    @Test(
        "overlapping scope requests reuse individual in-flight pieces",
        .timeLimit(.minutes(1))
    )
    func overlappingScopesReusePieces() async throws {
        let request = makeRequest()
        let programsGate = ContainerIndexScannerGate<[InstalledProgram]>(
            value: [makeProgram()]
        )
        let startMenuGate = ContainerIndexScannerGate<[WindowsStartMenuEntry]>(
            value: [makeStartMenuEntry()]
        )
        let counts = ContainerIndexCallCounts()
        let counters = PerformanceCounters()
        let service = makeService(
            counters: counters,
            installedPrograms: { request in
                try await programsGate.scan(request)
            },
            startMenuEntries: { request in
                try await startMenuGate.scan(request)
            },
            storageByteCount: { _ in
                _ = await counts.increment(.storageByteCount)
                return 4_096
            }
        )

        let first = Task {
            try await service.snapshot(
                for: request,
                scopes: [.installedPrograms, .startMenuEntries]
            )
        }
        await programsGate.waitForScanCount(1)
        await startMenuGate.waitForScanCount(1)
        let second = Task {
            try await service.snapshot(
                for: request,
                scopes: [.startMenuEntries, .storageByteCount]
            )
        }
        try await waitUntilContainerIndex {
            let storageCount = await counts.value(for: .storageByteCount)
            return counters.snapshot()[.containerIndexCoalescedRequests] == 1
                && storageCount == 1
        }

        await programsGate.release()
        await startMenuGate.release()
        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value

        #expect(firstSnapshot.installedPrograms == [makeProgram()])
        #expect(firstSnapshot.startMenuEntries == [makeStartMenuEntry()])
        #expect(secondSnapshot.installedPrograms == nil)
        #expect(secondSnapshot.startMenuEntries == [makeStartMenuEntry()])
        #expect(secondSnapshot.storageByteCount == 4_096)
        #expect(await programsGate.scanCount == 1)
        #expect(await startMenuGate.scanCount == 1)
        #expect(counters.snapshot()[.containerIndexScans] == 3)
    }

    @Test(
        "limits storage scans globally without blocking other scopes",
        .timeLimit(.minutes(1))
    )
    func storageConcurrencyLimit() async throws {
        let storageProbe = ContainerIndexStorageProbe()
        let counts = ContainerIndexCallCounts()
        let counters = PerformanceCounters()
        let service = makeService(
            configuration: ContainerIndexConfiguration(
                installedProgramsTTL: 5,
                startMenuEntriesTTL: 5,
                storageByteCountTTL: 30,
                bridgeMetadataTTL: 1,
                storageScanConcurrencyLimit: 2
            ),
            counters: counters,
            installedPrograms: { _ in
                _ = await counts.increment(.installedPrograms)
                return [makeProgram()]
            },
            storageByteCount: { request in
                try await storageProbe.scan(request)
            }
        )
        let requests = (0..<5).map {
            makeRequest(path: "/containers/\($0)")
        }
        let storageTasks = requests.map { request in
            Task {
                try await service.snapshot(
                    for: request,
                    scopes: .storageByteCount
                )
            }
        }

        await storageProbe.waitForStartedCount(2)
        #expect(await storageProbe.maximumConcurrentCount == 2)
        #expect(await storageProbe.startedCount == 2)

        let programs = try await service.snapshot(
            for: makeRequest(path: "/containers/programs"),
            scopes: .installedPrograms
        )
        #expect(programs.installedPrograms == [makeProgram()])
        #expect(await counts.value(for: .installedPrograms) == 1)
        #expect(await storageProbe.startedCount == 2)

        await storageProbe.release()
        for task in storageTasks {
            _ = try await task.value
        }

        #expect(await storageProbe.maximumConcurrentCount == 2)
        #expect(await storageProbe.startedCount == 5)
        let metrics = counters.snapshot()
        #expect(metrics[.containerStorageScans] == 5)
        #expect(metrics[.containerIndexScans] == 6)
    }

    @Test(
        "a cancelled queued storage request returns its permit to the next scan",
        .timeLimit(.minutes(1))
    )
    func cancelledQueuedStorageRequestReleasesTransferredPermit() async throws {
        let storageProbe = ContainerIndexStorageProbe()
        let counters = PerformanceCounters()
        let service = makeService(
            configuration: ContainerIndexConfiguration(
                installedProgramsTTL: 5,
                startMenuEntriesTTL: 5,
                storageByteCountTTL: 30,
                bridgeMetadataTTL: 1,
                storageScanConcurrencyLimit: 1
            ),
            counters: counters,
            storageByteCount: { request in
                try await storageProbe.scan(request)
            }
        )
        let activeRequest = makeRequest(path: "/containers/active")
        let deletedRequest = makeRequest(path: "/containers/deleted")
        let active = Task {
            try await service.snapshot(
                for: activeRequest,
                scopes: .storageByteCount
            )
        }
        await storageProbe.waitForStartedCount(1)
        let deleted = Task {
            try await service.snapshot(
                for: deletedRequest,
                scopes: .storageByteCount
            )
        }
        try await waitUntilContainerIndex {
            let waiterCount = await service.storageWaiterCount()
            return counters.snapshot()[.containerStorageScans] == 2
                && waiterCount == 1
        }

        await service.invalidate(
            containerID: deletedRequest.identity.containerID
        )
        // Release the active scan immediately, without waiting for the
        // cancellation handler to remove the queued waiter. This covers the
        // race where release transfers the permit to an already-cancelled task.
        await storageProbe.release()
        _ = try await active.value
        await #expect(throws: CancellationError.self) {
            try await deleted.value
        }

        let followUpRequest = makeRequest(path: "/containers/follow-up")
        let followUp = Task {
            try await service.snapshot(
                for: followUpRequest,
                scopes: .storageByteCount
            )
        }
        do {
            try await waitUntilContainerIndex {
                await storageProbe.startedCount == 2
            }
        } catch {
            await service.invalidate(
                containerID: followUpRequest.identity.containerID
            )
            _ = await followUp.result
            throw error
        }
        #expect(
            try await followUp.value.storageByteCount
                == Int64(followUpRequest.identity.path.utf8.count)
        )

        #expect(await storageProbe.startedCount == 2)
        #expect(await service.storageWaiterCount() == 0)
        #expect(
            await service.knownIdentityCount(
                for: deletedRequest.identity.containerID
            ) == 0
        )
    }

    @Test("retries after a failed scan without poisoning the cache")
    func failureRetry() async throws {
        let request = makeRequest()
        let flaky = ContainerIndexFlakyScanner()
        let counters = PerformanceCounters()
        let service = makeService(
            counters: counters,
            bridgeMetadata: { request in
                try await flaky.scan(request)
            }
        )

        await #expect(throws: ContainerIndexTestError.scanFailed) {
            try await service.snapshot(for: request, scopes: .bridgeMetadata)
        }
        let recovered = try await service.snapshot(
            for: request,
            scopes: .bridgeMetadata
        )
        let cached = try await service.snapshot(
            for: request,
            scopes: .bridgeMetadata
        )

        #expect(recovered.bridgeMetadata?.protocolSchemes == ["switchyard"])
        #expect(cached.bridgeMetadata == recovered.bridgeMetadata)
        #expect(await flaky.scanCount == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.containerIndexScans] == 2)
        #expect(metrics[.containerIndexCacheHits] == 1)
    }

    @Test(
        "cancelling one waiter does not cancel the shared scan",
        .timeLimit(.minutes(1))
    )
    func waiterCancellationDoesNotCancelSharedScan() async throws {
        let request = makeRequest()
        let gate = ContainerIndexScannerGate<Int64>(value: 8_192)
        let counters = PerformanceCounters()
        let service = makeService(
            counters: counters,
            storageByteCount: { request in
                try await gate.scan(request)
            }
        )

        let cancelledWaiter = Task {
            try await service.snapshot(for: request, scopes: .storageByteCount)
        }
        await gate.waitForScanCount(1)
        let survivingWaiter = Task {
            try await service.snapshot(for: request, scopes: .storageByteCount)
        }
        try await waitUntilContainerIndex {
            counters.snapshot()[.containerIndexCoalescedRequests] == 1
        }

        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        #expect(await gate.scanCount == 1)

        await gate.release()
        let snapshot = try await survivingWaiter.value

        #expect(snapshot.storageByteCount == 8_192)
        #expect(await gate.scanCount == 1)
        #expect(counters.snapshot()[.containerStorageScans] == 1)
    }

    @Test(
        "protocol and shortcut consumers share one bridge metadata scan",
        .timeLimit(.minutes(1))
    )
    func bridgeConsumersShareMetadataScan() async throws {
        let request = makeRequest()
        let metadata = ContainerBridgeIndexMetadata(
            protocolSchemes: ["switchyard"],
            desktopShortcutEntries: [
                WineDesktopShortcutManifestEntry(
                    kind: .lnk,
                    displayName: "Game",
                    windowsShortcutPath: #"C:\Users\Test\Desktop\Game.lnk"#
                )
            ]
        )
        let gate = ContainerIndexScannerGate<ContainerBridgeIndexMetadata>(
            value: metadata
        )
        let counters = PerformanceCounters()
        let service = makeService(
            counters: counters,
            bridgeMetadata: { request in
                try await gate.scan(request)
            }
        )

        let protocolConsumer = Task {
            try await service.snapshot(for: request, scopes: .bridgeMetadata)
        }
        await gate.waitForScanCount(1)
        let shortcutConsumer = Task {
            try await service.snapshot(for: request, scopes: .bridgeMetadata)
        }
        try await waitUntilContainerIndex {
            counters.snapshot()[.containerIndexCoalescedRequests] == 1
        }

        await gate.release()
        let protocolSnapshot = try await protocolConsumer.value
        let shortcutSnapshot = try await shortcutConsumer.value

        #expect(protocolSnapshot.bridgeMetadata == metadata)
        #expect(shortcutSnapshot.bridgeMetadata == metadata)
        #expect(await gate.scanCount == 1)
        #expect(counters.snapshot()[.containerIndexScans] == 1)
    }

    @Test("live bridge scanner reads both manifests in one indexed scope")
    func liveBridgeScannerCombinesManifests() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(
                "switchyard-container-index-bridge-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: root) }
        let protocolManifestURL = WineProtocolAssociationFormat.manifestURL(
            prefixPath: root.path
        )
        let shortcutManifestURL = WineDesktopShortcutFormat.manifestURL(
            prefixPath: root.path
        )
        let windowsShortcutPath =
            #"C:\users\steamuser\Desktop\Indexed Game.url"#
        let shortcutURL = try #require(
            WineDesktopShortcutFormat.hostShortcutURL(
                windowsPath: windowsShortcutPath,
                prefixPath: root.path
            )
        )
        for url in [
            protocolManifestURL,
            shortcutManifestURL,
            shortcutURL,
        ] {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data(
            "\(WineProtocolAssociationFormat.manifestHeader)\nxdt\n".utf8
        ).write(to: protocolManifestURL)
        let encodedName = "Indexed Game".utf8.map {
            String(format: "%02x", $0)
        }.joined()
        let encodedPath = windowsShortcutPath.utf8.map {
            String(format: "%02x", $0)
        }.joined()
        try Data(
            """
            \(WineDesktopShortcutFormat.manifestHeader)
            url\t\(encodedName)\t\(encodedPath)\t
            """.utf8
        ).write(to: shortcutManifestURL)
        try Data("[InternetShortcut]\nURL=xdt://launch\n".utf8)
            .write(to: shortcutURL)
        let counters = PerformanceCounters()
        let service = ContainerIndexService(
            scanners: .live,
            counters: counters
        )
        let request = ContainerIndexRequest(
            container: Container(name: "Test", path: root.path)
        )

        let snapshot = try await service.snapshot(
            for: request,
            scopes: .bridgeMetadata
        )
        let metadata = try #require(snapshot.bridgeMetadata)

        #expect(metadata.protocolSchemes == ["xdt"])
        #expect(
            metadata.desktopShortcutEntries.map(\.windowsShortcutPath)
                == [windowsShortcutPath]
        )
        #expect(
            Set(metadata.dependencies.map(\.role))
                == [
                    .protocolManifest,
                    .desktopShortcutManifest,
                    .desktopShortcut,
                ]
        )
        #expect(counters.snapshot()[.containerIndexScans] == 1)
    }
}

private enum ContainerIndexTestError: Error, Equatable {
    case scanFailed
    case conditionWasNotMet
}

private enum ContainerIndexTestScope: Hashable {
    case installedPrograms
    case startMenuEntries
    case storageByteCount
    case bridgeMetadata
}

private actor ContainerIndexCallCounts {
    private var counts: [ContainerIndexTestScope: Int] = [:]

    @discardableResult
    func increment(_ scope: ContainerIndexTestScope) -> Int {
        counts[scope, default: 0] += 1
        return counts[scope, default: 0]
    }

    func value(for scope: ContainerIndexTestScope) -> Int {
        counts[scope, default: 0]
    }
}

private actor ContainerIndexScannerGate<Value: Sendable> {
    private let value: Value
    private var shouldBlock = true
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var scanCount = 0

    init(value: Value) {
        self.value = value
    }

    func scan(_ request: ContainerIndexRequest) async throws -> Value {
        _ = request
        scanCount += 1
        resumeCountWaiters()
        if shouldBlock {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        return value
    }

    func waitForScanCount(_ target: Int) async {
        if scanCount >= target {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func release() {
        shouldBlock = false
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { $0.target <= scanCount }
        countWaiters.removeAll { $0.target <= scanCount }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor ContainerIndexStorageProbe {
    private var shouldBlock = true
    private var currentCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startedCount = 0
    private(set) var maximumConcurrentCount = 0

    func scan(_ request: ContainerIndexRequest) async throws -> Int64 {
        startedCount += 1
        currentCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, currentCount)
        resumeCountWaiters()
        if shouldBlock {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        currentCount -= 1
        return Int64(request.identity.path.utf8.count)
    }

    func waitForStartedCount(_ target: Int) async {
        if startedCount >= target {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func release() {
        shouldBlock = false
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { $0.target <= startedCount }
        countWaiters.removeAll { $0.target <= startedCount }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor ContainerIndexFlakyScanner {
    private(set) var scanCount = 0

    func scan(
        _ request: ContainerIndexRequest
    ) async throws -> ContainerBridgeIndexMetadata {
        _ = request
        scanCount += 1
        if scanCount == 1 {
            throw ContainerIndexTestError.scanFailed
        }
        return ContainerBridgeIndexMetadata(
            protocolSchemes: ["switchyard"]
        )
    }
}

private actor ContainerIndexInvalidationScanner {
    private var shouldBlockFirstScan = true
    private var firstScanContinuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var scanCount = 0

    func scan(
        _ request: ContainerIndexRequest
    ) async throws -> [InstalledProgram] {
        _ = request
        scanCount += 1
        let currentScan = scanCount
        resumeCountWaiters()
        if currentScan == 1, shouldBlockFirstScan {
            await withCheckedContinuation { continuation in
                firstScanContinuations.append(continuation)
            }
        }
        return [
            makeProgram(name: currentScan == 1 ? "Stale" : "Fresh")
        ]
    }

    func waitForScanCount(_ target: Int) async {
        if scanCount >= target {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func releaseFirstScan() {
        shouldBlockFirstScan = false
        let pending = firstScanContinuations
        firstScanContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { $0.target <= scanCount }
        countWaiters.removeAll { $0.target <= scanCount }
        ready.forEach { $0.continuation.resume() }
    }
}

private final class ContainerIndexTestClock:
    ContainerIndexClock,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var currentTime: TimeInterval

    init(now: TimeInterval = 0) {
        currentTime = now
    }

    func now() -> TimeInterval {
        lock.withLock { currentTime }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            currentTime += interval
        }
    }
}

private func makeService(
    configuration: ContainerIndexConfiguration = ContainerIndexConfiguration(),
    counters: PerformanceCounters = PerformanceCounters(),
    clock: any ContainerIndexClock = ContainerIndexTestClock(),
    installedPrograms:
        @escaping ContainerIndexScanners.InstalledProgramsScanner = { _ in [] },
    startMenuEntries:
        @escaping ContainerIndexScanners.StartMenuEntriesScanner = { _ in [] },
    storageByteCount:
        @escaping ContainerIndexScanners.StorageByteCountScanner = { _ in 0 },
    bridgeMetadata:
        @escaping ContainerIndexScanners.BridgeMetadataScanner = {
            _ in ContainerBridgeIndexMetadata()
        }
) -> ContainerIndexService {
    ContainerIndexService(
        scanners: ContainerIndexScanners(
            installedPrograms: installedPrograms,
            startMenuEntries: startMenuEntries,
            storageByteCount: storageByteCount,
            bridgeMetadata: bridgeMetadata
        ),
        configuration: configuration,
        counters: counters,
        clock: clock
    )
}

private func makeRequest(
    id: UUID = UUID(),
    path: String = "/containers/Test",
    revision: String = "1"
) -> ContainerIndexRequest {
    ContainerIndexRequest(
        container: Container(
            id: id,
            name: "Test",
            path: path,
            lastModified: Date(timeIntervalSinceReferenceDate: 1)
        ),
        revision: revision
    )
}

private func makeProgram(name: String = "Game") -> InstalledProgram {
    InstalledProgram(
        name: name,
        executablePath: #"C:\Games\Game.exe"#,
        installDirectory: #"C:\Games"#,
        source: .programFiles
    )
}

private func makeStartMenuEntry() -> WindowsStartMenuEntry {
    WindowsStartMenuEntry(
        windowsShortcutPath:
            #"C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Game.lnk"#
    )!
}

private func waitUntilContainerIndex(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<10_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    throw ContainerIndexTestError.conditionWasNotMet
}
