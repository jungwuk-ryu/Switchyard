import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("selectedSection") private var selectedSectionRawValue = SidebarSelection.gamesLaunchers.rawValue
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
                    store.addLauncher()
                } label: {
                    Label("Add Launcher", systemImage: "plus")
                }

                Button {
                    store.runSelectedLauncher()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }

                Button {
                    store.stopRunningOperations()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }

                Button {
                    store.selectedSection = .logs
                } label: {
                    Label("Open Logs", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    store.showInspector.toggle()
                } label: {
                    Label("Toggle Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .sheet(isPresented: $showsSetup) {
            SetupAssistantView()
                .environmentObject(store)
        }
        .onAppear {
            if !store.hasCompletedSetup {
                showsSetup = true
            }
        }
        .onChange(of: store.hasCompletedSetup) { _, completed in
            showsSetup = !completed
        }
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding {
            SidebarSelection(rawValue: selectedSectionRawValue) ?? store.selectedSection
        } set: { newValue in
            selectedSectionRawValue = newValue.rawValue
            store.selectedSection = newValue
        }
    }
}
