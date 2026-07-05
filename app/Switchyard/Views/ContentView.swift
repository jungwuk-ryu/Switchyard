import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("selectedSection") private var selectedSectionRawValue = SidebarSelection.containers.rawValue
    @State private var showsSetup = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: selectionBinding)
        } detail: {
            DetailView(selection: store.selectedSection)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.addContainer()
                } label: {
                    Label("Add Container", systemImage: "plus")
                }

                Button {
                    store.runSelectedContainer()
                } label: {
                    Label("Run Container", systemImage: "play.fill")
                }

                Button {
                    store.stopRunningOperations()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }

                Button {
                    selectSection(.logs)
                } label: {
                    Label("Open Logs", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .sheet(isPresented: $showsSetup) {
            SetupAssistantView()
                .environmentObject(store)
        }
        .onAppear {
            restoreSelectedSection()
            if !store.hasCompletedSetup {
                showsSetup = true
            }
        }
        .onChange(of: store.hasCompletedSetup) { _, completed in
            showsSetup = !completed
        }
        .onChange(of: store.selectedSection) { _, selection in
            selectedSectionRawValue = selection.rawValue
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
}
