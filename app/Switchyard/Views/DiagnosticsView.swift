import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: AppStore

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
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }

            List(store.diagnostics) { check in
                DiagnosticCheckRow(check: check) {
                    store.refreshRuntimeStatus()
                }
            }
        }
        .padding()
        .navigationTitle("Diagnostics")
    }
}
