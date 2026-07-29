import AppCore
import CoreGraphics
import Foundation

enum ContainerPreviewWindowPolicy {
    private static let excludedExecutableNames: Set<String> = [
        "explorerexe",
        "wine",
        "wine64",
        "wine64preloader",
        "wineboot",
        "winebootexe",
        "winecfg",
        "winecfgexe",
        "wineconsole",
        "wineconsoleexe",
        "winemenubuilder",
        "winemenubuilderexe",
        "wineserver",
        "wineserverexe",
    ]

    static func preferredWindow(
        in windows: [WineWindowSnapshot],
        selectedWindowID: CGWindowID? = nil
    ) -> WineWindowSnapshot? {
        preferredWindowCandidate(
            in: windows.filter { $0.image != nil },
            selectedWindowID: selectedWindowID
        )
    }

    static func preferredWindowCandidate(
        in windows: [WineWindowSnapshot],
        selectedWindowID: CGWindowID? = nil
    ) -> WineWindowSnapshot? {
        let eligibleWindows = windows.filter(representsApplication)
        if let selectedWindowID,
           let selectedWindow = eligibleWindows.first(where: {
               $0.id == selectedWindowID
           }) {
            return selectedWindow
        }
        return eligibleWindows.first
    }

    private static func representsApplication(
        _ window: WineWindowSnapshot
    ) -> Bool {
        if let executablePath = window.executablePath {
            let executableName = executablePath
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .last
                .map(String.init) ?? executablePath
            let key = executableName.lowercased().filter {
                $0.isLetter || $0.isNumber
            }
            if excludedExecutableNames.contains(key) {
                return false
            }
        }
        return window.meaningfulTitle != nil
            || window.executableDisplayName != nil
    }
}

@MainActor
final class ContainerLibraryCardModel: ObservableObject {
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var storageByteCount: Int64?
    @Published private(set) var isMeasuringSize = false

    private let captureService: WineWindowCaptureService
    private let previewStore: ContainerPreviewImageStore
    private let storageSizeService: ContainerStorageSizeService
    private var lastPersistedWindowID: CGWindowID?
    private var lastPersistedAt: Date?

    init(
        captureService: WineWindowCaptureService = WineWindowCaptureService(),
        previewStore: ContainerPreviewImageStore = .shared,
        storageSizeService: ContainerStorageSizeService = .shared
    ) {
        self.captureService = captureService
        self.previewStore = previewStore
        self.storageSizeService = storageSizeService
    }

    func monitor(containerID: UUID, store: AppStore) async {
        guard let initialContainer = store.containers.first(where: {
            $0.id == containerID
        }) else {
            return
        }
        await loadPersistedPreview(for: initialContainer)

        var wasRunning = store.sessionSnapshot(for: containerID)
            .wineServerState.hasRunningProcesses
        while !Task.isCancelled,
              let container = store.containers.first(where: {
                  $0.id == containerID
              }) {
            let isRunning = store.sessionSnapshot(for: containerID)
                .wineServerState.hasRunningProcesses
            if isRunning {
                await refreshLivePreview(for: container, store: store)
            } else if wasRunning {
                await refreshStorageSize(for: container)
            }
            wasRunning = isRunning

            do {
                try await Task.sleep(
                    for: isRunning ? .seconds(2) : .seconds(8)
                )
            } catch {
                return
            }
        }
    }

    func refreshStorageSize(for container: Container) async {
        isMeasuringSize = true
        defer { isMeasuringSize = false }

        let containerURL = URL(
            fileURLWithPath: container.path,
            isDirectory: true
        )
        storageByteCount = try? await storageSizeService
            .byteCount(forContainerAt: containerURL)
    }

    private func loadPersistedPreview(for container: Container) async {
        let containerURL = URL(
            fileURLWithPath: container.path,
            isDirectory: true
        )
        guard let preview = try? await previewStore.load(
            fromContainerAt: containerURL
        ) else {
            return
        }
        guard !Task.isCancelled else { return }
        previewImage = preview.image
        lastPersistedAt = preview.modifiedAt
    }

    private func refreshLivePreview(
        for container: Container,
        store: AppStore
    ) async {
        let processIDs = await store.wineHostProcessIDs(for: container.id)
        guard !Task.isCancelled, !processIDs.isEmpty else { return }

        var result = await captureService.captureWindows(
            ownedBy: processIDs,
            previewLimit: 1
        )
        guard !Task.isCancelled else { return }

        var window = ContainerPreviewWindowPolicy.preferredWindow(
            in: result.windows
        )
        if window == nil,
           let candidate = ContainerPreviewWindowPolicy
               .preferredWindowCandidate(in: result.windows) {
            result = await captureService.captureWindows(
                ownedBy: processIDs,
                preferredWindowID: candidate.id,
                previewLimit: 1
            )
            window = ContainerPreviewWindowPolicy.preferredWindow(
                in: result.windows,
                selectedWindowID: candidate.id
            )
        }

        guard !Task.isCancelled,
              let window,
              let image = window.image else {
            return
        }
        previewImage = image

        let now = Date()
        let shouldPersist = lastPersistedWindowID != window.id
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
        lastPersistedWindowID = window.id
        lastPersistedAt = persistedAt
    }
}
