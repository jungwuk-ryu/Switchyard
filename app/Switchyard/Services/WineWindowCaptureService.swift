import AppCore
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct WineWindowSnapshot: Identifiable, @unchecked Sendable {
    let id: CGWindowID
    let ownerProcessID: pid_t
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
    let image: CGImage?

    var aspectRatio: CGFloat {
        guard frame.height > 0 else { return 16 / 10 }
        return max(0.7, min(2.2, frame.width / frame.height))
    }
}

struct WineWindowCaptureResult: @unchecked Sendable {
    var windows: [WineWindowSnapshot]
    var needsScreenRecordingPermission: Bool
    var message: String?

    static let empty = WineWindowCaptureResult(
        windows: [],
        needsScreenRecordingPermission: false,
        message: nil
    )
}

@MainActor
final class WineWindowCaptureService {
    private struct CachedImage {
        var image: CGImage
        var capturedAt: Date
        var frameSize: CGSize
    }

    private var cachedImages: [CGWindowID: CachedImage] = [:]
    private var hasRequestedScreenRecordingPermission = false

    func captureWindows(
        ownedBy processIDs: Set<Int32>,
        limit: Int = 6
    ) async -> WineWindowCaptureResult {
        guard !processIDs.isEmpty else {
            cachedImages.removeAll(keepingCapacity: true)
            return .empty
        }

        let metadataFallback = coreGraphicsWindows(
            ownedBy: processIDs,
            limit: limit
        )
        guard screenRecordingAccessIsAvailable() else {
            return WineWindowCaptureResult(
                windows: metadataFallback,
                needsScreenRecordingPermission: true,
                message: String(
                    localized: "Allow Screen Recording to show live Windows app previews.",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
            let candidates = content.windows
                .filter { window in
                    guard let owner = window.owningApplication else { return false }
                    return processIDs.contains(Int32(owner.processID))
                        && window.windowLayer == 0
                        && window.frame.width >= 120
                        && window.frame.height >= 72
                }
                .sorted(by: Self.windowSort)
                .prefix(max(1, limit))

            var snapshots: [WineWindowSnapshot] = []
            snapshots.reserveCapacity(candidates.count)
            for window in candidates {
                guard !Task.isCancelled else { return .empty }
                let image = await image(for: window)
                snapshots.append(
                    WineWindowSnapshot(
                        id: window.windowID,
                        ownerProcessID: window.owningApplication?.processID ?? 0,
                        title: windowTitle(for: window),
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
                needsScreenRecordingPermission: false,
                message: nil
            )
        } catch {
            return WineWindowCaptureResult(
                windows: metadataFallback,
                needsScreenRecordingPermission: true,
                message: String(
                    localized: "Live previews are unavailable. You can still switch to each Windows app.",
                    bundle: SwitchyardStrings.bundle
                )
            )
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

        for accessibilityWindow in accessibilityWindows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                accessibilityWindow,
                kAXTitleAttribute as CFString,
                &titleValue
            ) == .success,
            let title = titleValue as? String,
            title == window.title else {
                continue
            }
            AXUIElementPerformAction(accessibilityWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(
                accessibilityWindow,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            break
        }
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
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        guard !hasRequestedScreenRecordingPermission else { return false }
        hasRequestedScreenRecordingPermission = true
        return CGRequestScreenCaptureAccess()
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
        ownedBy processIDs: Set<Int32>,
        limit: Int
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
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return WineWindowSnapshot(
                id: CGWindowID(windowNumber.uint32Value),
                ownerProcessID: ownerNumber.int32Value,
                title: title?.isEmpty == false
                    ? title!
                    : (ownerName?.isEmpty == false ? ownerName! : "Windows App"),
                frame: bounds,
                isOnScreen: isOnScreen,
                image: cachedImages[CGWindowID(windowNumber.uint32Value)]?.image
            )
        }
        .sorted { lhs, rhs in
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
            return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
        }
        .prefix(max(1, limit))
        .map { $0 }
    }

    private func windowTitle(for window: SCWindow) -> String {
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return title
        }
        let applicationName = window.owningApplication?.applicationName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return applicationName?.isEmpty == false ? applicationName! : "Windows App"
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
    @Published private(set) var needsScreenRecordingPermission = false
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
        let result = await captureService.captureWindows(ownedBy: processIDs)
        guard !Task.isCancelled, generation == refreshGeneration else { return }

        windows = result.windows
        needsScreenRecordingPermission = result.needsScreenRecordingPermission
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
}
