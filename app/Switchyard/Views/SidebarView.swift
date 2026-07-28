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
            SidebarFooter()
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

private struct SidebarFooter: View {
    @EnvironmentObject private var updater: SwitchyardUpdater

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(spacing: 8) {
                if updater.isUpdateAvailable {
                    AppUpdateButton(
                        accessibilityIdentifier: "sidebar.app-update.install"
                    )
                }

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
            }
            .padding(10)
        }
        .background(.bar)
    }
}

struct AppUpdateButton: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var updater: SwitchyardUpdater

    let accessibilityIdentifier: String

    var body: some View {
        Button {
            updater.downloadAndInstall()
        } label: {
            HStack(spacing: 6) {
                if updater.isPresentingUpdate {
                    ProgressView()
                        .controlSize(.small)
                }
                Label(
                    String(
                        localized: "Download & Install",
                        bundle: SwitchyardStrings.bundle
                    ),
                    systemImage: "arrow.down.app.fill"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(
            !store.canChangeCompatibilityConfiguration
                || updater.isChecking
                || updater.isPresentingUpdate
        )
        .help(
            store.hasRunningContainers
                ? String(
                    localized: "Stop All Windows Apps",
                    bundle: SwitchyardStrings.bundle
                )
                : String(
                    localized: "Download & Install",
                    bundle: SwitchyardStrings.bundle
                )
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
