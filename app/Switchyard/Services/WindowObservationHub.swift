import AppCore
import AppKit
import CoreGraphics
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

struct WindowObservationProcessIdentity: Hashable, Sendable {
    let processID: pid_t
    let generation: String
}

struct WindowObservationDescriptor: Equatable, Sendable {
    let windowID: CGWindowID
    let processIdentity: WindowObservationProcessIdentity
    let title: String?
    let frame: CGRect
    let isOnScreen: Bool
    let isActive: Bool
    let layer: Int

    var ownerProcessID: pid_t {
        processIdentity.processID
    }
}

enum WindowObservationOrdering {
    static func areInPreferredOrder(
        _ lhs: WindowObservationDescriptor,
        _ rhs: WindowObservationDescriptor
    ) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
        let lhsArea = lhs.frame.width * lhs.frame.height
        let rhsArea = rhs.frame.width * rhs.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        return lhs.windowID < rhs.windowID
    }
}

struct WindowObservationOutputProfile: Hashable, Sendable {
    static let preview = WindowObservationOutputProfile(
        identifier: "switchyard-preview-v1",
        maximumPixelWidth: 1_120,
        maximumPixelHeight: 760,
        maximumScale: 2
    )

    let identifier: String
    let maximumPixelWidth: Int
    let maximumPixelHeight: Int
    let maximumScale: Double

    init(
        identifier: String,
        maximumPixelWidth: Int,
        maximumPixelHeight: Int,
        maximumScale: Double
    ) {
        self.identifier = identifier
        self.maximumPixelWidth = max(1, maximumPixelWidth)
        self.maximumPixelHeight = max(1, maximumPixelHeight)
        self.maximumScale = max(0, maximumScale)
    }

    fileprivate func pixelSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return (
                width: min(maximumPixelWidth, 960),
                height: min(maximumPixelHeight, 600)
            )
        }

        let scale = min(
            maximumScale,
            min(
                Double(maximumPixelWidth) / sourceSize.width,
                Double(maximumPixelHeight) / sourceSize.height
            )
        )
        return (
            width: max(1, Int(floor(sourceSize.width * scale))),
            height: max(1, Int(floor(sourceSize.height * scale)))
        )
    }
}

struct WindowObservationCapturedImage: @unchecked Sendable {
    let image: CGImage
    let byteCost: Int

    init(image: CGImage, byteCost: Int? = nil) {
        self.image = image
        self.byteCost = max(1, byteCost ?? Self.byteCost(of: image))
    }

    private static func byteCost(of image: CGImage) -> Int {
        let (cost, overflowed) = image.bytesPerRow.multipliedReportingOverflow(
            by: image.height
        )
        return overflowed ? .max : cost
    }
}

struct WindowObservationCaptureSource: Sendable {
    private let operation:
        @Sendable (WindowObservationOutputProfile) async throws
            -> WindowObservationCapturedImage

    init(
        _ operation: @escaping
            @Sendable (WindowObservationOutputProfile) async throws
                -> WindowObservationCapturedImage
    ) {
        self.operation = operation
    }

    fileprivate func capture(
        profile: WindowObservationOutputProfile
    ) async throws -> WindowObservationCapturedImage {
        try await operation(profile)
    }
}

struct WindowObservationSource: Sendable {
    let descriptor: WindowObservationDescriptor
    let captureSource: WindowObservationCaptureSource
}

struct WindowObservation: @unchecked Sendable {
    let descriptor: WindowObservationDescriptor
    let image: CGImage?
}

private struct WindowObservationFrameIdentity: Hashable, Sendable {
    let x: UInt64
    let y: UInt64
    let width: UInt64
    let height: UInt64

    init(_ frame: CGRect) {
        x = Double(frame.origin.x).bitPattern
        y = Double(frame.origin.y).bitPattern
        width = Double(frame.size.width).bitPattern
        height = Double(frame.size.height).bitPattern
    }
}

struct WindowObservationIdentity: Hashable, Sendable {
    let processIdentity: WindowObservationProcessIdentity
    let windowID: CGWindowID
    private let frameIdentity: WindowObservationFrameIdentity

    init(
        processIdentity: WindowObservationProcessIdentity,
        windowID: CGWindowID,
        frame: CGRect
    ) {
        self.processIdentity = processIdentity
        self.windowID = windowID
        frameIdentity = WindowObservationFrameIdentity(frame)
    }
}

struct WindowObservationHubConfiguration: Sendable {
    var contentTTL: TimeInterval = 0.5
    var captureTTL: TimeInterval = 2.5
    var captureByteLimit: Int = 64 * 1_024 * 1_024
}

protocol WindowObservationClock: Sendable {
    func now() -> TimeInterval
}

private struct SystemWindowObservationClock: WindowObservationClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

actor WindowObservationHub {
    typealias ContentProvider =
        @Sendable () async throws -> [WindowObservationSource]

    static let shared = WindowObservationHub {
        try await ScreenCaptureKitWindowObservationAdapter.windows()
    }

    private struct Cached<Value: Sendable>: Sendable {
        let value: Value
        let observedAt: TimeInterval
    }

    private struct InFlight<Value: Sendable>: Sendable {
        let id: UUID
        let generation: UInt64
        let task: Task<Value, any Error>
    }

    private struct CaptureKey: Hashable, Sendable {
        let processIdentity: WindowObservationProcessIdentity
        let windowID: CGWindowID
        let frame: WindowObservationFrameIdentity
        let outputProfile: WindowObservationOutputProfile
    }

    private let contentProvider: ContentProvider
    private let configuration: WindowObservationHubConfiguration
    private let counters: PerformanceCounters
    private let clock: any WindowObservationClock

    private var cachedContent: Cached<[WindowObservationSource]>?
    private var lastNonemptyContent: [WindowObservationSource] = []
    private var contentTask: InFlight<[WindowObservationSource]>?
    private var contentGeneration: UInt64 = 0
    private var captureCache:
        CostBoundedCache<CaptureKey, Cached<WindowObservationCapturedImage>>
    private var captureTasks:
        [CaptureKey: InFlight<WindowObservationCapturedImage>] = [:]
    private var captureGeneration: UInt64 = 0

    init(
        configuration: WindowObservationHubConfiguration =
            WindowObservationHubConfiguration(),
        counters: PerformanceCounters = .shared,
        clock: any WindowObservationClock = SystemWindowObservationClock(),
        contentProvider: @escaping ContentProvider
    ) {
        self.configuration = configuration
        self.counters = counters
        self.clock = clock
        self.contentProvider = contentProvider
        captureCache = CostBoundedCache(
            costLimit: configuration.captureByteLimit
        )
    }

    func observeWindows(
        ownedBy processIDs: Set<pid_t>,
        preferredWindowID: CGWindowID? = nil,
        previewLimit: Int = 6,
        outputProfile: WindowObservationOutputProfile = .preview,
        forceContentRefresh: Bool = false,
        matching isIncluded:
            @escaping @Sendable (WindowObservationDescriptor) -> Bool = { _ in
                true
            }
    ) async throws -> [WindowObservation] {
        counters.increment(.windowObservationRequests)
        guard !processIDs.isEmpty else { return [] }

        let sources = try await content(
            forceRefresh: forceContentRefresh
        )
        let candidates = sources.filter {
            processIDs.contains($0.descriptor.ownerProcessID)
                && isIncluded($0.descriptor)
        }
        let boundedPreviewLimit = max(0, previewLimit)

        var observations: [WindowObservation] = []
        observations.reserveCapacity(candidates.count)
        var remainingPreviewCaptures = boundedPreviewLimit
        for source in candidates {
            let usesPreviewBudget = source.descriptor.isOnScreen
                && remainingPreviewCaptures > 0
            if usesPreviewBudget {
                remainingPreviewCaptures -= 1
            }
            let shouldCapture = usesPreviewBudget
                || source.descriptor.windowID == preferredWindowID
            let observedImage: CGImage?
            if shouldCapture {
                observedImage = await image(
                    for: source,
                    outputProfile: outputProfile
                )
            } else {
                observedImage = cachedImage(
                    for: source.descriptor,
                    outputProfile: outputProfile
                )
            }
            observations.append(
                WindowObservation(
                    descriptor: source.descriptor,
                    image: observedImage
                )
            )
        }
        return observations
    }

    func cachedObservations(
        matching identities: Set<WindowObservationIdentity>,
        outputProfile: WindowObservationOutputProfile = .preview
    ) -> [WindowObservation] {
        guard !identities.isEmpty else {
            return []
        }
        let sources: [WindowObservationSource]
        if let currentContent = cachedContent?.value,
           !currentContent.isEmpty {
            sources = currentContent
        } else {
            sources = lastNonemptyContent
        }

        return sources.compactMap { source in
            let descriptor = source.descriptor
            let identity = WindowObservationIdentity(
                processIdentity: descriptor.processIdentity,
                windowID: descriptor.windowID,
                frame: descriptor.frame
            )
            guard identities.contains(identity),
                  let image = cachedImage(
                      for: descriptor,
                      outputProfile: outputProfile
                  ) else {
                return nil
            }
            return WindowObservation(
                descriptor: descriptor,
                image: image
            )
        }
    }

    func invalidateContent() {
        contentGeneration &+= 1
        cachedContent = nil
        lastNonemptyContent.removeAll()
        contentTask?.task.cancel()
        contentTask = nil
    }

    func removeAllCachedCaptures() {
        captureGeneration &+= 1
        captureCache.removeAll(keepingCapacity: true)
        for inFlight in captureTasks.values {
            inFlight.task.cancel()
        }
        captureTasks.removeAll()
    }

    func shutdown() {
        contentGeneration &+= 1
        captureGeneration &+= 1
        contentTask?.task.cancel()
        contentTask = nil
        for inFlight in captureTasks.values {
            inFlight.task.cancel()
        }
        captureTasks.removeAll()
        cachedContent = nil
        lastNonemptyContent.removeAll()
        captureCache.removeAll()
    }

    private func content(
        forceRefresh: Bool
    ) async throws -> [WindowObservationSource] {
        if let inFlight = contentTask {
            return try await finishContent(inFlight)
        }

        let currentTime = clock.now()
        if !forceRefresh,
           let cachedContent,
           isFresh(
               cachedContent.observedAt,
               ttl: configuration.contentTTL,
               now: currentTime
           ) {
            return cachedContent.value
        }

        counters.increment(.windowContentEnumerations)
        let provider = contentProvider
        let inFlight = InFlight(
            id: UUID(),
            generation: contentGeneration,
            task: Task {
                try await provider()
            }
        )
        contentTask = inFlight
        return try await finishContent(inFlight)
    }

    private func finishContent(
        _ inFlight: InFlight<[WindowObservationSource]>
    ) async throws -> [WindowObservationSource] {
        do {
            let result = try await inFlight.task.value
            guard inFlight.generation == contentGeneration else {
                throw CancellationError()
            }
            if contentTask?.id == inFlight.id {
                contentTask = nil
                cachedContent = Cached(
                    value: result,
                    observedAt: clock.now()
                )
                if !result.isEmpty {
                    lastNonemptyContent = result
                }
            }
            return result
        } catch {
            if contentTask?.id == inFlight.id {
                contentTask = nil
            }
            throw error
        }
    }

    private func image(
        for source: WindowObservationSource,
        outputProfile: WindowObservationOutputProfile
    ) async -> CGImage? {
        let key = captureKey(
            for: source.descriptor,
            outputProfile: outputProfile
        )
        let cached = captureCache.value(forKey: key)
        let currentTime = clock.now()
        if let cached,
           isFresh(
               cached.observedAt,
               ttl: configuration.captureTTL,
               now: currentTime
           ) {
            counters.increment(.windowCaptureCacheHits)
            return cached.value.image
        }

        guard source.descriptor.isOnScreen else {
            return cached?.value.image
        }

        if let inFlight = captureTasks[key] {
            counters.increment(.windowCaptureCoalescedRequests)
            return await finishCapture(
                inFlight,
                for: key,
                staleImage: cached?.value.image
            )
        }

        counters.increment(.windowCaptureExecutions)
        let captureSource = source.captureSource
        let inFlight = InFlight(
            id: UUID(),
            generation: captureGeneration,
            task: Task {
                try await captureSource.capture(profile: outputProfile)
            }
        )
        captureTasks[key] = inFlight
        return await finishCapture(
            inFlight,
            for: key,
            staleImage: cached?.value.image
        )
    }

    private func finishCapture(
        _ inFlight: InFlight<WindowObservationCapturedImage>,
        for key: CaptureKey,
        staleImage: CGImage?
    ) async -> CGImage? {
        do {
            let captured = try await inFlight.task.value
            guard inFlight.generation == captureGeneration else {
                return nil
            }
            if captureTasks[key]?.id == inFlight.id {
                captureTasks.removeValue(forKey: key)
                let insertion = captureCache.insert(
                    Cached(
                        value: captured,
                        observedAt: clock.now()
                    ),
                    cost: captured.byteCost,
                    forKey: key
                )
                if insertion.evictedCost > 0 {
                    counters.increment(
                        .windowCaptureEvictedBytes,
                        by: UInt64(insertion.evictedCost)
                    )
                }
            }
            return captured.image
        } catch {
            guard inFlight.generation == captureGeneration else {
                return nil
            }
            if captureTasks[key]?.id == inFlight.id {
                captureTasks.removeValue(forKey: key)
            }
            return staleImage
        }
    }

    private func cachedImage(
        for descriptor: WindowObservationDescriptor,
        outputProfile: WindowObservationOutputProfile
    ) -> CGImage? {
        captureCache.valueWithoutUpdatingRecency(
            forKey: captureKey(
                for: descriptor,
                outputProfile: outputProfile
            )
        )?.value.image
    }

    private func captureKey(
        for descriptor: WindowObservationDescriptor,
        outputProfile: WindowObservationOutputProfile
    ) -> CaptureKey {
        CaptureKey(
            processIdentity: descriptor.processIdentity,
            windowID: descriptor.windowID,
            frame: WindowObservationFrameIdentity(descriptor.frame),
            outputProfile: outputProfile
        )
    }

    private func isFresh(
        _ observedAt: TimeInterval,
        ttl: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        let age = now - observedAt
        return age >= 0 && age < max(0, ttl)
    }
}

private final class ScreenCaptureKitWindowBox: @unchecked Sendable {
    let window: SCWindow

    init(_ window: SCWindow) {
        self.window = window
    }
}

private enum ScreenCaptureKitWindowObservationAdapter {
    @MainActor
    static func windows() async throws -> [WindowObservationSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        var processIdentities:
            [pid_t: WindowObservationProcessIdentity] = [:]

        return content.windows
            .compactMap { window -> WindowObservationSource? in
                guard let application = window.owningApplication else {
                    return nil
                }
                let processID = pid_t(application.processID)
                let processIdentity = processIdentities[processID] ?? {
                    let identity = WindowObservationProcessIdentity(
                        processID: processID,
                        generation: processGeneration(for: processID)
                    )
                    processIdentities[processID] = identity
                    return identity
                }()
                let descriptor = WindowObservationDescriptor(
                    windowID: window.windowID,
                    processIdentity: processIdentity,
                    title: window.title,
                    frame: window.frame,
                    isOnScreen: window.isOnScreen,
                    isActive: window.isActive,
                    layer: window.windowLayer
                )
                let box = ScreenCaptureKitWindowBox(window)
                return WindowObservationSource(
                    descriptor: descriptor,
                    captureSource: WindowObservationCaptureSource { profile in
                        try await capture(box.window, profile: profile)
                    }
                )
            }
            .sorted {
                WindowObservationOrdering.areInPreferredOrder(
                    $0.descriptor,
                    $1.descriptor
                )
            }
    }

    @MainActor
    private static func capture(
        _ window: SCWindow,
        profile: WindowObservationOutputProfile
    ) async throws -> WindowObservationCapturedImage {
        let outputSize = profile.pixelSize(for: window.frame.size)
        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.queueDepth = 1
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return WindowObservationCapturedImage(image: image)
    }

    private static func processGeneration(for processID: pid_t) -> String {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        if actualSize == expectedSize {
            return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
        }
        if let launchDate = NSRunningApplication(
            processIdentifier: processID
        )?.launchDate {
            return "launch:\(launchDate.timeIntervalSinceReferenceDate.bitPattern)"
        }
        return "enumeration:\(UUID().uuidString)"
    }
}
