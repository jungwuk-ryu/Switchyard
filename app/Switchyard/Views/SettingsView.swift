import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("developerLogging") private var developerLogging = false

    var body: some View {
        TabView(selection: $store.selectedSettingsTab) {
            Form {
                PathPickerRow(title: "Storage", message: "Choose the Switchyard storage folder.", path: $store.libraryPath) {
                    store.persistPreferences()
                }
                Text("Containers and portable manifests stay in this user-selected folder. Runtime caches and logs remain in their documented user-local locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tag(SettingsTab.general)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
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
                }
                PathPickerRow(title: "GPTK", message: "Choose your local Apple Game Porting Toolkit installation.", path: $store.gptkPath) {
                    store.refreshRuntimeStatus()
                }
                if URL(fileURLWithPath: store.gptkPath).pathExtension.lowercased() == "dmg" {
                    Button("Import Selected GPTK") {
                        store.importSelectedGPTKDiskImage()
                    }
                    .disabled(store.isImportingGPTK)
                }
                StatusBadge(status: store.runtimeStatus.gptk, label: store.runtimeStatus.gptk.label)
                if let message = store.gptkSetupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Switchyard does not download or bundle GPTK. Apple handles sign-in and license acceptance; Switchyard imports only after checking the DMG's executable code for Apple signatures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tag(SettingsTab.gptk)
            .tabItem { Label("GPTK", systemImage: "cube.transparent") }

            Form {
                Button {
                    store.installCompatibleWineRuntime()
                } label: {
                    if store.runtimeInstallationState.isWorking {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing Compatible Runtime…")
                    } else {
                        Label("Install or Update Compatible Runtime", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(store.runtimeInstallationState.isWorking)
                if let message = store.runtimeInstallationState.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PathPickerRow(title: "Wine", message: "Choose a Wine executable or a Wine runtime folder.", path: $store.winePath) {
                    store.refreshRuntimeStatus()
                }
                StatusBadge(status: store.runtimeStatus.wine, label: store.runtimeStatus.wine.label)
                Text(wineRuntimeMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Runtime Channel", value: store.currentRuntime.id)
                LabeledContent("Runtime Source", value: store.currentRuntime.patchsetID)
                LabeledContent(
                    "Source Revision",
                    value: store.currentRuntime.sourceRevision.isEmpty
                        ? "Unpinned"
                        : String(store.currentRuntime.sourceRevision.prefix(12))
                )
                Button("Re-run Runtime Diagnostics") {
                    store.refreshRuntimeStatus()
                }
            }
            .padding()
            .tag(SettingsTab.wine)
            .tabItem { Label("Wine Runtime", systemImage: "wrench.and.screwdriver") }

            Form {
                LabeledContent("Renderer", value: "D3DMetal when GPTK is valid")
                LabeledContent("Container Template", value: "Per-container Wine prefix")
                if let fontCheck = store.diagnostics.first(where: { $0.id == "open-font-pack" }) {
                    StatusBadge(status: fontCheck.status, label: fontCheck.status.label)
                    Text(fontCheck.result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Install Open Font Pack") {
                    store.ensureOpenFontPack()
                }
                Text("Switchyard installs OFL Noto fonts into containers and maps common Windows font family names without bundling Microsoft fonts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tag(SettingsTab.containerSetup)
            .tabItem { Label("Container Setup", systemImage: "slider.horizontal.3") }

            Form {
                Toggle("Developer logging", isOn: $developerLogging)
                Text("When enabled, launches include detailed Wine debug output. Per-run files omit argument values, are protected for your account only, and are limited to 50 logs for 14 days in ~/Library/Application Support/Switchyard/Logs/DebugRuns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy Diagnostic Bundle") {
                    let bundle = store.diagnosticBundle()
                    if let data = try? JSONEncoder().encode(bundle),
                       let text = String(data: data, encoding: .utf8) {
                        ClipboardPrivacy.confirmAndCopy(
                            title: "Copy diagnostic bundle?",
                            message: "Switchyard will redact common secrets and your home folder path before copying.",
                            text: text
                        )
                    }
                }
                Button("Reset Cached Setup State") {
                    store.hasCompletedSetup = false
                    store.persistPreferences()
                }
            }
            .padding()
            .tag(SettingsTab.advanced)
            .tabItem { Label("Advanced", systemImage: "terminal") }
        }
        .frame(width: 660, height: 440)
    }

    private var wineRuntimeMessage: String {
        store.diagnostics.first { $0.id == "wine-runtime" }?.result
            ?? "Choose a Wine executable or Switchyard Wine runtime folder, then run diagnostics."
    }
}
