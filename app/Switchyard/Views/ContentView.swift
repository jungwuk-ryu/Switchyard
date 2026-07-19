import AppCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedSection") private var selectedSectionRawValue = SidebarSelection.containers.rawValue
    @State private var hasEvaluatedInitialReadiness = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: selectionBinding)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            DetailView(selection: store.selectedSection)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
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
                    store.stopAllRuns()
                } label: {
                    Label("Stop All Runs", systemImage: "stop.fill")
                }
                .disabled(!store.hasRunningContainers)

                Button {
                    selectSection(.logs)
                } label: {
                    Label("Open Logs", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $store.isSetupAssistantPresented) {
            SetupAssistantView()
                .environmentObject(store)
        }
        .onAppear {
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
        .onChange(of: store.runtimeStatus) { _, status in
            evaluateInitialReadiness(status)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.refreshRuntimeStatus()
        }
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding {
            store.selectedSection
        } set: { newValue in
            selectSection(newValue)
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
