import AppCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var appLanguageIdentifier =
        AppLanguagePreference.selectedIdentifier()
    @State private var isRestartingForLanguage = false
    @State private var languageRestartError: String?

    var body: some View {
        TabView(selection: $store.selectedSettingsTab) {
            generalSettings
                .tag(SettingsTab.general)
                .tabItem { Label("General", systemImage: "gearshape") }

            gptkSettings
                .tag(SettingsTab.gptk)
                .tabItem { Label("GPTK", systemImage: "cube.transparent") }

            RuntimeSettingsView()
                .tag(SettingsTab.wine)
                .tabItem { Label("Wine Runtime", systemImage: "wrench.and.screwdriver") }

            containerSetupSettings
                .tag(SettingsTab.containerSetup)
                .tabItem { Label("Container Setup", systemImage: "slider.horizontal.3") }

            DebugLogsSettingsView()
                .tag(SettingsTab.logs)
                .tabItem { Label("Logs", systemImage: "doc.text") }

            advancedSettings
                .tag(SettingsTab.advanced)
                .tabItem { Label("Advanced", systemImage: "terminal") }
        }
        .frame(width: 820, height: 640)
    }

    private var generalSettings: some View {
        SettingsPage(title: "General", systemImage: "gearshape.fill") {
            languageSettings

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Apple compatibility support") {
                        StatusBadge(
                            status: store.runtimeStatus.rosetta,
                            label: "Rosetta 2"
                        )
                    }

                    if store.runtimeStatus.architecture == .ok
                        && store.runtimeStatus.rosetta != .ok {
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
                        .buttonStyle(.borderedProminent)
                        .disabled(store.rosettaInstallationState.isWorking)
                    }

                    if let message = store.rosettaInstallationState.errorMessage {
                        SettingsNotice(
                            message: message,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .red
                        )
                    }
                }
                .padding(4)
            } label: {
                Label("System", systemImage: "desktopcomputer")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    PathPickerRow(
                        title: String(
                            localized: "Storage",
                            bundle: SwitchyardStrings.bundle
                        ),
                        message: String(
                            localized: "Choose the Switchyard storage folder.",
                            bundle: SwitchyardStrings.bundle
                        ),
                        path: $store.libraryPath
                    ) {
                        store.persistPreferences()
                    }

                    Text("Containers and portable manifests stay in this user-selected folder. Runtime caches and logs remain in their documented user-local locations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            } label: {
                Label("Storage", systemImage: "internaldrive")
            }
        }
    }

    private var languageSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(languageLabel) {
                    Picker(
                        languageLabel,
                        selection: $appLanguageIdentifier
                    ) {
                        Text(systemDefaultLabel)
                            .tag(AppLanguagePreference.systemIdentifier)
                        ForEach(AppLanguagePreference.options) { option in
                            Text(verbatim: option.displayName)
                                .tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .trailing)
                    .disabled(isRestartingForLanguage)
                    .onChange(of: appLanguageIdentifier) { _, identifier in
                        languageRestartError = nil
                        AppLanguagePreference.apply(identifier)
                    }
                }

                if appLanguageIdentifier
                    != AppLanguagePreference.selectionAtLaunch {
                    HStack(alignment: .center, spacing: 12) {
                        SettingsNotice(
                            message: String(
                                localized: "Restart Switchyard to apply the selected language.",
                                bundle: SwitchyardStrings.bundle
                            ),
                            systemImage: "arrow.clockwise.circle.fill",
                            color: .secondary
                        )

                        Button {
                            restartForLanguageChange()
                        } label: {
                            if isRestartingForLanguage {
                                ProgressView()
                                    .controlSize(.small)
                                Text(restartLabel)
                            } else {
                                Text(restartLabel)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(isRestartingForLanguage)
                    }

                    if let languageRestartError {
                        SettingsNotice(
                            message: languageRestartError,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .red
                        )
                    }
                }
            }
            .padding(4)
        } label: {
            Label(languageLabel, systemImage: "globe")
        }
    }

    private var languageLabel: String {
        String(localized: "Language", bundle: SwitchyardStrings.bundle)
    }

    private var systemDefaultLabel: String {
        String(localized: "System Default", bundle: SwitchyardStrings.bundle)
    }

    private var restartLabel: String {
        String(localized: "Restart", bundle: SwitchyardStrings.bundle)
    }

    private func restartForLanguageChange() {
        guard !isRestartingForLanguage else { return }
        isRestartingForLanguage = true
        languageRestartError = nil

        Task { @MainActor in
            do {
                try await AppLanguagePreference.restartApplication()
            } catch {
                languageRestartError = error.localizedDescription
                isRestartingForLanguage = false
            }
        }
    }

    private var gptkSettings: some View {
        SettingsPage(title: "GPTK", systemImage: "cube.transparent.fill") {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            gptkDownloadButton
                            gptkImportButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            gptkDownloadButton
                            gptkImportButton
                        }
                    }

                    Divider()

                    PathPickerRow(
                        title: "GPTK",
                        message: String(
                            localized: "Choose your local Apple Game Porting Toolkit installation.",
                            bundle: SwitchyardStrings.bundle
                        ),
                        path: $store.gptkPath
                    ) {
                        store.refreshRuntimeStatus()
                    }

                    if URL(fileURLWithPath: store.gptkPath)
                        .pathExtension.lowercased() == "dmg" {
                        Button("Import Selected GPTK") {
                            store.importSelectedGPTKDiskImage()
                        }
                        .disabled(store.isImportingGPTK)
                    }

                    HStack {
                        Text("GPTK")
                            .foregroundStyle(.secondary)
                        Spacer()
                        StatusBadge(
                            status: store.runtimeStatus.gptk,
                            label: store.runtimeStatus.gptk.label
                        )
                    }

                    if let message = store.gptkSetupMessage {
                        SettingsNotice(
                            message: message,
                            systemImage: "info.circle.fill",
                            color: .secondary
                        )
                    }

                    Text("Switchyard does not download or bundle GPTK. Apple handles sign-in and license acceptance; Switchyard imports only after checking the DMG's executable code for Apple signatures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            } label: {
                Label("GPTK", systemImage: "shippingbox")
            }
        }
    }

    private var containerSetupSettings: some View {
        SettingsPage(
            title: "Container Setup",
            systemImage: "slider.horizontal.3"
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Renderer", value: "D3DMetal when GPTK is valid")
                    LabeledContent(
                        "Container Template",
                        value: "Per-container Wine prefix"
                    )
                }
                .padding(4)
            } label: {
                Label("Renderer", systemImage: "display")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if let fontCheck = store.diagnostics.first(
                        where: { $0.id == "open-font-pack" }
                    ) {
                        HStack {
                            Text("Open Font Pack")
                                .foregroundStyle(.secondary)
                            Spacer()
                            StatusBadge(
                                status: fontCheck.status,
                                label: fontCheck.status.label
                            )
                        }
                        Text(fontCheck.result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Install Open Font Pack") {
                        store.ensureOpenFontPack()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Switchyard installs OFL Noto fonts into containers and maps common Windows font family names without bundling Microsoft fonts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            } label: {
                Label("Open Font Pack", systemImage: "textformat")
            }
        }
    }

    private var advancedSettings: some View {
        SettingsPage(title: "Advanced", systemImage: "terminal.fill") {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Copy Diagnostic Bundle") {
                        copyDiagnosticBundle()
                    }
                    .buttonStyle(.borderedProminent)

                    Divider()

                    Button("Reset Cached Setup State") {
                        store.hasCompletedSetup = false
                        store.persistPreferences()
                        store.requestSetupAssistant()
                    }
                }
                .padding(4)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }
    }

    private var gptkDownloadButton: some View {
        Button("Download from Apple") {
            store.openGPTKDownloadPage()
        }
        .buttonStyle(.borderedProminent)
    }

    private var gptkImportButton: some View {
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

    private func copyDiagnosticBundle() {
        let bundle = store.diagnosticBundle()
        guard let data = try? JSONEncoder().encode(bundle),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        ClipboardPrivacy.confirmAndCopy(
            title: String(
                localized: "Copy diagnostic bundle?",
                bundle: SwitchyardStrings.bundle
            ),
            message: String(
                localized: "Switchyard will redact common secrets and your home folder path before copying.",
                bundle: SwitchyardStrings.bundle
            ),
            text: text
        )
    }
}

struct SettingsPage<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                        .background(
                            .tint.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 11)
                        )
                    Text(title)
                        .font(.title2.weight(.semibold))
                }

                content
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsNotice: View {
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
