import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection

    var body: some View {
        List(selection: $selection) {
            Section("Containers") {
                SidebarRow(selection: .containers)
            }

            Section("Activity") {
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
