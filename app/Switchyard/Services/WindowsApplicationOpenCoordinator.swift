import AppCore
import Combine
import Foundation
import Persistence

struct WindowsApplicationOpenItem: Identifiable, Equatable {
    let id: UUID
    let applicationURL: URL

    init(id: UUID = UUID(), applicationURL: URL) {
        self.id = id
        self.applicationURL = applicationURL.standardizedFileURL
    }
}

@MainActor
final class WindowsApplicationOpenCoordinator: ObservableObject {
    @Published private(set) var pendingItems: [WindowsApplicationOpenItem] = []
    @Published private(set) var claimedItem: WindowsApplicationOpenItem?

    private var mountedHandlerIDs: Set<UUID> = []
    private var openMainWindow: (() -> Void)?

    var nextItem: WindowsApplicationOpenItem? {
        pendingItems.first
    }

    @discardableResult
    func enqueue(_ urls: [URL]) -> Bool {
        var didAcceptExecutable = false
        for url in urls {
            guard url.isFileURL,
                  WindowsApplicationFileKind(path: url.path) == .executable else {
                continue
            }
            didAcceptExecutable = true

            let standardizedURL = url.standardizedFileURL
            guard claimedItem?.applicationURL != standardizedURL,
                  !pendingItems.contains(where: {
                      $0.applicationURL == standardizedURL
                  }) else {
                continue
            }
            pendingItems.append(
                WindowsApplicationOpenItem(applicationURL: standardizedURL)
            )
        }
        return didAcceptExecutable
    }

    func claimNextItem() -> WindowsApplicationOpenItem? {
        guard claimedItem == nil, !pendingItems.isEmpty else { return nil }
        let item = pendingItems.removeFirst()
        claimedItem = item
        return item
    }

    func complete(_ itemID: WindowsApplicationOpenItem.ID) {
        if claimedItem?.id == itemID {
            claimedItem = nil
            return
        }
        pendingItems.removeAll { $0.id == itemID }
    }

    func handlerDidAppear(
        id: UUID,
        openMainWindow: @escaping () -> Void
    ) {
        mountedHandlerIDs.insert(id)
        self.openMainWindow = openMainWindow
    }

    func handlerDidDisappear(id: UUID) {
        mountedHandlerIDs.remove(id)
    }

    func showMainWindowIfNeeded() {
        guard mountedHandlerIDs.isEmpty else { return }
        openMainWindow?()
    }
}

enum WindowsApplicationOpenRouting {
    static func matchingContainers(
        for applicationURL: URL,
        among containers: [Container],
        catalog: ContainerDirectoryCatalog = ContainerDirectoryCatalog()
    ) -> [Container] {
        containers.filter { catalog.contains(applicationURL, in: $0) }
    }

    static func automaticContainer(
        for applicationURL: URL,
        among containers: [Container],
        catalog: ContainerDirectoryCatalog = ContainerDirectoryCatalog()
    ) -> Container? {
        let matches = matchingContainers(
            for: applicationURL,
            among: containers,
            catalog: catalog
        )
        return matches.count == 1 ? matches[0] : nil
    }
}
