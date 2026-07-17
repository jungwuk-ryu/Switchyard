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
                    Text("Install the compatible runtime and import your Apple toolkit.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SetupStepRow(number: 1, title: "Check Apple Silicon and macOS", detail: "Diagnostics run automatically when the app opens.")

                SetupStepRow(number: 2, title: "Install the Wine runtime", detail: "Switchyard downloads the latest signed release compatible with this app build.")
                HStack {
                    Button {
                        store.installCompatibleWineRuntime()
                    } label: {
                        if store.runtimeInstallationState.isWorking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing Runtime…")
                        } else {
                            Label("Install or Update Runtime", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(store.runtimeInstallationState.isWorking)
                    StatusBadge(status: store.runtimeStatus.wine, label: "Wine")
                }
                if let message = store.runtimeInstallationState.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SetupStepRow(number: 3, title: "Get Game Porting Toolkit", detail: "Apple sign-in and license acceptance stay on Apple's site; Switchyard imports the downloaded DMG.")
                HStack {
                    Button("Download from Apple") {
                        store.openGPTKDownloadPage()
                    }
                    Button {
                        store.importLatestDownloadedGPTK()
                    } label: {
                        if store.isImportingGPTK {
                            ProgressView()
                                .controlSize(.small)
                            Text("Verifying and Importing…")
                        } else {
                            Text("Import Downloaded GPTK")
                        }
                    }
                    .disabled(store.isImportingGPTK)
                    StatusBadge(status: store.runtimeStatus.gptk, label: "GPTK")
                }
                if let message = store.gptkSetupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PathPickerRow(title: "GPTK", message: "Or choose a local GPTK directory or disk image.", path: $store.gptkPath) {
                    store.refreshRuntimeStatus()
                }
                if URL(fileURLWithPath: store.gptkPath).pathExtension.lowercased() == "dmg" {
                    Button("Import Selected GPTK") {
                        store.importSelectedGPTKDiskImage()
                    }
                    .disabled(store.isImportingGPTK)
                }
                PathPickerRow(title: "Storage", message: "Choose where Switchyard stores containers and manifests.", path: $store.libraryPath) {
                    store.persistPreferences()
                }
                PathPickerRow(title: "Wine", message: "Optional: choose a runtime manually.", path: $store.winePath) {
                    store.refreshRuntimeStatus()
                }
            }

            ErrorBanner(title: "Apple download required", message: "Switchyard never redistributes GPTK. It imports only the copy you download from Apple after accepting Apple's terms.")

            Spacer()

            HStack {
                Button("Skip for Now") {
                    dismiss()
                }
                .help("Close setup for now. Running remains disabled until diagnostics pass.")

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
        .frame(width: 760, height: 650)
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
