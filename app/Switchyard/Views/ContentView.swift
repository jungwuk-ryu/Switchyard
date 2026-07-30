import AppCore
import SwiftUI

private struct StopAllWindowsAppsConfirmationRequestKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var requestStopAllWindowsAppsConfirmation: (() -> Void)? {
        get { self[StopAllWindowsAppsConfirmationRequestKey.self] }
        set { self[StopAllWindowsAppsConfirmationRequestKey.self] = newValue }
    }
}

struct StopAllWindowsAppsConfirmationState: Equatable {
    private(set) var isPresented = false

    mutating func request() {
        isPresented = true
    }

    mutating func cancel() {
        isPresented = false
    }

    @discardableResult
    mutating func confirm() -> Bool {
        guard isPresented else { return false }
        isPresented = false
        return true
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var updater: SwitchyardUpdater
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedSection") private var selectedSectionRawValue = SidebarSelection.containers.rawValue
    @State private var hasEvaluatedInitialReadiness = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var stopAllWindowsAppsConfirmation = StopAllWindowsAppsConfirmationState()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            DetailView(selection: store.selectedSection)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                if !store.isPresentingContainerDetail {
                    Button {
                        store.addContainer()
                    } label: {
                        Label("Add Container", systemImage: "plus")
                    }
                    .disabled(!store.hasCompletedSetup || !store.runtimeStatus.canLaunch)
                    .help(
                        store.hasCompletedSetup && store.runtimeStatus.canLaunch
                            ? "Create a private space for a Windows app"
                            : "Finish setup before creating a container"
                    )

                    Button {
                        stopAllWindowsAppsConfirmation.request()
                    } label: {
                        Label("Stop All Windows Apps", systemImage: "stop.fill")
                    }
                    .disabled(
                        !store.hasRunningContainers
                            || store.isStoppingAllWindowsApps
                    )
                    .help("Close all running Windows apps after confirmation")
                    .accessibilityHint("Shows a confirmation before closing all running Windows apps")
                }
            }
        }
        .hidingDefaultToolbarTitle()
        .toolbar(
            removing: store.isPresentingContainerDetail ? .sidebarToggle : nil
        )
        .sheet(isPresented: $store.isSetupAssistantPresented) {
            SetupAssistantView()
                .environmentObject(store)
        }
        .onAppear {
            updater.start()
            restoreSelectedSection()
            if !store.hasCompletedSetup {
                store.requestSetupAssistant()
            } else {
                evaluateInitialReadiness(store.runtimeStatus)
            }
        }
        .onChange(of: store.hasCompletedSetup) { _, completed in
            if completed {
                store.isSetupAssistantPresented = false
            }
        }
        .onChange(of: store.selectedSection) { _, selection in
            selectedSectionRawValue = selection.rawValue
        }
        .onChange(of: store.isPresentingContainerDetail) { _, isPresented in
            withAnimation(.snappy(duration: 0.28)) {
                columnVisibility = isPresented ? .detailOnly : .all
            }
        }
        .onChange(of: store.runtimeStatus) { _, status in
            evaluateInitialReadiness(status)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.refreshRuntimeStatus()
            updater.checkForUpdatesIfNeeded()
        }
        .focusedSceneValue(
            \.requestStopAllWindowsAppsConfirmation,
            {
                stopAllWindowsAppsConfirmation.request()
            }
        )
        .confirmationDialog(
            "Stop all Windows apps?",
            isPresented: stopAllWindowsAppsConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Stop All Windows Apps", role: .destructive) {
                guard stopAllWindowsAppsConfirmation.confirm() else { return }
                Task {
                    await store.stopAllWindowsApps()
                }
            }
            .disabled(
                !store.hasRunningContainers
                    || store.isStoppingAllWindowsApps
            )

            Button("Cancel", role: .cancel) {
                stopAllWindowsAppsConfirmation.cancel()
            }
        } message: {
            Text("All running Windows apps will close. Unsaved work may be lost.")
        }
        .alert(
            String(localized: "Error", bundle: SwitchyardStrings.bundle),
            isPresented: updateErrorBinding
        ) {
            Button("OK") {
                updater.dismissError()
            }
        } message: {
            if let errorMessage = updater.errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var stopAllWindowsAppsConfirmationBinding: Binding<Bool> {
        Binding {
            stopAllWindowsAppsConfirmation.isPresented
        } set: { isPresented in
            if isPresented {
                stopAllWindowsAppsConfirmation.request()
            } else {
                stopAllWindowsAppsConfirmation.cancel()
            }
        }
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding {
            store.selectedSection
        } set: { newValue in
            selectSection(newValue)
        }
    }

    private var updateErrorBinding: Binding<Bool> {
        Binding {
            updater.errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                updater.dismissError()
            }
        }
    }

    private func restoreSelectedSection() {
        selectSection(SidebarSelection(rawValue: selectedSectionRawValue) ?? .containers)
    }

    private func selectSection(_ selection: SidebarSelection) {
        selectedSectionRawValue = selection.rawValue
        store.selectedSection = selection
    }

    private func evaluateInitialReadiness(_ status: RuntimeStatus) {
        guard !hasEvaluatedInitialReadiness else { return }
        let requirement = GuidedSetupPolicy.nextRequirement(for: status)
        guard requirement != .checking else { return }
        hasEvaluatedInitialReadiness = true
        if store.hasCompletedSetup && requirement != .ready {
            store.requestSetupAssistant()
        }
    }
}

private extension View {
    @ViewBuilder
    func hidingDefaultToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}
