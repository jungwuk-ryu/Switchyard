import AppCore
import CoreGraphics
import Foundation
import Testing
@testable import Switchyard

@Suite("Window Observation Hub")
struct WindowObservationHubTests {
    @Test(
        "coalesces global content enumeration across callers",
        .timeLimit(.minutes(1))
    )
    func coalescesContentEnumeration() async throws {
        let firstCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let secondCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 2, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 101,
                    generation: "first",
                    windowID: 1,
                    capture: firstCapture
                ),
                makeSource(
                    processID: 202,
                    generation: "second",
                    windowID: 2,
                    capture: secondCapture
                ),
            ]
        )
        await provider.blockEnumerations()
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)

        let first = Task {
            try await hub.observeWindows(
                ownedBy: [101],
                previewLimit: 0
            )
        }
        await provider.waitForEnumerationCount(1)
        let second = Task {
            try await hub.observeWindows(
                ownedBy: [202],
                previewLimit: 0
            )
        }
        try await waitUntil {
            counters.snapshot()[.windowObservationRequests] == 2
        }

        #expect(await provider.enumerationCount() == 1)
        await provider.releaseEnumerations()
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult.map(\.descriptor.ownerProcessID) == [101])
        #expect(secondResult.map(\.descriptor.ownerProcessID) == [202])
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 2)
        #expect(metrics[.windowContentEnumerations] == 1)
        #expect(metrics[.windowCaptureExecutions] == 0)
        await hub.shutdown()
    }

    @Test(
        "content cache expires exactly at its TTL",
        .timeLimit(.minutes(1))
    )
    func contentTTL() async throws {
        let clock = WindowObservationTestClock(now: 40)
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 101,
                    generation: "process",
                    windowID: 1,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(
            provider: provider,
            counters: counters,
            clock: clock,
            contentTTL: 1
        )

        _ = try await hub.observeWindows(ownedBy: [101], previewLimit: 0)
        _ = try await hub.observeWindows(ownedBy: [101], previewLimit: 0)
        clock.advance(by: 1)
        _ = try await hub.observeWindows(ownedBy: [101], previewLimit: 0)

        #expect(await provider.enumerationCount() == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 3)
        #expect(metrics[.windowContentEnumerations] == 2)
        await hub.shutdown()
    }

    @Test(
        "coalesces identical in-flight captures",
        .timeLimit(.minutes(1))
    )
    func coalescesIdenticalCapture() async throws {
        let expected = makeCapturedImage(width: 3, byteCost: 12)
        let capture = WindowCaptureFake(outcomes: [.success(expected)])
        await capture.blockCaptures()
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 303,
                    generation: "process",
                    windowID: 33,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)

        let first = Task {
            try await hub.observeWindows(ownedBy: [303])
        }
        await capture.waitForCaptureCount(1)
        let second = Task {
            try await hub.observeWindows(ownedBy: [303])
        }
        try await waitUntil {
            counters.snapshot()[.windowCaptureCoalescedRequests] == 1
        }

        #expect(await capture.captureCount() == 1)
        await capture.releaseCaptures()
        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult.first?.image != nil)
        #expect(secondResult.first?.image != nil)
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 2)
        #expect(metrics[.windowContentEnumerations] == 1)
        #expect(metrics[.windowCaptureExecutions] == 1)
        #expect(metrics[.windowCaptureCacheHits] == 0)
        #expect(metrics[.windowCaptureCoalescedRequests] == 1)
        await hub.shutdown()
    }

    @Test(
        "capture cache hits and byte eviction have exact counters",
        .timeLimit(.minutes(1))
    )
    func cacheHitsAndByteEviction() async throws {
        let firstCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let secondCapture = WindowCaptureFake(
            outcomes: [
                .success(makeCapturedImage(width: 2, byteCost: 4)),
                .success(makeCapturedImage(width: 2, byteCost: 4)),
            ]
        )
        let thirdCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 3, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 1,
                    generation: "a",
                    windowID: 11,
                    capture: firstCapture
                ),
                makeSource(
                    processID: 2,
                    generation: "b",
                    windowID: 22,
                    capture: secondCapture
                ),
                makeSource(
                    processID: 3,
                    generation: "c",
                    windowID: 33,
                    capture: thirdCapture
                ),
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(
            provider: provider,
            counters: counters,
            captureByteLimit: 8
        )

        _ = try await hub.observeWindows(ownedBy: [1])
        _ = try await hub.observeWindows(ownedBy: [2])
        _ = try await hub.observeWindows(ownedBy: [1])
        _ = try await hub.observeWindows(ownedBy: [3])
        _ = try await hub.observeWindows(ownedBy: [1])
        _ = try await hub.observeWindows(ownedBy: [2])

        #expect(await firstCapture.captureCount() == 1)
        #expect(await secondCapture.captureCount() == 2)
        #expect(await thirdCapture.captureCount() == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 6)
        #expect(metrics[.windowContentEnumerations] == 1)
        #expect(metrics[.windowCaptureExecutions] == 4)
        #expect(metrics[.windowCaptureCacheHits] == 2)
        #expect(metrics[.windowCaptureCoalescedRequests] == 0)
        #expect(metrics[.windowCaptureEvictedBytes] == 8)
        await hub.shutdown()
    }

    @Test(
        "capture cache expires exactly at its TTL",
        .timeLimit(.minutes(1))
    )
    func captureTTL() async throws {
        let clock = WindowObservationTestClock(now: 12)
        let capture = WindowCaptureFake(
            outcomes: [
                .success(makeCapturedImage(width: 1, byteCost: 4)),
                .success(makeCapturedImage(width: 2, byteCost: 4)),
            ]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 101,
                    generation: "process",
                    windowID: 1,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(
            provider: provider,
            counters: counters,
            clock: clock,
            captureTTL: 1
        )

        let first = try await hub.observeWindows(ownedBy: [101])
        let cached = try await hub.observeWindows(ownedBy: [101])
        clock.advance(by: 1)
        let refreshed = try await hub.observeWindows(ownedBy: [101])

        #expect(first.first?.image?.width == 1)
        #expect(cached.first?.image?.width == 1)
        #expect(refreshed.first?.image?.width == 2)
        #expect(await capture.captureCount() == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.windowCaptureExecutions] == 2)
        #expect(metrics[.windowCaptureCacheHits] == 1)
        await hub.shutdown()
    }

    @Test(
        "preferred off-screen windows keep metadata without new capture",
        .timeLimit(.minutes(1))
    )
    func offscreenPreferredWindowDoesNotCapture() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 404,
                    generation: "process",
                    windowID: 44,
                    isOnScreen: false,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)

        let result = try await hub.observeWindows(
            ownedBy: [404],
            preferredWindowID: 44,
            previewLimit: 0
        )

        #expect(result.count == 1)
        #expect(result.first?.descriptor.isOnScreen == false)
        #expect(result.first?.image == nil)
        #expect(await capture.captureCount() == 0)
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 1)
        #expect(metrics[.windowContentEnumerations] == 1)
        #expect(metrics[.windowCaptureExecutions] == 0)
        #expect(metrics[.windowCaptureCacheHits] == 0)
        await hub.shutdown()
    }

    @Test(
        "off-screen metadata does not consume the preview capture budget",
        .timeLimit(.minutes(1))
    )
    func offscreenWindowsDoNotConsumePreviewBudget() async throws {
        let offscreenCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let onscreenCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 2, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 404,
                    generation: "process",
                    windowID: 44,
                    isOnScreen: false,
                    capture: offscreenCapture
                ),
                makeSource(
                    processID: 404,
                    generation: "process",
                    windowID: 45,
                    isOnScreen: true,
                    capture: onscreenCapture
                ),
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)

        let result = try await hub.observeWindows(
            ownedBy: [404],
            previewLimit: 1
        )

        #expect(result.map(\.descriptor.windowID) == [44, 45])
        #expect(result[0].image == nil)
        #expect(result[1].image?.width == 2)
        #expect(await offscreenCapture.captureCount() == 0)
        #expect(await onscreenCapture.captureCount() == 1)
        #expect(counters.snapshot()[.windowCaptureExecutions] == 1)
        await hub.shutdown()
    }

    @Test(
        "process and window identifier reuse cannot reuse an old capture",
        .timeLimit(.minutes(1))
    )
    func processAndWindowReuseIsolation() async throws {
        let originalCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let reusedCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 2, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 505,
                    generation: "launch-a",
                    windowID: 55,
                    capture: originalCapture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(
            provider: provider,
            counters: counters,
            contentTTL: 0
        )

        let original = try await hub.observeWindows(ownedBy: [505])
        await provider.setSources([
            makeSource(
                processID: 505,
                generation: "launch-b",
                windowID: 55,
                capture: reusedCapture
            )
        ])
        let reused = try await hub.observeWindows(ownedBy: [505])

        #expect(original.first?.image?.width == 1)
        #expect(reused.first?.image?.width == 2)
        #expect(await originalCapture.captureCount() == 1)
        #expect(await reusedCapture.captureCount() == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.windowContentEnumerations] == 2)
        #expect(metrics[.windowCaptureExecutions] == 2)
        #expect(metrics[.windowCaptureCacheHits] == 0)
        await hub.shutdown()
    }

    @Test(
        "capture failure clears in-flight state for retry",
        .timeLimit(.minutes(1))
    )
    func captureFailureClearsInFlight() async throws {
        let capture = WindowCaptureFake(
            outcomes: [
                .failure,
                .success(makeCapturedImage(width: 2, byteCost: 4)),
            ]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 606,
                    generation: "process",
                    windowID: 66,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)

        let failed = try await hub.observeWindows(ownedBy: [606])
        let retried = try await hub.observeWindows(ownedBy: [606])

        #expect(failed.first?.image == nil)
        #expect(retried.first?.image?.width == 2)
        #expect(await capture.captureCount() == 2)
        let metrics = counters.snapshot()
        #expect(metrics[.windowCaptureExecutions] == 2)
        #expect(metrics[.windowCaptureCacheHits] == 0)
        #expect(metrics[.windowCaptureCoalescedRequests] == 0)
        await hub.shutdown()
    }

    @Test(
        "cancelling one waiter does not cancel a shared capture",
        .timeLimit(.minutes(1))
    )
    func waiterCancellationDoesNotCancelSharedCapture() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 4, byteCost: 16))]
        )
        await capture.blockCaptures()
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 707,
                    generation: "process",
                    windowID: 77,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)

        let cancelledWaiter = Task {
            try await hub.observeWindows(ownedBy: [707])
        }
        await capture.waitForCaptureCount(1)
        let survivingWaiter = Task {
            try await hub.observeWindows(ownedBy: [707])
        }
        try await waitUntil {
            counters.snapshot()[.windowCaptureCoalescedRequests] == 1
        }
        cancelledWaiter.cancel()
        await capture.releaseCaptures()

        let cancelledResult = try await cancelledWaiter.value
        let survivingResult = try await survivingWaiter.value

        #expect(cancelledResult.first?.image?.width == 4)
        #expect(survivingResult.first?.image?.width == 4)
        #expect(await capture.captureCount() == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.windowCaptureExecutions] == 1)
        #expect(metrics[.windowCaptureCoalescedRequests] == 1)
        await hub.shutdown()
    }

    @Test(
        "content invalidation rejects a stale in-flight completion",
        .timeLimit(.minutes(1))
    )
    func contentInvalidationRejectsStaleCompletion() async throws {
        let oldCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let newCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 2, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 808,
                    generation: "old",
                    windowID: 81,
                    capture: oldCapture
                )
            ]
        )
        await provider.blockEnumerations()
        let hub = makeHub(provider: provider, counters: PerformanceCounters())

        let staleRequest = Task {
            try await hub.observeWindows(ownedBy: [808], previewLimit: 0)
        }
        await provider.waitForEnumerationCount(1)
        await hub.invalidateContent()
        await provider.setSources([
            makeSource(
                processID: 808,
                generation: "new",
                windowID: 82,
                capture: newCapture
            )
        ])
        await provider.releaseEnumerations()

        await #expect(throws: CancellationError.self) {
            try await staleRequest.value
        }
        let refreshed = try await hub.observeWindows(
            ownedBy: [808],
            previewLimit: 0
        )
        #expect(refreshed.map(\.descriptor.windowID) == [82])
        #expect(await provider.enumerationCount() == 2)
        await hub.shutdown()
    }

    @Test(
        "capture invalidation rejects and does not recache stale work",
        .timeLimit(.minutes(1))
    )
    func captureInvalidationRejectsStaleCompletion() async throws {
        let capture = WindowCaptureFake(
            outcomes: [
                .success(makeCapturedImage(width: 1, byteCost: 4)),
                .success(makeCapturedImage(width: 2, byteCost: 4)),
            ]
        )
        await capture.blockCaptures()
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 909,
                    generation: "process",
                    windowID: 91,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)

        let staleRequest = Task {
            try await hub.observeWindows(ownedBy: [909])
        }
        await capture.waitForCaptureCount(1)
        await hub.removeAllCachedCaptures()
        await capture.releaseCaptures()
        let staleResult = try await staleRequest.value
        #expect(staleResult.first?.image == nil)

        let refreshed = try await hub.observeWindows(ownedBy: [909])
        #expect(refreshed.first?.image?.width == 2)
        #expect(await capture.captureCount() == 2)
        #expect(counters.snapshot()[.windowCaptureCacheHits] == 0)
        await hub.shutdown()
    }
}

private enum WindowObservationHubTestError: Error {
    case captureFailed
    case conditionWasNotMet
}

private actor WindowContentProviderFake {
    private var sources: [WindowObservationSource]
    private var count = 0
    private var shouldBlock = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(sources: [WindowObservationSource]) {
        self.sources = sources
    }

    func enumerate() async throws -> [WindowObservationSource] {
        count += 1
        resumeCountWaiters()
        if shouldBlock {
            await withCheckedContinuation { continuation in
                blocked.append(continuation)
            }
        }
        return sources
    }

    func setSources(_ sources: [WindowObservationSource]) {
        self.sources = sources
    }

    func blockEnumerations() {
        shouldBlock = true
    }

    func releaseEnumerations() {
        shouldBlock = false
        let continuations = blocked
        blocked.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForEnumerationCount(_ target: Int) async {
        if count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func enumerationCount() -> Int {
        count
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { $0.target <= count }
        countWaiters.removeAll { $0.target <= count }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor WindowCaptureFake {
    enum Outcome: Sendable {
        case success(WindowObservationCapturedImage)
        case failure
    }

    private var outcomes: [Outcome]
    private var count = 0
    private var shouldBlock = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func capture(
        profile _: WindowObservationOutputProfile
    ) async throws -> WindowObservationCapturedImage {
        count += 1
        resumeCountWaiters()
        if shouldBlock {
            await withCheckedContinuation { continuation in
                blocked.append(continuation)
            }
        }
        guard !outcomes.isEmpty else {
            throw WindowObservationHubTestError.captureFailed
        }
        switch outcomes.removeFirst() {
        case let .success(image):
            return image
        case .failure:
            throw WindowObservationHubTestError.captureFailed
        }
    }

    func blockCaptures() {
        shouldBlock = true
    }

    func releaseCaptures() {
        shouldBlock = false
        let continuations = blocked
        blocked.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitForCaptureCount(_ target: Int) async {
        if count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func captureCount() -> Int {
        count
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { $0.target <= count }
        countWaiters.removeAll { $0.target <= count }
        ready.forEach { $0.continuation.resume() }
    }
}

private final class WindowObservationTestClock:
    WindowObservationClock,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var currentTime: TimeInterval

    init(now: TimeInterval) {
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

private func makeHub(
    provider: WindowContentProviderFake,
    counters: PerformanceCounters,
    clock: any WindowObservationClock = WindowObservationTestClock(now: 0),
    contentTTL: TimeInterval = 10,
    captureTTL: TimeInterval = 10,
    captureByteLimit: Int = 1_024
) -> WindowObservationHub {
    WindowObservationHub(
        configuration: WindowObservationHubConfiguration(
            contentTTL: contentTTL,
            captureTTL: captureTTL,
            captureByteLimit: captureByteLimit
        ),
        counters: counters,
        clock: clock,
        contentProvider: {
            try await provider.enumerate()
        }
    )
}

private func makeSource(
    processID: pid_t,
    generation: String,
    windowID: CGWindowID,
    frame: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600),
    isOnScreen: Bool = true,
    capture: WindowCaptureFake
) -> WindowObservationSource {
    WindowObservationSource(
        descriptor: WindowObservationDescriptor(
            windowID: windowID,
            processIdentity: WindowObservationProcessIdentity(
                processID: processID,
                generation: generation
            ),
            title: "Window \(windowID)",
            frame: frame,
            isOnScreen: isOnScreen,
            layer: 0
        ),
        captureSource: WindowObservationCaptureSource { profile in
            try await capture.capture(profile: profile)
        }
    )
}

private func makeCapturedImage(
    width: Int,
    byteCost: Int
) -> WindowObservationCapturedImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return WindowObservationCapturedImage(
        image: context!.makeImage()!,
        byteCost: byteCost
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
    throw WindowObservationHubTestError.conditionWasNotMet
}
