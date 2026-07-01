import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                SidebarRow(selection: .gamesLaunchers)
                SidebarRow(selection: .bottles)
            }

            Section("Operations") {
                SidebarRow(selection: .running)
                SidebarRow(selection: .installQueue)
                SidebarRow(selection: .logs)
            }

            Section("Support") {
                SidebarRow(selection: .diagnostics)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Switchyard")
    }
}

private struct SidebarRow: View {
    let selection: SidebarSelection

    var body: some View {
        Label(selection.title, systemImage: selection.symbolName)
            .tag(selection)
    }
}
