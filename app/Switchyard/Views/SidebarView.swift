import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSelection.allCases) { item in
                SidebarRow(selection: item)
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
