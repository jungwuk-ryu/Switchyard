import SwiftUI

struct SetupAssistantView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "switch.2")
                    .font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("Set Up Switchyard")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Prepare the local runtime paths before launching supported game launchers.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SetupStepRow(number: 1, title: "Check Apple Silicon and macOS", detail: "Diagnostics run automatically when the app opens.")
                PathPickerRow(title: "GPTK", message: "Choose your local Apple Game Porting Toolkit installation.", path: $store.gptkPath) {
                    store.refreshRuntimeStatus()
                }
                PathPickerRow(title: "Library", message: "Choose where Switchyard stores bottles and manifests.", path: $store.libraryPath) {
                    store.persistPreferences()
                }
                PathPickerRow(title: "Wine", message: "Choose a Wine executable or a Wine runtime folder.", path: $store.winePath) {
                    store.refreshRuntimeStatus()
                }
            }

            ErrorBanner(title: "User-provided GPTK only", message: "Switchyard links to your local Apple-provided GPTK install and does not include Apple binaries.")

            Spacer()

            HStack {
                Button("Read-only Mode") {
                    dismiss()
                }
                .help("Close setup. Running remains disabled until diagnostics pass.")

                Spacer()

                Button("Re-run Diagnostics") {
                    store.refreshRuntimeStatus()
                }

                Button("Finish Setup") {
                    store.completeSetup()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 520)
    }
}

private struct SetupStepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 24, height: 24)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
