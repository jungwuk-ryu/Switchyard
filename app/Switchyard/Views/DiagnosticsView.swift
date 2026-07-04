import AppCore
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text(store.runtimeStatus.summary)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Re-run") {
                    store.refreshRuntimeStatus()
                }
            }

            if !store.runtimeStatus.canLaunch {
                ErrorBanner(
                    title: "Setup is incomplete",
                    message: "Resolve missing runtime components before running supported launchers.",
                    actionTitle: "Open Settings"
                ) {
                    openSettingsTab(preferredSettingsTab)
                }
            }

            List(store.diagnostics) { check in
                DiagnosticCheckRow(check: check) {
                    performRecovery(for: check)
                }
            }
        }
        .padding()
        .navigationTitle("Diagnostics")
    }

    private var preferredSettingsTab: SettingsTab {
        if store.runtimeStatus.gptk != .ok {
            return .gptk
        }
        if store.runtimeStatus.wine != .ok || store.runtimeStatus.patchset != .ok {
            return .wine
        }
        return .general
    }

    private func performRecovery(for check: DiagnosticCheck) {
        switch check.id {
        case "gptk":
            openSettingsTab(.gptk)
        case "wine-runtime", "patch-series":
            openSettingsTab(.wine)
        case "open-font-pack":
            store.ensureOpenFontPack()
        default:
            store.refreshRuntimeStatus()
        }
    }

    private func openSettingsTab(_ tab: SettingsTab) {
        store.selectedSettingsTab = tab
        openSettings()
    }
}
