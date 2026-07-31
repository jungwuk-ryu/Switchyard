import AppCore
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

struct WineWindowSnapshot: Identifiable, @unchecked Sendable {
    let id: CGWindowID
    let ownerProcessID: pid_t
    let title: String
    let executablePath: String?
    let frame: CGRect
    let isOnScreen: Bool
    let image: CGImage?
    let applicationIconData: Data?

    init(
        id: CGWindowID,
        ownerProcessID: pid_t,
        title: String,
        executablePath: String?,
        frame: CGRect,
        isOnScreen: Bool,
        image: CGImage?,
        applicationIconData: Data? = nil
    ) {
        self.id = id
        self.ownerProcessID = ownerProcessID
        self.title = title
        self.executablePath = executablePath
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.image = image
        self.applicationIconData = applicationIconData
    }

    var meaningfulTitle: String? {
        Self.meaningfulTitle(from: title)
    }

    var executableDisplayName: String? {
        guard let executablePath else { return nil }
        let normalizedPath = executablePath.replacingOccurrences(of: "\\", with: "/")
        guard var name = normalizedPath.split(separator: "/").last.map(String.init) else {
            return nil
        }
        if name.lowercased().hasSuffix(".exe") {
            name.removeLast(4)
        }
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !Self.genericTitleKeys.contains(Self.genericTitleKey(candidate)) else {
            return nil
        }
        return candidate
    }

    private static let genericTitleKeys: Set<String> = [
        "desktop",
        "explorer",
        "explorerexe",
        "programmanager",
        "steamwebhelper",
        "steamwebhelperexe",
        "wine",
        "wine64",
        "wine64preloader",
        "wineserver",
        "wineserverexe",
        "windowsapp",
        "windowssession",
        "xdt",
        "xdtexe",
    ]

    private static func genericTitleKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func meaningfulTitle(from value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !genericTitleKeys.contains(genericTitleKey(candidate)) else {
            return nil
        }
        return candidate
    }
}

struct WineWindowCaptureResult: @unchecked Sendable {
    var windows: [WineWindowSnapshot]
    var screenRecordingAccessUnavailable: Bool
    var message: String?

    static let empty = WineWindowCaptureResult(
        windows: [],
        screenRecordingAccessUnavailable: false,
        message: nil
    )

    static func screenRecordingUnavailable(
        windows: [WineWindowSnapshot]
    ) -> WineWindowCaptureResult {
        WineWindowCaptureResult(
            windows: windows,
            screenRecordingAccessUnavailable: true,
            message: String(
                localized: "Screen Recording access is unavailable. Check System Settings, then reopen Switchyard.",
                bundle: SwitchyardStrings.bundle
            )
        )
    }

    static func captureUnavailable(
        windows: [WineWindowSnapshot]
    ) -> WineWindowCaptureResult {
        WineWindowCaptureResult(
            windows: windows,
            screenRecordingAccessUnavailable: false,
            message: nil
        )
    }
}

enum WineWindowCloseResult: Equatable, Sendable {
    case requested
    case accessibilityPermissionRequired
    case staleWindow
    case ambiguousWindow
    case closeUnsupported
    case unresponsive
    case operationFailed
}

@MainActor
final class ScreenRecordingPermissionPromptGate {
    static let shared = ScreenRecordingPermissionPromptGate()

    private var hasRequestedPermission = false

    func requestIfNeeded(using request: () -> Bool) -> Bool {
        guard !hasRequestedPermission else { return false }
        hasRequestedPermission = true
        return request()
    }
}

struct WineAccessibilityWindowCandidate {
    let identifier: Int
    let title: String?
    let frame: CGRect?
    fileprivate let element: AXUIElement?

    init(
        identifier: Int,
        title: String?,
        frame: CGRect?,
        element: AXUIElement? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.frame = frame
        self.element = element
    }
}

enum WineAccessibilityWindowMatch: Equatable, Sendable {
    case matched(identifier: Int)
    case stale
    case ambiguous
}

enum WineAccessibilityWindowMatchPurpose: Equatable, Sendable {
    case activation
    case close
}

protocol WineWindowAccessibilityControlling: AnyObject, Sendable {
    var isProcessTrusted: Bool { get }

    func requestProcessTrust()
    func windows(for processID: pid_t) -> [WineAccessibilityWindowCandidate]?
    func raise(_ candidate: WineAccessibilityWindowCandidate)
    func close(_ candidate: WineAccessibilityWindowCandidate) -> WineWindowCloseResult
}

final class SystemWineWindowAccessibilityController:
    WineWindowAccessibilityControlling, @unchecked Sendable
{
    var isProcessTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestProcessTrust() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions(
            [promptKey: true] as CFDictionary
        )
    }

    func windows(for processID: pid_t) -> [WineAccessibilityWindowCandidate]? {
        let applicationElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(applicationElement, 1)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let accessibilityWindows = windowsValue as? [AXUIElement] else {
            return nil
        }

        return accessibilityWindows.enumerated().map { index, window in
            WineAccessibilityWindowCandidate(
                identifier: index,
                title: Self.title(for: window),
                frame: Self.frame(for: window),
                element: window
            )
        }
    }

    func raise(_ candidate: WineAccessibilityWindowCandidate) {
        guard let window = candidate.element else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
    }

    func close(
        _ candidate: WineAccessibilityWindowCandidate
    ) -> WineWindowCloseResult {
        guard let window = candidate.element else {
            return .staleWindow
        }

        var closeButtonValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &closeButtonValue
        )
        guard copyResult == .success else {
            return Self.closeResult(for: copyResult)
        }
        guard let closeButtonValue,
              CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID() else {
            return .closeUnsupported
        }
        let closeButton = unsafeDowncast(closeButtonValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(closeButton, 1)

        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            closeButton,
            kAXEnabledAttribute as CFString,
            &enabledValue
        ) == .success,
        let isEnabled = enabledValue as? Bool,
        !isEnabled {
            return .closeUnsupported
        }

        var actionNames: CFArray?
        let actionResult = AXUIElementCopyActionNames(closeButton, &actionNames)
        guard actionResult == .success else {
            return Self.closeResult(for: actionResult)
        }
        guard let actions = actionNames as? [String],
              actions.contains(kAXPressAction) else {
            return .closeUnsupported
        }

        return Self.closeResult(
            for: AXUIElementPerformAction(
                closeButton,
                kAXPressAction as CFString
            )
        )
    }

    private static func title(for window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func frame(for window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func closeResult(for error: AXError) -> WineWindowCloseResult {
        switch error {
        case .success:
            return .requested
        case .apiDisabled:
            return .accessibilityPermissionRequired
        case .attributeUnsupported, .actionUnsupported, .notImplemented,
             .parameterizedAttributeUnsupported, .noValue:
            return .closeUnsupported
        case .invalidUIElement, .invalidUIElementObserver:
            return .staleWindow
        case .cannotComplete:
            return .unresponsive
        default:
            return .operationFailed
        }
    }
}

private final class LegacyShareableContentProviderBox:
    @unchecked Sendable
{
    let operation: () async throws -> SCShareableContent

    init(
        _ operation: @escaping () async throws -> SCShareableContent
    ) {
        self.operation = operation
    }
}

private final class LegacyScreenCaptureKitWindowBox:
    @unchecked Sendable
{
    let window: SCWindow

    init(_ window: SCWindow) {
        self.window = window
    }
}

@MainActor
final class WineWindowCaptureService {
    private struct CachedApplicationIcon {
        var data: Data
        var capturedAt: Date
    }

    private var cachedExecutablePaths: [pid_t: String] = [:]
    private var cachedApplicationIcons: [pid_t: CachedApplicationIcon] = [:]
    private let windowObservationHub: WindowObservationHub
    private let screenRecordingPreflight: () -> Bool
    private let screenRecordingRequest: () -> Bool
    private let screenRecordingPermissionPromptGate:
        ScreenRecordingPermissionPromptGate
    private let screenRecordingSettingsOpener: () -> Void
    private let dockProcessIsVisible: (pid_t) -> Bool
    private let coreGraphicsWindowsProvider:
        ((Set<Int32>) -> [WineWindowSnapshot])?
    private let processGenerationProvider: (pid_t) -> String
    private let applicationIconDataProvider: (pid_t) -> Data?
    private let applicationIconCacheLifetime: TimeInterval
    private let now: () -> Date
    private let accessibilityController: any WineWindowAccessibilityControlling

    init(
        screenRecordingPreflight: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        screenRecordingRequest: @escaping () -> Bool = {
            CGRequestScreenCaptureAccess()
        },
        screenRecordingPermissionPromptGate:
            ScreenRecordingPermissionPromptGate = .shared,
        screenRecordingSettingsOpener: @escaping () -> Void = {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) else {
                return
            }
            NSWorkspace.shared.open(url)
        },
        windowObservationHub: WindowObservationHub? = nil,
        shareableContentProvider:
            (() async throws -> SCShareableContent)? = nil,
        dockProcessIsVisible: @escaping (pid_t) -> Bool = { processID in
            NSRunningApplication(processIdentifier: processID)?.activationPolicy
                == .regular
        },
        coreGraphicsWindowsProvider:
            ((Set<Int32>) -> [WineWindowSnapshot])? = nil,
        processGenerationProvider: @escaping (pid_t) -> String = {
            WineWindowCaptureService.processGeneration(for: $0)
        },
        applicationIconDataProvider: @escaping (pid_t) -> Data? = { processID in
            NSRunningApplication(processIdentifier: processID)?
                .icon?
                .tiffRepresentation
        },
        applicationIconCacheLifetime: TimeInterval = 4,
        now: @escaping () -> Date = { Date() },
        accessibilityController: any WineWindowAccessibilityControlling =
            SystemWineWindowAccessibilityController()
    ) {
        self.screenRecordingPreflight = screenRecordingPreflight
        self.screenRecordingRequest = screenRecordingRequest
        self.screenRecordingPermissionPromptGate =
            screenRecordingPermissionPromptGate
        self.screenRecordingSettingsOpener = screenRecordingSettingsOpener
        if let windowObservationHub {
            self.windowObservationHub = windowObservationHub
        } else if let shareableContentProvider {
            self.windowObservationHub = Self.makeIsolatedObservationHub(
                shareableContentProvider: shareableContentProvider
            )
        } else {
            self.windowObservationHub = .shared
        }
        self.dockProcessIsVisible = dockProcessIsVisible
        self.coreGraphicsWindowsProvider = coreGraphicsWindowsProvider
        self.processGenerationProvider = processGenerationProvider
        self.applicationIconDataProvider = applicationIconDataProvider
        self.applicationIconCacheLifetime = applicationIconCacheLifetime
        self.now = now
        self.accessibilityController = accessibilityController
    }

    private static func makeIsolatedObservationHub(
        shareableContentProvider:
            @escaping () async throws -> SCShareableContent
    ) -> WindowObservationHub {
        let provider = LegacyShareableContentProviderBox(
            shareableContentProvider
        )
        return WindowObservationHub {
            try await legacyObservationSources(using: provider)
        }
    }

    private static func legacyObservationSources(
        using provider: LegacyShareableContentProviderBox
    ) async throws -> [WindowObservationSource] {
        let content = try await provider.operation()
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
                let box = LegacyScreenCaptureKitWindowBox(window)
                return WindowObservationSource(
                    descriptor: descriptor,
                    captureSource: WindowObservationCaptureSource { _ in
                        try await captureLegacyWindow(box)
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

    private static func captureLegacyWindow(
        _ box: LegacyScreenCaptureKitWindowBox
    ) async throws -> WindowObservationCapturedImage {
        let configuration = screenshotConfiguration(
            sourceSize: box.window.frame.size
        )
        let filter = SCContentFilter(
            desktopIndependentWindow: box.window
        )
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return WindowObservationCapturedImage(image: image)
    }

    nonisolated private static func processGeneration(
        for processID: pid_t
    ) -> String {
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

    func captureWindows(
        ownedBy processIDs: Set<Int32>,
        preferredWindowID: CGWindowID? = nil,
        previewLimit: Int = 6,
        forceContentRefresh: Bool = false
    ) async -> WineWindowCaptureResult {
        guard !processIDs.isEmpty else {
            cachedExecutablePaths.removeAll(keepingCapacity: true)
            cachedApplicationIcons.removeAll(keepingCapacity: true)
            return .empty
        }
        cachedExecutablePaths = cachedExecutablePaths.filter {
            processIDs.contains($0.key)
        }
        cachedApplicationIcons = cachedApplicationIcons.filter {
            processIDs.contains($0.key)
        }

        let dockVisibleProcessIDs = Set(
            processIDs.filter { dockProcessIsVisible($0) }
        )
        guard !dockVisibleProcessIDs.isEmpty else {
            return .empty
        }

        let metadataFallback = coreGraphicsWindows(ownedBy: dockVisibleProcessIDs)
        guard screenRecordingPreflight() else {
            return .screenRecordingUnavailable(
                windows: await mergingSharedCachedImages(
                    into: metadataFallback
                )
            )
        }

        do {
            let observations = try await windowObservationHub.observeWindows(
                ownedBy: dockVisibleProcessIDs,
                preferredWindowID: preferredWindowID,
                previewLimit: max(1, previewLimit),
                forceContentRefresh: forceContentRefresh,
                matching: { descriptor in
                    descriptor.layer == 0
                        && descriptor.frame.width >= 120
                        && descriptor.frame.height >= 72
                        && Self.isUserFacingWindow(
                            isDockProcess: true,
                            title: descriptor.title ?? "",
                            isOnScreen: descriptor.isOnScreen
                        )
                }
            )

            guard !Task.isCancelled else { return .empty }
            let snapshots = observations
                .sorted { lhs, rhs in
                    WindowObservationOrdering.areInPreferredOrder(
                        lhs.descriptor,
                        rhs.descriptor
                    )
                }
                .map { observation in
                    let descriptor = observation.descriptor
                    return WineWindowSnapshot(
                        id: descriptor.windowID,
                        ownerProcessID: descriptor.ownerProcessID,
                        title: Self.windowTitle(
                            from: descriptor.title
                        ),
                        executablePath: windowsExecutablePath(
                            processID: descriptor.ownerProcessID
                        ),
                        frame: descriptor.frame,
                        isOnScreen: descriptor.isOnScreen,
                        image: observation.image,
                        applicationIconData: applicationIconData(
                            processID: descriptor.ownerProcessID
                        )
                    )
                }

            let resultWindows: [WineWindowSnapshot]
            if snapshots.isEmpty {
                resultWindows = await mergingSharedCachedImages(
                    into: metadataFallback
                )
            } else {
                resultWindows = snapshots
            }
            return WineWindowCaptureResult(
                windows: resultWindows,
                screenRecordingAccessUnavailable: false,
                message: nil
            )
        } catch {
            return .captureUnavailable(
                windows: await mergingSharedCachedImages(
                    into: metadataFallback
                )
            )
        }
    }

    func activate(_ window: WineWindowSnapshot) {
        let application = NSRunningApplication(processIdentifier: window.ownerProcessID)
        application?.activate(options: [.activateAllWindows])

        let accessibilityController = accessibilityController
        guard accessibilityController.isProcessTrusted else { return }
        Task.detached(priority: .userInitiated) {
            guard let candidates = accessibilityController.windows(
                for: window.ownerProcessID
            ),
            case let .matched(identifier) = Self.resolveWindowMatch(
                snapshotTitle: window.title,
                snapshotFrame: window.frame,
                candidates: candidates,
                purpose: .activation
            ),
            let match = candidates.first(where: {
                $0.identifier == identifier
            }) else {
                return
            }
            accessibilityController.raise(match)
        }
    }

    func close(_ window: WineWindowSnapshot) async -> WineWindowCloseResult {
        guard dockProcessIsVisible(window.ownerProcessID) else {
            return .staleWindow
        }
        let accessibilityController = accessibilityController
        guard accessibilityController.isProcessTrusted else {
            accessibilityController.requestProcessTrust()
            return .accessibilityPermissionRequired
        }
        return await Task.detached(priority: .userInitiated) {
            guard let candidates = accessibilityController.windows(
                for: window.ownerProcessID
            ) else {
                return .staleWindow
            }

            switch Self.resolveWindowMatch(
                snapshotTitle: window.title,
                snapshotFrame: window.frame,
                candidates: candidates,
                purpose: .close
            ) {
            case let .matched(identifier):
                guard let match = candidates.first(where: {
                    $0.identifier == identifier
                }) else {
                    return .staleWindow
                }
                return accessibilityController.close(match)
            case .stale:
                return .staleWindow
            case .ambiguous:
                return .ambiguousWindow
            }
        }.value
    }

    nonisolated static func isUserFacingWindow(
        isDockProcess: Bool,
        title: String,
        isOnScreen: Bool
    ) -> Bool {
        guard isDockProcess else { return false }
        return isOnScreen
            || WineWindowSnapshot.meaningfulTitle(from: title) != nil
    }

    nonisolated static func resolveWindowMatch(
        snapshotTitle: String,
        snapshotFrame: CGRect,
        candidates: [WineAccessibilityWindowCandidate],
        purpose: WineAccessibilityWindowMatchPurpose
    ) -> WineAccessibilityWindowMatch {
        let credibleCandidates: [(identifier: Int, score: CGFloat)] = candidates
            .compactMap { candidate -> (identifier: Int, score: CGFloat)? in
                guard windowMatchIsCredible(
                    snapshotTitle: snapshotTitle,
                    snapshotFrame: snapshotFrame,
                    candidateTitle: candidate.title,
                    candidateFrame: candidate.frame,
                    purpose: purpose
                ) else {
                    return nil
                }
                return (
                    identifier: candidate.identifier,
                    score: windowMatchScore(
                        snapshotTitle: snapshotTitle,
                        snapshotFrame: snapshotFrame,
                        candidateTitle: candidate.title,
                        candidateFrame: candidate.frame
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.identifier < rhs.identifier
            }

        guard let best = credibleCandidates.first else {
            return .stale
        }
        if purpose == .close,
           credibleCandidates.count > 1 {
            return .ambiguous
        }
        return .matched(identifier: best.identifier)
    }

    nonisolated private static func windowMatchIsCredible(
        snapshotTitle: String,
        snapshotFrame: CGRect,
        candidateTitle: String?,
        candidateFrame: CGRect?,
        purpose: WineAccessibilityWindowMatchPurpose
    ) -> Bool {
        guard purpose == .close else {
            return windowMatchIsCredible(
                snapshotTitle: snapshotTitle,
                snapshotFrame: snapshotFrame,
                candidateTitle: candidateTitle,
                candidateFrame: candidateFrame
            )
        }

        if let title = WineWindowSnapshot.meaningfulTitle(from: snapshotTitle) {
            guard title.localizedCaseInsensitiveCompare(
                candidateTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ) == .orderedSame else {
                return false
            }
            guard let candidateFrame else { return false }
            let originDelta = hypot(
                snapshotFrame.minX - candidateFrame.minX,
                snapshotFrame.minY - candidateFrame.minY
            )
            let sizeDelta = hypot(
                snapshotFrame.width - candidateFrame.width,
                snapshotFrame.height - candidateFrame.height
            )
            return originDelta <= 24 && sizeDelta <= 24
        }
        guard let candidateFrame else { return false }
        let originDelta = hypot(
            snapshotFrame.minX - candidateFrame.minX,
            snapshotFrame.minY - candidateFrame.minY
        )
        let sizeDelta = hypot(
            snapshotFrame.width - candidateFrame.width,
            snapshotFrame.height - candidateFrame.height
        )
        return originDelta <= 12 && sizeDelta <= 12
    }

    func requestScreenRecordingAccess() {
        if screenRecordingPreflight() {
            return
        }
        let didGrantAccess = screenRecordingPermissionPromptGate.requestIfNeeded(
            using: screenRecordingRequest
        )
        if !didGrantAccess {
            screenRecordingSettingsOpener()
        }
    }

    static func screenshotConfiguration(
        sourceSize: CGSize
    ) -> SCStreamConfiguration {
        let outputSize = thumbnailSize(for: sourceSize)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        // SCWindow.frame excludes the macOS shadow, but a captured shadow adds
        // asymmetric transparent padding. Excluding it keeps the visible
        // window content centered inside the aspect-fit preview.
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.queueDepth = 1
        return configuration
    }

    private static func thumbnailSize(for sourceSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: 960, height: 600)
        }
        let maximumWidth: CGFloat = 1_120
        let maximumHeight: CGFloat = 760
        let scale = min(
            2,
            min(maximumWidth / sourceSize.width, maximumHeight / sourceSize.height)
        )
        return CGSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )
    }

    private func coreGraphicsWindows(
        ownedBy processIDs: Set<Int32>
    ) -> [WineWindowSnapshot] {
        if let coreGraphicsWindowsProvider {
            return coreGraphicsWindowsProvider(processIDs)
        }
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info -> WineWindowSnapshot? in
            guard let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  processIDs.contains(ownerNumber.int32Value),
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                  layerNumber.intValue == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 120,
                  bounds.height >= 72 else {
                return nil
            }
            let title = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard Self.isUserFacingWindow(
                isDockProcess: true,
                title: title ?? "",
                isOnScreen: isOnScreen
            ) else {
                return nil
            }
            return WineWindowSnapshot(
                id: CGWindowID(windowNumber.uint32Value),
                ownerProcessID: ownerNumber.int32Value,
                title: title?.isEmpty == false ? title! : "",
                executablePath: windowsExecutablePath(
                    processID: ownerNumber.int32Value
                ),
                frame: bounds,
                isOnScreen: isOnScreen,
                image: nil,
                applicationIconData: applicationIconData(
                    processID: ownerNumber.int32Value
                )
            )
        }
        .sorted { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
            return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
        }
    }

    private func mergingSharedCachedImages(
        into fallbackWindows: [WineWindowSnapshot]
    ) async -> [WineWindowSnapshot] {
        guard !fallbackWindows.isEmpty else { return fallbackWindows }

        let processIdentities = Dictionary(
            uniqueKeysWithValues: Set(
                fallbackWindows.map(\.ownerProcessID)
            ).map { processID in
                (
                    processID,
                    WindowObservationProcessIdentity(
                        processID: processID,
                        generation: processGenerationProvider(processID)
                    )
                )
            }
        )
        let identities = Set<WindowObservationIdentity>(
            fallbackWindows.compactMap { window -> WindowObservationIdentity? in
                guard let processIdentity =
                    processIdentities[window.ownerProcessID] else {
                    return nil
                }
                return WindowObservationIdentity(
                    processIdentity: processIdentity,
                    windowID: window.id,
                    frame: window.frame
                )
            }
        )
        let cachedObservations = await windowObservationHub
            .cachedObservations(matching: identities)
        var imagesByIdentity:
            [WindowObservationIdentity: CGImage] = [:]
        for observation in cachedObservations {
            guard let image = observation.image else { continue }
            let descriptor = observation.descriptor
            imagesByIdentity[
                WindowObservationIdentity(
                    processIdentity: descriptor.processIdentity,
                    windowID: descriptor.windowID,
                    frame: descriptor.frame
                )
            ] = image
        }
        guard !imagesByIdentity.isEmpty else {
            return fallbackWindows
        }

        return fallbackWindows.map { window in
            guard let processIdentity =
                processIdentities[window.ownerProcessID] else {
                return window
            }
            let cachedImage = imagesByIdentity[
                WindowObservationIdentity(
                    processIdentity: processIdentity,
                    windowID: window.id,
                    frame: window.frame
                )
            ]
            guard window.image == nil, let cachedImage else {
                return window
            }
            return WineWindowSnapshot(
                id: window.id,
                ownerProcessID: window.ownerProcessID,
                title: window.title,
                executablePath: window.executablePath,
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                image: cachedImage,
                applicationIconData: window.applicationIconData
            )
        }
    }

    private static func windowTitle(from rawTitle: String?) -> String {
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return title
        }
        return ""
    }

    nonisolated static func windowMatchScore(
        snapshotTitle: String,
        snapshotFrame: CGRect,
        candidateTitle: String?,
        candidateFrame: CGRect?
    ) -> CGFloat {
        let title = WineWindowSnapshot.meaningfulTitle(from: snapshotTitle)
        let candidateTitle = candidateTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titlePenalty: CGFloat = title == nil
            || title?.localizedCaseInsensitiveCompare(candidateTitle) == .orderedSame
            ? 0
            : 1_000_000
        guard let candidateFrame else {
            return titlePenalty + 500_000
        }
        return titlePenalty
            + abs(snapshotFrame.minX - candidateFrame.minX)
            + abs(snapshotFrame.minY - candidateFrame.minY)
            + abs(snapshotFrame.width - candidateFrame.width)
            + abs(snapshotFrame.height - candidateFrame.height)
    }

    nonisolated static func windowMatchIsCredible(
        snapshotTitle: String,
        snapshotFrame: CGRect,
        candidateTitle: String?,
        candidateFrame: CGRect?
    ) -> Bool {
        if let title = WineWindowSnapshot.meaningfulTitle(from: snapshotTitle),
           title.localizedCaseInsensitiveCompare(
               candidateTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
           ) == .orderedSame {
            return true
        }
        guard let candidateFrame else { return false }
        let originDelta = hypot(
            snapshotFrame.minX - candidateFrame.minX,
            snapshotFrame.minY - candidateFrame.minY
        )
        let sizeDelta = hypot(
            snapshotFrame.width - candidateFrame.width,
            snapshotFrame.height - candidateFrame.height
        )
        return originDelta <= 96 && sizeDelta <= 96
    }

    private func windowsExecutablePath(processID: pid_t) -> String? {
        if let cachedPath = cachedExecutablePaths[processID] {
            return cachedPath
        }
        let executablePath = Self.processArguments(processID: processID)
            .prefix(8)
            .first(where: Self.looksLikeWindowsExecutablePath)
        if let executablePath {
            cachedExecutablePaths[processID] = executablePath
        }
        return executablePath
    }

    func applicationIconData(processID: pid_t) -> Data? {
        guard processID > 0 else { return nil }
        let capturedAt = now()
        let cachedIcon = cachedApplicationIcons[processID]
        if let cachedIcon {
            let age = capturedAt.timeIntervalSince(cachedIcon.capturedAt)
            if age >= 0, age < applicationIconCacheLifetime {
                return cachedIcon.data
            }
        }
        guard let iconData = applicationIconDataProvider(processID),
              !iconData.isEmpty else {
            return cachedIcon?.data
        }
        cachedApplicationIcons[processID] = CachedApplicationIcon(
            data: iconData,
            capturedAt: capturedAt
        )
        return iconData
    }

    private static func looksLikeWindowsExecutablePath(_ argument: String) -> Bool {
        let candidate = argument
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return candidate.hasSuffix(".exe") && (
            candidate.contains("\\")
                || candidate.contains("/")
                || candidate.hasPrefix("c:")
        )
    }

    private static func processArguments(processID: pid_t) -> [String] {
        guard processID > 0 else { return [] }
        var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var byteCount = 0
        guard sysctl(
            &managementInformationBase,
            UInt32(managementInformationBase.count),
            nil,
            &byteCount,
            nil,
            0
        ) == 0,
        byteCount > MemoryLayout<Int32>.size else {
            return []
        }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard bytes.withUnsafeMutableBytes({ buffer in
            sysctl(
                &managementInformationBase,
                UInt32(managementInformationBase.count),
                buffer.baseAddress,
                &byteCount,
                nil,
                0
            )
        }) == 0 else {
            return []
        }
        return decodeProcessArguments(
            fromKernelBytes: Array(bytes.prefix(byteCount))
        )
    }

    static func decodeProcessArguments(
        fromKernelBytes bytes: [UInt8]
    ) -> [String] {
        guard bytes.count > MemoryLayout<Int32>.size else { return [] }
        let argumentCount = bytes.withUnsafeBytes {
            Int($0.loadUnaligned(as: Int32.self))
        }
        guard argumentCount > 0, argumentCount <= 4_096 else { return [] }

        var offset = MemoryLayout<Int32>.size

        func skipCString() {
            while offset < bytes.count, bytes[offset] != 0 {
                offset += 1
            }
            if offset < bytes.count {
                offset += 1
            }
        }

        skipCString()
        while offset < bytes.count, bytes[offset] == 0 {
            offset += 1
        }

        var arguments: [String] = []
        arguments.reserveCapacity(argumentCount)
        for _ in 0..<argumentCount {
            guard offset < bytes.count else { break }
            let start = offset
            while offset < bytes.count, bytes[offset] != 0 {
                offset += 1
            }
            arguments.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            if offset < bytes.count {
                offset += 1
            }
        }
        return arguments
    }

}

@MainActor
final class ContainerSessionStageModel: ObservableObject {
    @Published private(set) var windows: [WineWindowSnapshot] = []
    @Published private(set) var screenRecordingAccessUnavailable = false
    @Published private(set) var previewMessage: String?
    @Published private(set) var closingWindowIdentities:
        Set<SessionStageWindowIdentity> = []
    @Published private(set) var resourceSnapshot: WineSessionResourceSnapshot?
    @Published var selectedWindowID: CGWindowID?
    @Published private(set) var selectedWindowIdentity:
        SessionStageWindowIdentity?

    private let captureService: WineWindowCaptureService
    private let previewStore = ContainerPreviewImageStore.shared
    private let resourceMetricsService = WineSessionResourceMetricsService()
    private var refreshGeneration = 0
    private var lastPersistedWindowIdentity: SessionStageWindowIdentity?
    private var lastPersistedAt: Date?

    init() {
        // Swift 6.1.2 can crash during SIL generation when this construction
        // appears in a stored-property initializer.
        captureService = WineWindowCaptureService()
    }

    func monitor(containerID: UUID, store: AppStore) async {
        while !Task.isCancelled {
            await refresh(containerID: containerID, store: store)
            do {
                let delay: Duration = store.sessionSnapshot(for: containerID)
                    .wineServerState.hasRunningProcesses ? .seconds(2) : .seconds(4)
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    func refresh(containerID: UUID, store: AppStore) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let processIDs = await store.wineHostProcessIDs(for: containerID)
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        let resourceMetricsService = resourceMetricsService
        async let sampledResources = Task.detached(priority: .utility) {
            resourceMetricsService.sample(processIDs: processIDs)
        }.value
        let result = await captureService.captureWindows(
            ownedBy: processIDs,
            preferredWindowID: selectedWindowID
        )
        let resources = await sampledResources
        guard !Task.isCancelled, generation == refreshGeneration else { return }

        windows = Self.windowsKeepingStableOrder(
            previous: windows,
            refreshed: result.windows
        )
        resourceSnapshot = resources
        screenRecordingAccessUnavailable = result.screenRecordingAccessUnavailable
        previewMessage = result.message
        selectedWindowIdentity = Self.selectedWindowIdentity(
            previous: selectedWindowIdentity,
            selectedWindowID: selectedWindowID,
            windows: windows
        )
        selectedWindowID = selectedWindowIdentity?.windowID
        closingWindowIdentities = Self.closingWindowIdentities(
            closingWindowIdentities,
            stillPresentIn: windows
        )
        await persistCurrentPreview(containerID: containerID, store: store)
    }

    func activate(_ window: WineWindowSnapshot) {
        selectedWindowID = window.id
        selectedWindowIdentity = SessionStageWindowIdentity(window: window)
        captureService.activate(window)
    }

    @discardableResult
    func close(_ window: WineWindowSnapshot) async -> WineWindowCloseResult {
        let identity = SessionStageWindowIdentity(window: window)
        guard !closingWindowIdentities.contains(identity) else {
            return .operationFailed
        }
        closingWindowIdentities.insert(identity)
        defer {
            closingWindowIdentities.remove(identity)
        }

        let result = await captureService.close(window)
        return result
    }

    func requestScreenRecordingAccess() {
        captureService.requestScreenRecordingAccess()
    }

    private func persistCurrentPreview(containerID: UUID, store: AppStore) async {
        guard let window = ContainerPreviewWindowPolicy.preferredWindow(
                  in: windows,
                  selectedWindowID: selectedWindowID
              ),
              let image = window.image,
              let container = store.containers.first(where: {
                  $0.id == containerID
              }) else {
            return
        }

        let now = Date()
        let windowIdentity = SessionStageWindowIdentity(window: window)
        let shouldPersist = lastPersistedWindowIdentity != windowIdentity
            || lastPersistedAt.map {
                now.timeIntervalSince($0) >= 5
            } ?? true
        guard shouldPersist else { return }

        let containerURL = URL(
            fileURLWithPath: container.path,
            isDirectory: true
        )
        guard let persistedAt = try? await previewStore.save(
            ContainerPreviewImage(image: image),
            intoContainerAt: containerURL
        ) else {
            return
        }
        lastPersistedWindowIdentity = windowIdentity
        lastPersistedAt = persistedAt
    }

    nonisolated static func selectedWindowIdentity(
        previous: SessionStageWindowIdentity?,
        selectedWindowID: CGWindowID?,
        windows: [WineWindowSnapshot]
    ) -> SessionStageWindowIdentity? {
        if let previous,
           windows.contains(where: previous.matches) {
            return previous
        }
        if previous == nil,
           let selectedWindowID,
           let selectedWindow = windows.first(where: {
               $0.id == selectedWindowID
           }) {
            return SessionStageWindowIdentity(window: selectedWindow)
        }
        return windows.first.map(SessionStageWindowIdentity.init)
    }

    nonisolated static func closingWindowIdentities(
        _ identities: Set<SessionStageWindowIdentity>,
        stillPresentIn windows: [WineWindowSnapshot]
    ) -> Set<SessionStageWindowIdentity> {
        Set(identities.filter { identity in
            windows.contains(where: identity.matches)
        })
    }

    nonisolated static func windowsKeepingStableOrder(
        previous: [WineWindowSnapshot],
        refreshed: [WineWindowSnapshot]
    ) -> [WineWindowSnapshot] {
        let refreshedByID = Dictionary(
            uniqueKeysWithValues: refreshed.map {
                (SessionStageWindowIdentity(window: $0), $0)
            }
        )
        var ordered = previous.compactMap {
            refreshedByID[SessionStageWindowIdentity(window: $0)]
        }
        let existingIdentities = Set(
            ordered.map(SessionStageWindowIdentity.init)
        )
        ordered.append(contentsOf: refreshed.filter {
            !existingIdentities.contains(SessionStageWindowIdentity(window: $0))
        })
        return ordered
    }
}
