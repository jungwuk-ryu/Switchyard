import AppCore
import SwiftUI

private struct WindowsApplicationOpenHandlingModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: WindowsApplicationOpenCoordinator
    @ObservedObject var store: AppStore

    @State private var handlerID = UUID()
    @State private var presentedItem: WindowsApplicationOpenItem?
    @State private var presentedItemID: WindowsApplicationOpenItem.ID?
    @State private var selectedContainerID: UUID?

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedItem, onDismiss: finishDismissal) { item in
                WindowsApplicationOpenView(
                    item: item,
                    containers: store.containers,
                    selectedContainerID: $selectedContainerID,
                    isContainerUnavailable: { containerID in
                        store.isContainerTransitioning(containerID)
                            || !store.runtimeStatus.canLaunch
                    },
                    addContainer: addContainer,
                    cancel: {
                        finish(item: item)
                    },
                    run: { containerID in
                        finish(item: item, runningIn: containerID)
                    }
                )
            }
            .onAppear {
                coordinator.handlerDidAppear(
                    id: handlerID,
                    openMainWindow: {
                        openWindow(id: "main")
                    },
                    claimableItemDidBecomeAvailable: {
                        processNextItemSoon()
                    }
                )
                processNextItemIfPossible()
            }
            .onDisappear {
                coordinator.handlerDidDisappear(id: handlerID)
                completePresentedItem()
            }
            .onChange(of: store.hasCompletedSetup) { _, _ in
                processNextItemIfPossible()
            }
            .onChange(of: store.runtimeStatus) { _, _ in
                processNextItemIfPossible()
            }
            .onChange(of: store.containers) { _, _ in
                repairContainerSelection()
                processNextItemIfPossible()
            }
    }

    private func processNextItemIfPossible() {
        guard presentedItem == nil,
              store.hasCompletedSetup,
              store.runtimeStatus.canLaunch,
              let item = coordinator.claimNextItem() else {
            return
        }

        guard isExistingRegularFile(item.applicationURL) else {
            coordinator.complete(item.id)
            processNextItemSoon()
            return
        }

        let automaticContainer = WindowsApplicationOpenRouting.automaticContainer(
            for: item.applicationURL,
            among: store.containers
        )
        if let automaticContainer,
           !store.isContainerTransitioning(automaticContainer.id) {
            coordinator.complete(item.id)
            _ = store.runWindowsApplication(
                at: item.applicationURL,
                in: automaticContainer.id
            )
            processNextItemSoon()
            return
        }

        selectedContainerID = automaticContainer?.id
            ?? store.selectedContainerID
            ?? store.containers.first?.id
        presentedItemID = item.id
        presentedItem = item
    }

    private func isExistingRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
        ])
        return values?.isRegularFile == true && values?.isDirectory != true
    }

    private func addContainer() {
        store.addContainer()
        selectedContainerID = store.selectedContainerID
    }

    private func repairContainerSelection() {
        guard presentedItem != nil else { return }
        if let selectedContainerID,
           store.containers.contains(where: { $0.id == selectedContainerID }) {
            return
        }
        selectedContainerID = store.selectedContainerID
            ?? store.containers.first?.id
    }

    private func finish(
        item: WindowsApplicationOpenItem,
        runningIn containerID: UUID? = nil
    ) {
        if let containerID {
            _ = store.runWindowsApplication(
                at: item.applicationURL,
                in: containerID
            )
        }
        coordinator.complete(item.id)
        presentedItemID = nil
        presentedItem = nil
        selectedContainerID = nil
    }

    private func finishDismissal() {
        completePresentedItem()
        processNextItemSoon()
    }

    private func completePresentedItem() {
        if let presentedItemID {
            coordinator.complete(presentedItemID)
        }
        presentedItemID = nil
        presentedItem = nil
        selectedContainerID = nil
    }

    private func processNextItemSoon() {
        Task { @MainActor in
            await Task.yield()
            processNextItemIfPossible()
        }
    }
}

private struct WindowsApplicationOpenView: View {
    let item: WindowsApplicationOpenItem
    let containers: [Container]
    @Binding var selectedContainerID: UUID?
    let isContainerUnavailable: (UUID) -> Bool
    let addContainer: () -> Void
    let cancel: () -> Void
    let run: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a Windows application")
                    .font(.title2.weight(.semibold))

                Text(verbatim: item.applicationURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(verbatim: item.applicationURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            if containers.isEmpty {
                ContentUnavailableView {
                    Label("Containers", systemImage: "shippingbox")
                } description: {
                    Text("Create a private space for a Windows app")
                } actions: {
                    Button("Add Container", action: addContainer)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Text("Containers")
                    .font(.headline)

                List(containers, selection: $selectedContainerID) { container in
                    Text(container.name)
                        .tag(container.id)
                }
                .frame(minHeight: 150, maxHeight: 260)
            }

            if let selectedContainer,
               isContainerUnavailable(selectedContainer.id) {
                SettingsNotice(
                    message: String(
                        localized: "Wait for \(selectedContainer.name) to finish its current session action before starting another executable.",
                        bundle: SwitchyardStrings.bundle
                    ),
                    systemImage: "clock.fill",
                    color: .secondary
                )
            }

            HStack {
                Spacer()

                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)

                Button("Run") {
                    if let selectedContainerID {
                        run(selectedContainerID)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedContainerID == nil
                        || selectedContainerID.map(isContainerUnavailable) == true
                )
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var selectedContainer: Container? {
        guard let selectedContainerID else { return nil }
        return containers.first { $0.id == selectedContainerID }
    }
}

extension View {
    func handlesWindowsApplicationOpenEvents(
        coordinator: WindowsApplicationOpenCoordinator,
        store: AppStore
    ) -> some View {
        modifier(
            WindowsApplicationOpenHandlingModifier(
                coordinator: coordinator,
                store: store
            )
        )
    }
}
