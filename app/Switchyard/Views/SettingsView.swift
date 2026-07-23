import AppCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("developerLogging") private var developerLogging = false
    @AppStorage("verboseWineLogging") private var verboseWineLogging = false

    var body: some View {
        let runtime = store.currentRuntime

        TabView(selection: $store.selectedSettingsTab) {
            Form {
                LabeledContent("Apple compatibility support") {
                    StatusBadge(status: store.runtimeStatus.rosetta, label: "Rosetta 2")
                }
                if store.runtimeStatus.architecture == .ok && store.runtimeStatus.rosetta != .ok {
                    Button {
                        store.installRosetta()
                    } label: {
                        if store.rosettaInstallationState.isWorking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing Rosetta 2…")
                        } else {
                            Text("Install Rosetta 2")
                        }
                    }
                    .disabled(store.rosettaInstallationState.isWorking)
                }
                if let message = store.rosettaInstallationState.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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
                Section("Active Runtime") {
                    RuntimeBuildSummaryView(runtime: runtime)
                    LabeledContent("Compatibility") {
                        StatusBadge(
                            status: runtimeCompatibilityStatus,
                            label: runtimeCompatibilityStatus == .ok ? "Compatible" : "Needs Attention"
                        )
                    }
                    Text(runtimeCompatibilityMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Switchyard uses this app-wide runtime for every container.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Runtime Management") {
                    Button {
                        store.installCompatibleWineRuntime()
                    } label: {
                        if store.runtimeInstallationState.isWorking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing Active Runtime…")
                        } else {
                            Label("Install or Update Active Runtime", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(store.runtimeInstallationState.isWorking)
                    if let message = store.runtimeInstallationState.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    PathPickerRow(title: "Active Runtime", message: "Choose the app-wide Wine executable or runtime folder.", path: $store.winePath) {
                        store.refreshRuntimeStatus()
                    }
                    .disabled(!store.canChangeActiveRuntime)
                    if !store.canChangeActiveRuntime {
                        Text("Wait for all container activity to stop before changing the active runtime.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Re-run Runtime Diagnostics") {
                        store.refreshRuntimeStatus()
                    }
                }

                Section {
                    DisclosureGroup("Technical Details") {
                        RuntimeBuildTechnicalDetailsView(runtime: runtime)
                            .padding(.top, 6)
                    }
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
                Text("When enabled, launches record Wine errors and warnings in a protected per-run file. Files omit argument values and are limited to 50 logs for 14 days in ~/Library/Application Support/Switchyard/Logs/DebugRuns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Verbose Wine logging", isOn: $verboseWineLogging)
                    .disabled(!developerLogging)
                Text("Verbose mode additionally records Wine fixme output and targeted SEH, graphics, and window-system traces. It can produce very large logs, so the live view is batched and keeps only its latest 5,000 entries while the protected file keeps the complete run output.")
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
                    store.requestSetupAssistant()
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
            ?? "Install the Switchyard runtime, then run diagnostics."
    }

    private var runtimeCompatibilityStatus: HealthStatus {
        store.runtimeStatus.wine == .ok
            ? store.runtimeStatus.patchset
            : store.runtimeStatus.wine
    }

    private var runtimeCompatibilityMessage: String {
        if store.runtimeStatus.wine == .ok && store.runtimeStatus.patchset == .ok {
            return "The active runtime is ready and matched to this version of Switchyard."
        }
        if store.runtimeStatus.wine == .ok {
            return "The runtime is runnable, but it does not match this version of Switchyard. Install the compatible runtime to continue."
        }
        return wineRuntimeMessage
    }
}
