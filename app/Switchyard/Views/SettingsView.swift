import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("autoOpenLogsOnFailure") private var autoOpenLogsOnFailure = true
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @AppStorage("defaultDPI") private var defaultDPI = 144.0
    @AppStorage("developerLogging") private var developerLogging = true

    var body: some View {
        TabView {
            Form {
                PathPickerRow(title: "Library", message: "Choose the Switchyard library folder.", path: $store.libraryPath) {
                    store.persistPreferences()
                }
                Toggle("Auto-open logs on failure", isOn: $autoOpenLogsOnFailure)
                Toggle("Check for updates", isOn: $checkForUpdates)
            }
            .padding()
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
            .tabItem { Label("GPTK", systemImage: "cube.transparent") }

            Form {
                PathPickerRow(title: "Wine", message: "Choose the cached Switchyard Wine executable.", path: $store.winePath) {
                    store.refreshRuntimeStatus()
                }
                LabeledContent("Runtime Channel", value: "local-source-cache")
                LabeledContent("Patch Series", value: "switchyard-v1")
                Button("Re-run Runtime Diagnostics") {
                    store.refreshRuntimeStatus()
                }
            }
            .padding()
            .tabItem { Label("Wine & Patches", systemImage: "wrench.and.screwdriver") }

            Form {
                Slider(value: $defaultDPI, in: 96...240, step: 12) {
                    Text("Default DPI")
                }
                LabeledContent("Renderer", value: "D3DMetal when GPTK is valid")
                LabeledContent("Bottle Template", value: "Per-launcher isolated prefix")
            }
            .padding()
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
            .tabItem { Label("Advanced", systemImage: "terminal") }
        }
        .frame(width: 620, height: 360)
    }
}
