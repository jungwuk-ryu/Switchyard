import AppCore
import AppKit
import ApplicationServices
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
        "wine",
        "wine64",
        "wine64preloader",
        "windowsapp",
        "windowssession",
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

@MainActor
final class WineWindowCaptureService {
    private struct CachedImage {
        var image: CGImage
        var capturedAt: Date
        var frameSize: CGSize
    }

    private var cachedImages: [CGWindowID: CachedImage] = [:]
    private var cachedExecutablePaths: [pid_t: String] = [:]
    private var hasRequestedScreenRecordingPermission = false
    private let screenRecordingPreflight: () -> Bool
    private let screenRecordingRequest: () -> Bool
    private let shareableContentProvider: () async throws -> SCShareableContent

    init(
        screenRecordingPreflight: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        screenRecordingRequest: @escaping () -> Bool = {
            CGRequestScreenCaptureAccess()
        },
        shareableContentProvider: @escaping () async throws -> SCShareableContent = {
            try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        }
    ) {
        self.screenRecordingPreflight = screenRecordingPreflight
        self.screenRecordingRequest = screenRecordingRequest
        self.shareableContentProvider = shareableContentProvider
    }

    func captureWindows(
        ownedBy processIDs: Set<Int32>,
        preferredWindowID: CGWindowID? = nil,
        previewLimit: Int = 6
    ) async -> WineWindowCaptureResult {
        guard !processIDs.isEmpty else {
            cachedImages.removeAll(keepingCapacity: true)
            cachedExecutablePaths.removeAll(keepingCapacity: true)
            return .empty
        }
        cachedExecutablePaths = cachedExecutablePaths.filter {
            processIDs.contains($0.key)
        }

        let metadataFallback = coreGraphicsWindows(ownedBy: processIDs)
        guard screenRecordingAccessIsAvailable() else {
            return .screenRecordingUnavailable(windows: metadataFallback)
        }

        do {
            let content = try await shareableContentProvider()
            let candidates = Array(
                content.windows
                    .filter { window in
                        guard let owner = window.owningApplication else { return false }
                        return processIDs.contains(Int32(owner.processID))
                            && window.windowLayer == 0
                            && window.frame.width >= 120
                            && window.frame.height >= 72
                    }
                    .sorted(by: Self.windowSort)
            )

            var snapshots: [WineWindowSnapshot] = []
            snapshots.reserveCapacity(candidates.count)
            for (index, window) in candidates.enumerated() {
                guard !Task.isCancelled else { return .empty }
                let shouldCapturePreview = index < max(1, previewLimit)
                    || window.windowID == preferredWindowID
                let image = shouldCapturePreview
                    ? await image(for: window)
                    : cachedImages[window.windowID]?.image
                snapshots.append(
                    WineWindowSnapshot(
                        id: window.windowID,
                        ownerProcessID: window.owningApplication?.processID ?? 0,
                        title: windowTitle(for: window),
                        executablePath: windowsExecutablePath(
                            processID: window.owningApplication?.processID ?? 0
                        ),
                        frame: window.frame,
                        isOnScreen: window.isOnScreen,
                        image: image
                    )
                )
            }

            let activeWindowIDs = Set(snapshots.map(\.id))
            cachedImages = cachedImages.filter { activeWindowIDs.contains($0.key) }
            return WineWindowCaptureResult(
                windows: snapshots.isEmpty ? metadataFallback : snapshots,
                screenRecordingAccessUnavailable: false,
                message: nil
            )
        } catch {
            return .captureUnavailable(windows: metadataFallback)
        }
    }

    func activate(_ window: WineWindowSnapshot) {
        let application = NSRunningApplication(processIdentifier: window.ownerProcessID)
        application?.activate(options: [.activateAllWindows])

        guard AXIsProcessTrusted() else { return }
        let applicationElement = AXUIElementCreateApplication(window.ownerProcessID)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let accessibilityWindows = windowsValue as? [AXUIElement] else {
            return
        }

        let candidates = accessibilityWindows.map { candidate in
            (
                element: candidate,
                title: accessibilityTitle(for: candidate),
                frame: accessibilityFrame(for: candidate)
            )
        }
        guard let match = candidates.min(by: { lhs, rhs in
            Self.windowMatchScore(
                snapshotTitle: window.title,
                snapshotFrame: window.frame,
                candidateTitle: lhs.title,
                candidateFrame: lhs.frame
            ) < Self.windowMatchScore(
                snapshotTitle: window.title,
                snapshotFrame: window.frame,
                candidateTitle: rhs.title,
                candidateFrame: rhs.frame
            )
        }),
        Self.windowMatchIsCredible(
            snapshotTitle: window.title,
            snapshotFrame: window.frame,
            candidateTitle: match.title,
            candidateFrame: match.frame
        ) else {
            return
        }
        AXUIElementPerformAction(match.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            match.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func screenRecordingAccessIsAvailable() -> Bool {
        if screenRecordingPreflight() {
            return true
        }
        guard !hasRequestedScreenRecordingPermission else { return false }
        hasRequestedScreenRecordingPermission = true
        return screenRecordingRequest()
    }

    private func image(for window: SCWindow) async -> CGImage? {
        if let cached = cachedImages[window.windowID],
           cached.frameSize == window.frame.size,
           Date().timeIntervalSince(cached.capturedAt) < 1.6 {
            return cached.image
        }

        let outputSize = thumbnailSize(for: window.frame.size)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = false
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.queueDepth = 1

        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            cachedImages[window.windowID] = CachedImage(
                image: image,
                capturedAt: Date(),
                frameSize: window.frame.size
            )
            return image
        } catch {
            return cachedImages[window.windowID]?.image
        }
    }

    private func thumbnailSize(for sourceSize: CGSize) -> CGSize {
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
            return WineWindowSnapshot(
                id: CGWindowID(windowNumber.uint32Value),
                ownerProcessID: ownerNumber.int32Value,
                title: title?.isEmpty == false ? title! : "",
                executablePath: windowsExecutablePath(
                    processID: ownerNumber.int32Value
                ),
                frame: bounds,
                isOnScreen: isOnScreen,
                image: cachedImages[CGWindowID(windowNumber.uint32Value)]?.image
            )
        }
        .sorted { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
            return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
        }
    }

    private func windowTitle(for window: SCWindow) -> String {
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return title
        }
        return ""
    }

    private func accessibilityTitle(for window: AXUIElement) -> String? {
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

    private func accessibilityFrame(for window: AXUIElement) -> CGRect? {
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

    static func windowMatchScore(
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

    static func windowMatchIsCredible(
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

    private static func windowSort(_ lhs: SCWindow, _ rhs: SCWindow) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
        let lhsArea = lhs.frame.width * lhs.frame.height
        let rhsArea = rhs.frame.width * rhs.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        return lhs.windowID < rhs.windowID
    }
}

@MainActor
final class ContainerSessionStageModel: ObservableObject {
    @Published private(set) var windows: [WineWindowSnapshot] = []
    @Published private(set) var screenRecordingAccessUnavailable = false
    @Published private(set) var previewMessage: String?
    @Published var selectedWindowID: CGWindowID?

    private let captureService = WineWindowCaptureService()
    private var refreshGeneration = 0

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
        let result = await captureService.captureWindows(
            ownedBy: processIDs,
            preferredWindowID: selectedWindowID
        )
        guard !Task.isCancelled, generation == refreshGeneration else { return }

        windows = Self.windowsKeepingStableOrder(
            previous: windows,
            refreshed: result.windows
        )
        screenRecordingAccessUnavailable = result.screenRecordingAccessUnavailable
        previewMessage = result.message
        if let selectedWindowID,
           windows.contains(where: { $0.id == selectedWindowID }) {
            return
        }
        selectedWindowID = windows.first?.id
    }

    func activate(_ window: WineWindowSnapshot) {
        selectedWindowID = window.id
        captureService.activate(window)
    }

    func openScreenRecordingSettings() {
        captureService.openScreenRecordingSettings()
    }

    static func windowsKeepingStableOrder(
        previous: [WineWindowSnapshot],
        refreshed: [WineWindowSnapshot]
    ) -> [WineWindowSnapshot] {
        let refreshedByID = Dictionary(
            uniqueKeysWithValues: refreshed.map { ($0.id, $0) }
        )
        var ordered = previous.compactMap { refreshedByID[$0.id] }
        let existingIDs = Set(ordered.map(\.id))
        ordered.append(contentsOf: refreshed.filter { !existingIDs.contains($0.id) })
        return ordered
    }
}
