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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarSettingsLink()
        }
    }
}

private struct SidebarRow: View {
    let selection: SidebarSelection

    var body: some View {
        Label(selection.title, systemImage: selection.symbolName)
            .tag(selection)
    }
}

private struct SidebarSettingsLink: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()

            SettingsLink {
                Label(
                    String(
                        localized: "Settings",
                        bundle: SwitchyardStrings.bundle
                    ),
                    systemImage: "gearshape"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(
                String(
                    localized: "Open Settings",
                    bundle: SwitchyardStrings.bundle
                )
            )
            .padding(10)
        }
        .background(.bar)
    }
}
