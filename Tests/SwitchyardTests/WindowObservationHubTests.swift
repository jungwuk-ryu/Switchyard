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
        "default capture TTL spans a two-second preview poll",
        .timeLimit(.minutes(1))
    )
    func defaultCaptureTTLSpansPreviewPoll() async throws {
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
        let hub = WindowObservationHub(
            configuration: WindowObservationHubConfiguration(),
            counters: counters,
            clock: clock,
            contentProvider: {
                try await provider.enumerate()
            }
        )

        let first = try await hub.observeWindows(ownedBy: [101])
        clock.advance(by: 2)
        let secondPoll = try await hub.observeWindows(ownedBy: [101])
        clock.advance(by: 0.5)
        let expired = try await hub.observeWindows(ownedBy: [101])

        #expect(first.first?.image?.width == 1)
        #expect(secondPoll.first?.image?.width == 1)
        #expect(expired.first?.image?.width == 2)
        #expect(await provider.enumerationCount() == 3)
        #expect(await capture.captureCount() == 2)
        #expect(counters.snapshot()[.windowCaptureCacheHits] == 1)
        await hub.shutdown()
    }

    @Test(
        "capture services share enumeration and capture work",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func captureServicesShareHubWork() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 5, byteCost: 20))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 811,
                    generation: "process",
                    windowID: 81,
                    title: "Game",
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)
        let cardService = makeCaptureService(hub: hub)
        let stageService = makeCaptureService(hub: hub)

        let cardResult = await cardService.captureWindows(
            ownedBy: [811],
            previewLimit: 1
        )
        let stageResult = await stageService.captureWindows(
            ownedBy: [811],
            preferredWindowID: 81
        )

        let cardImage = try #require(cardResult.windows.first?.image)
        let stageImage = try #require(stageResult.windows.first?.image)
        #expect(cardImage === stageImage)
        #expect(await provider.enumerationCount() == 1)
        #expect(await capture.captureCount() == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.windowContentEnumerations] == 1)
        #expect(metrics[.windowCaptureExecutions] == 1)
        #expect(metrics[.windowCaptureCacheHits] == 1)
        await hub.shutdown()
    }

    @Test(
        "capture failure keeps a shared cached preview",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func captureFailureKeepsSharedCachedPreview() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 5, byteCost: 20))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 812,
                    generation: "process",
                    windowID: 87,
                    title: "Game",
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(
            provider: provider,
            counters: counters,
            contentTTL: 0
        )
        let matchingFallback = makeFallbackWindow(
            processID: 812,
            windowID: 87
        )
        let unmatchedFallback = makeFallbackWindow(
            processID: 812,
            windowID: 88
        )
        let service = makeCaptureService(
            hub: hub,
            coreGraphicsWindowsProvider: { _ in
                [matchingFallback, unmatchedFallback]
            }
        )

        let captured = await service.captureWindows(ownedBy: [812])
        let capturedImage = try #require(
            captured.windows.first?.image
        )
        await provider.failEnumerations()
        let fallback = await service.captureWindows(
            ownedBy: [812],
            forceContentRefresh: true
        )
        let fallbackImage = try #require(
            fallback.windows.first?.image
        )

        #expect(fallback.windows.map(\.id) == [87, 88])
        #expect(fallbackImage === capturedImage)
        #expect(fallback.windows[1].image == nil)
        #expect(!fallback.screenRecordingAccessUnavailable)
        #expect(await provider.enumerationCount() == 2)
        #expect(await capture.captureCount() == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 2)
        #expect(metrics[.windowContentEnumerations] == 2)
        #expect(metrics[.windowCaptureExecutions] == 1)
        await hub.shutdown()
    }

    @Test(
        "screen recording denial keeps a shared cached preview",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func screenRecordingDenialKeepsSharedCachedPreview() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 6, byteCost: 24))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 813,
                    generation: "process",
                    windowID: 89,
                    title: "Game",
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)
        let fallbackWindow = makeFallbackWindow(
            processID: 813,
            windowID: 89
        )
        var hasScreenRecordingAccess = true
        let service = makeCaptureService(
            hub: hub,
            screenRecordingPreflight: {
                hasScreenRecordingAccess
            },
            coreGraphicsWindowsProvider: { _ in
                [fallbackWindow]
            }
        )

        let captured = await service.captureWindows(ownedBy: [813])
        let capturedImage = try #require(
            captured.windows.first?.image
        )
        hasScreenRecordingAccess = false
        let fallback = await service.captureWindows(ownedBy: [813])
        let fallbackImage = try #require(
            fallback.windows.first?.image
        )

        #expect(fallbackImage === capturedImage)
        #expect(fallback.screenRecordingAccessUnavailable)
        #expect(await provider.enumerationCount() == 1)
        #expect(await capture.captureCount() == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 1)
        #expect(metrics[.windowContentEnumerations] == 1)
        #expect(metrics[.windowCaptureExecutions] == 1)
        await hub.shutdown()
    }

    @Test(
        "fallback images require matching process generation and frame",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func fallbackImagesRequireSafeIdentity() async throws {
        let capturedFrame = CGRect(
            x: 10,
            y: 20,
            width: 800,
            height: 600
        )
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 7, byteCost: 28))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 814,
                    generation: "original-process",
                    windowID: 95,
                    title: "Game",
                    frame: capturedFrame,
                    capture: capture
                )
            ]
        )
        let hub = makeHub(
            provider: provider,
            counters: PerformanceCounters()
        )
        let capturingService = makeCaptureService(
            hub: hub,
            processGeneration: "original-process"
        )

        let captured = await capturingService.captureWindows(
            ownedBy: [814]
        )
        #expect(captured.windows.first?.image?.width == 7)

        let frameMismatchService = makeCaptureService(
            hub: hub,
            screenRecordingPreflight: { false },
            processGeneration: "original-process",
            coreGraphicsWindowsProvider: { _ in
                [
                    makeFallbackWindow(
                        processID: 814,
                        windowID: 95,
                        frame: capturedFrame.offsetBy(dx: 1, dy: 0)
                    )
                ]
            }
        )
        let frameMismatch = await frameMismatchService.captureWindows(
            ownedBy: [814]
        )

        let processMismatchService = makeCaptureService(
            hub: hub,
            screenRecordingPreflight: { false },
            processGeneration: "reused-process",
            coreGraphicsWindowsProvider: { _ in
                [
                    makeFallbackWindow(
                        processID: 814,
                        windowID: 95,
                        frame: capturedFrame
                    )
                ]
            }
        )
        let processMismatch = await processMismatchService.captureWindows(
            ownedBy: [814]
        )

        #expect(frameMismatch.windows.first?.image == nil)
        #expect(processMismatch.windows.first?.image == nil)
        #expect(await provider.enumerationCount() == 1)
        #expect(await capture.captureCount() == 1)
        await hub.shutdown()
    }

    @Test(
        "successful empty observations reuse a safely matched cached preview",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func emptyObservationKeepsSafelyMatchedPreview() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 8, byteCost: 32))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 815,
                    generation: "process",
                    windowID: 96,
                    title: "Game",
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(
            provider: provider,
            counters: counters,
            contentTTL: 0
        )
        let fallbackWindow = makeFallbackWindow(
            processID: 815,
            windowID: 96
        )
        let service = makeCaptureService(
            hub: hub,
            coreGraphicsWindowsProvider: { _ in
                [fallbackWindow]
            }
        )

        let captured = await service.captureWindows(ownedBy: [815])
        let capturedImage = try #require(
            captured.windows.first?.image
        )
        await provider.setSources([])
        let fallback = await service.captureWindows(
            ownedBy: [815],
            forceContentRefresh: true
        )
        let fallbackImage = try #require(
            fallback.windows.first?.image
        )

        #expect(fallbackImage === capturedImage)
        #expect(!fallback.screenRecordingAccessUnavailable)
        #expect(await provider.enumerationCount() == 2)
        #expect(await capture.captureCount() == 1)
        let metrics = counters.snapshot()
        #expect(metrics[.windowObservationRequests] == 2)
        #expect(metrics[.windowContentEnumerations] == 2)
        #expect(metrics[.windowCaptureExecutions] == 1)
        await hub.shutdown()
    }

    @Test(
        "content invalidation clears retained fallback observations",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func contentInvalidationClearsRetainedFallbackObservations() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 9, byteCost: 36))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 817,
                    generation: "process",
                    windowID: 97,
                    title: "Game",
                    capture: capture
                )
            ]
        )
        let hub = makeHub(
            provider: provider,
            counters: PerformanceCounters()
        )
        let fallbackWindow = makeFallbackWindow(
            processID: 817,
            windowID: 97
        )
        var hasScreenRecordingAccess = true
        let service = makeCaptureService(
            hub: hub,
            screenRecordingPreflight: {
                hasScreenRecordingAccess
            },
            coreGraphicsWindowsProvider: { _ in
                [fallbackWindow]
            }
        )

        let captured = await service.captureWindows(ownedBy: [817])
        #expect(captured.windows.first?.image?.width == 9)
        await hub.invalidateContent()
        hasScreenRecordingAccess = false
        let fallback = await service.captureWindows(ownedBy: [817])

        #expect(fallback.windows.first?.image == nil)
        #expect(fallback.screenRecordingAccessUnavailable)
        #expect(await provider.enumerationCount() == 1)
        #expect(await capture.captureCount() == 1)
        await hub.shutdown()
    }

    @Test(
        "capture service keeps active-first window ordering",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func captureServiceKeepsActiveFirstOrdering() async {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 5, byteCost: 20))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 816,
                    generation: "process",
                    windowID: 94,
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: 1_200,
                        height: 900
                    ),
                    isOnScreen: false,
                    capture: capture
                ),
                makeSource(
                    processID: 816,
                    generation: "process",
                    windowID: 93,
                    capture: capture
                ),
                makeSource(
                    processID: 816,
                    generation: "process",
                    windowID: 90,
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: 320,
                        height: 180
                    ),
                    isOnScreen: false,
                    isActive: true,
                    capture: capture
                ),
                makeSource(
                    processID: 816,
                    generation: "process",
                    windowID: 92,
                    capture: capture
                ),
                makeSource(
                    processID: 816,
                    generation: "process",
                    windowID: 91,
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: 1_000,
                        height: 800
                    ),
                    capture: capture
                ),
            ]
        )
        let hub = makeHub(
            provider: provider,
            counters: PerformanceCounters()
        )
        let service = makeCaptureService(hub: hub)

        let result = await service.captureWindows(
            ownedBy: [816],
            previewLimit: 1
        )

        #expect(result.windows.map(\.id) == [90, 91, 92, 93, 94])
        #expect(result.windows.first?.isOnScreen == false)
        #expect(await capture.captureCount() == 1)
        await hub.shutdown()
    }

    @Test(
        "card fallback query reuses hub enumeration and prior captures",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func cardFallbackReusesHubWork() async throws {
        let genericCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let gameCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 2, byteCost: 8))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 822,
                    generation: "process",
                    windowID: 82,
                    title: "wine",
                    capture: genericCapture
                ),
                makeSource(
                    processID: 822,
                    generation: "process",
                    windowID: 83,
                    title: "Game",
                    capture: gameCapture
                ),
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)
        let service = makeCaptureService(hub: hub)

        var result = await service.captureWindows(
            ownedBy: [822],
            previewLimit: 1
        )
        #expect(
            ContainerPreviewWindowPolicy.preferredWindow(
                in: result.windows
            ) == nil
        )
        let candidate = try #require(
            ContainerPreviewWindowPolicy.preferredWindowCandidate(
                in: result.windows
            )
        )

        result = await service.captureWindows(
            ownedBy: [822],
            preferredWindowID: candidate.id,
            previewLimit: 1,
            forceContentRefresh: false
        )
        let preferred = try #require(
            ContainerPreviewWindowPolicy.preferredWindow(
                in: result.windows,
                selectedWindowID: candidate.id
            )
        )

        #expect(preferred.id == 83)
        #expect(preferred.image?.width == 2)
        #expect(await provider.enumerationCount() == 1)
        #expect(await genericCapture.captureCount() == 1)
        #expect(await gameCapture.captureCount() == 1)
        #expect(counters.snapshot()[.windowCaptureCacheHits] == 1)
        await hub.shutdown()
    }

    @Test(
        "capture service never captures an off-screen preferred window",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func captureServiceSuppressesOffscreenCapture() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 833,
                    generation: "process",
                    windowID: 84,
                    title: "Game",
                    isOnScreen: false,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)
        let service = makeCaptureService(hub: hub)

        let result = await service.captureWindows(
            ownedBy: [833],
            preferredWindowID: 84,
            previewLimit: 1
        )

        #expect(result.windows.map(\.id) == [84])
        #expect(result.windows.first?.image == nil)
        #expect(await capture.captureCount() == 0)
        #expect(counters.snapshot()[.windowCaptureExecutions] == 0)
        await hub.shutdown()
    }

    @Test(
        "observing another container does not evict cached captures",
        .timeLimit(.minutes(1))
    )
    @MainActor
    func captureServiceDoesNotPruneOtherContainerCache() async throws {
        let firstCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 1, byteCost: 4))]
        )
        let secondCapture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 2, byteCost: 8))]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 844,
                    generation: "first",
                    windowID: 85,
                    title: "First Game",
                    capture: firstCapture
                ),
                makeSource(
                    processID: 855,
                    generation: "second",
                    windowID: 86,
                    title: "Second Game",
                    capture: secondCapture
                ),
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(provider: provider, counters: counters)
        let firstService = makeCaptureService(hub: hub)
        let secondService = makeCaptureService(hub: hub)

        _ = await firstService.captureWindows(ownedBy: [844])
        _ = await secondService.captureWindows(ownedBy: [855])
        let firstAgain = await firstService.captureWindows(
            ownedBy: [844]
        )

        #expect(firstAgain.windows.first?.image?.width == 1)
        #expect(await provider.enumerationCount() == 1)
        #expect(await firstCapture.captureCount() == 1)
        #expect(await secondCapture.captureCount() == 1)
        #expect(counters.snapshot()[.windowCaptureCacheHits] == 1)
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
        "off-screen preferred windows do not join in-flight captures",
        .timeLimit(.minutes(1))
    )
    func offscreenPreferredWindowDoesNotJoinInFlight() async throws {
        let capture = WindowCaptureFake(
            outcomes: [.success(makeCapturedImage(width: 7, byteCost: 28))]
        )
        await capture.blockCaptures()
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 405,
                    generation: "process",
                    windowID: 46,
                    capture: capture
                )
            ]
        )
        let counters = PerformanceCounters()
        let hub = makeHub(
            provider: provider,
            counters: counters,
            contentTTL: 0
        )

        let onScreenRequest = Task {
            try await hub.observeWindows(
                ownedBy: [405],
                preferredWindowID: 46,
                previewLimit: 0
            )
        }
        await capture.waitForCaptureCount(1)
        await provider.setSources([
            makeSource(
                processID: 405,
                generation: "process",
                windowID: 46,
                isOnScreen: false,
                capture: capture
            )
        ])
        let completion = WindowObservationCompletionProbe()
        let offscreenRequest = Task {
            let result = try await hub.observeWindows(
                ownedBy: [405],
                preferredWindowID: 46,
                previewLimit: 0
            )
            await completion.finish()
            return result
        }
        try await waitUntil {
            if await completion.isFinished() {
                return true
            }
            return counters.snapshot()[
                .windowCaptureCoalescedRequests
            ] > 0
        }

        #expect(await completion.isFinished())
        #expect(
            counters.snapshot()[.windowCaptureCoalescedRequests] == 0
        )
        await capture.releaseCaptures()
        let offscreenResult = try await offscreenRequest.value
        let onScreenResult = try await onScreenRequest.value

        #expect(offscreenResult.first?.image == nil)
        #expect(onScreenResult.first?.image?.width == 7)
        #expect(await provider.enumerationCount() == 2)
        #expect(await capture.captureCount() == 1)
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
        "capture invalidation rejects a blocked failed completion",
        .timeLimit(.minutes(1))
    )
    func captureInvalidationRejectsBlockedFailure() async throws {
        let clock = WindowObservationTestClock(now: 0)
        let capture = WindowCaptureFake(
            outcomes: [
                .success(makeCapturedImage(width: 1, byteCost: 4)),
                .failure,
            ]
        )
        let provider = WindowContentProviderFake(
            sources: [
                makeSource(
                    processID: 908,
                    generation: "process",
                    windowID: 90,
                    capture: capture
                )
            ]
        )
        let hub = makeHub(
            provider: provider,
            counters: PerformanceCounters(),
            clock: clock,
            captureTTL: 1
        )

        let initial = try await hub.observeWindows(ownedBy: [908])
        #expect(initial.first?.image?.width == 1)
        clock.advance(by: 1)
        await capture.blockCaptures()
        let failedRequest = Task {
            try await hub.observeWindows(ownedBy: [908])
        }
        await capture.waitForCaptureCount(2)
        await hub.removeAllCachedCaptures()
        await capture.releaseCaptures()
        let failedResult = try await failedRequest.value

        #expect(failedResult.first?.image == nil)
        #expect(await capture.captureCount() == 2)
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
    private var shouldFail = false
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
        if shouldFail {
            throw WindowObservationHubTestError.captureFailed
        }
        return sources
    }

    func setSources(_ sources: [WindowObservationSource]) {
        self.sources = sources
    }

    func blockEnumerations() {
        shouldBlock = true
    }

    func failEnumerations() {
        shouldFail = true
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

private actor WindowObservationCompletionProbe {
    private var finished = false

    func finish() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
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
    title: String? = nil,
    frame: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600),
    isOnScreen: Bool = true,
    isActive: Bool = false,
    capture: WindowCaptureFake
) -> WindowObservationSource {
    WindowObservationSource(
        descriptor: WindowObservationDescriptor(
            windowID: windowID,
            processIdentity: WindowObservationProcessIdentity(
                processID: processID,
                generation: generation
            ),
            title: title ?? "Window \(windowID)",
            frame: frame,
            isOnScreen: isOnScreen,
            isActive: isActive,
            layer: 0
        ),
        captureSource: WindowObservationCaptureSource { profile in
            try await capture.capture(profile: profile)
        }
    )
}

@MainActor
private func makeCaptureService(
    hub: WindowObservationHub,
    screenRecordingPreflight: @escaping () -> Bool = { true },
    processGeneration: String = "process",
    coreGraphicsWindowsProvider:
        @escaping (Set<Int32>) -> [WineWindowSnapshot] = { _ in [] }
) -> WineWindowCaptureService {
    WineWindowCaptureService(
        screenRecordingPreflight: screenRecordingPreflight,
        windowObservationHub: hub,
        dockProcessIsVisible: { _ in true },
        coreGraphicsWindowsProvider: coreGraphicsWindowsProvider,
        processGenerationProvider: { _ in processGeneration },
        applicationIconDataProvider: { _ in nil }
    )
}

private func makeFallbackWindow(
    processID: pid_t,
    windowID: CGWindowID,
    frame: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600)
) -> WineWindowSnapshot {
    WineWindowSnapshot(
        id: windowID,
        ownerProcessID: processID,
        title: "Fallback \(windowID)",
        executablePath: nil,
        frame: frame,
        isOnScreen: true,
        image: nil
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
