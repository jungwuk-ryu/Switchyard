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

    private var mountedHandlers: [UUID: () -> Void] = [:]
    private var openMainWindow: (() -> Void)?

    var nextItem: WindowsApplicationOpenItem? {
        pendingItems.first
    }

    @discardableResult
    func enqueue(_ urls: [URL]) -> Bool {
        let previousClaimableItemID = claimableItemID
        var didAcceptWindowsApplication = false
        for url in urls {
            guard url.isFileURL,
                  WindowsApplicationFileKind.supports(url) else {
                continue
            }
            didAcceptWindowsApplication = true

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
        notifyHandlersIfClaimableItemChanged(
            from: previousClaimableItemID
        )
        return didAcceptWindowsApplication
    }

    func claimNextItem() -> WindowsApplicationOpenItem? {
        guard claimedItem == nil, !pendingItems.isEmpty else { return nil }
        let item = pendingItems.removeFirst()
        claimedItem = item
        return item
    }

    func complete(_ itemID: WindowsApplicationOpenItem.ID) {
        let previousClaimableItemID = claimableItemID
        if claimedItem?.id == itemID {
            claimedItem = nil
        } else {
            pendingItems.removeAll { $0.id == itemID }
        }
        notifyHandlersIfClaimableItemChanged(
            from: previousClaimableItemID
        )
    }

    func handlerDidAppear(
        id: UUID,
        openMainWindow: @escaping () -> Void,
        claimableItemDidBecomeAvailable: @escaping () -> Void
    ) {
        mountedHandlers[id] = claimableItemDidBecomeAvailable
        self.openMainWindow = openMainWindow
    }

    func handlerDidDisappear(id: UUID) {
        mountedHandlers.removeValue(forKey: id)
    }

    func showMainWindowIfNeeded() {
        guard mountedHandlers.isEmpty else { return }
        openMainWindow?()
    }

    private var claimableItemID: WindowsApplicationOpenItem.ID? {
        guard claimedItem == nil else { return nil }
        return pendingItems.first?.id
    }

    private func notifyHandlersIfClaimableItemChanged(
        from previousItemID: WindowsApplicationOpenItem.ID?
    ) {
        guard let claimableItemID,
              claimableItemID != previousItemID else {
            return
        }

        let handlers = mountedHandlers
        for (handlerID, notifyHandler) in handlers {
            guard mountedHandlers[handlerID] != nil else { continue }
            notifyHandler()
        }
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
