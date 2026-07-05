import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("autoOpenLogsOnFailure") private var autoOpenLogsOnFailure = true
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @AppStorage("defaultDPI") private var defaultDPI = 144.0
    @AppStorage("developerLogging") private var developerLogging = true

    var body: some View {
        TabView(selection: $store.selectedSettingsTab) {
            Form {
                PathPickerRow(title: "Storage", message: "Choose the Switchyard storage folder.", path: $store.libraryPath) {
                    store.persistPreferences()
                }
                Toggle("Auto-open logs on failure", isOn: $autoOpenLogsOnFailure)
                Toggle("Check for updates", isOn: $checkForUpdates)
            }
            .padding()
            .tag(SettingsTab.general)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                PathPickerRow(title: "GPTK", message: "Choose your local Apple Game Porting Toolkit installation.", path: $store.gptkPath) {
                    store.refreshRuntimeStatus()
                }
                StatusBadge(status: store.runtimeStatus.gptk, label: store.runtimeStatus.gptk.label)
                Text("Switchyard does not bundle GPTK. Choose your own Apple-provided installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .tag(SettingsTab.gptk)
            .tabItem { Label("GPTK", systemImage: "cube.transparent") }

            Form {
                PathPickerRow(title: "Wine", message: "Choose a Wine executable or a Wine runtime folder.", path: $store.winePath) {
                    store.refreshRuntimeStatus()
                }
                StatusBadge(status: store.runtimeStatus.wine, label: store.runtimeStatus.wine.label)
                Text("A default cache path is not enough; Diagnostics require an actual executable such as bin/wine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Runtime Channel", value: "local-source-cache")
                LabeledContent("Patch Series", value: "switchyard-v1")
                Button("Re-run Runtime Diagnostics") {
                    store.refreshRuntimeStatus()
                }
            }
            .padding()
            .tag(SettingsTab.wine)
            .tabItem { Label("Wine & Patches", systemImage: "wrench.and.screwdriver") }

            Form {
                Slider(value: $defaultDPI, in: 96...240, step: 12) {
                    Text("Default DPI")
                }
                LabeledContent("Renderer", value: "D3DMetal when GPTK is valid")
                LabeledContent("Container Template", value: "Per-launcher isolated prefix")
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
            .tag(SettingsTab.launchDefaults)
            .tabItem { Label("Launch Defaults", systemImage: "slider.horizontal.3") }

            Form {
                Toggle("Developer logging", isOn: $developerLogging)
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
        .frame(width: 620, height: 360)
    }
}
