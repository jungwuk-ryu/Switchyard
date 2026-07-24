import AppCore
import SwiftUI

struct SetupAssistantView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var hasStarted = false
    @State private var isSettingUpSteam = false
    @State private var isConfirmingStopAll = false
    @State private var isStoppingAppsForSetup = false
    @State private var setupStopError: String?

    private var requirement: GuidedSetupRequirement {
        GuidedSetupPolicy.nextRequirement(for: store.runtimeStatus)
    }

    var body: some View {
        VStack(spacing: 0) {
            setupHeader
                .padding(24)

            Divider()

            ScrollView {
                setupContent
                    .frame(maxWidth: 660, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            setupFooter
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 820)
        .frame(minHeight: 610, idealHeight: 660)
        .interactiveDismissDisabled(isBusy)
        .task {
            store.refreshRuntimeStatus()
        }
        .task(id: automaticSetupTaskID) {
            guard hasStarted,
                  !isSettingUpSteam,
                  requirement == .runtime,
                  store.canChangeCompatibilityConfiguration else { return }
            store.installCompatibleWineRuntimeIfNeeded()
        }
        .task(id: downloadScanTaskID) {
            guard shouldScanDownloads else { return }
            while !Task.isCancelled {
                store.refreshDownloadedInstallers()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if shouldScanDownloads {
                store.refreshDownloadedInstallers()
            }
            store.refreshRuntimeStatus()
        }
        .onChange(of: store.steamInstallationState) { _, state in
            guard case .installed = state else { return }
            finishSetup()
        }
        .confirmationDialog(
            "Stop all Windows apps?",
            isPresented: $isConfirmingStopAll,
            titleVisibility: .visible
        ) {
            Button("Stop All Windows Apps", role: .destructive) {
                stopRunningAppsAndResume()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved work in Windows apps may be lost. Switchyard needs them closed before changing compatibility files.")
        }
        .sheet(
            item: Binding(
                get: { store.gptkComponentConsentRequest },
                set: { request in
                    if request == nil {
                        store.dismissGPTKComponentConsent()
                    }
                }
            )
        ) { request in
            GPTKComponentLicenseConsentView(
                request: request,
                cancel: {
                    store.dismissGPTKComponentConsent()
                },
                accept: {
                    store.acceptGPTKComponentConsent(requestID: request.id)
                }
            )
        }
    }

    private var setupHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "switch.2")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(.largeTitle.weight(.semibold))
                    Text(headerSubtitle)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 12) {
                ProgressView(value: progressValue, total: 4)
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue(progressLabel)
                Text(progressLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        if !hasStarted {
            welcomeContent
        } else if isSettingUpSteam {
            steamContent
        } else {
            switch requirement {
            case .checking:
                checkingContent
            case .unsupportedMac:
                unsupportedContent
            case .rosetta:
                rosettaContent
            case .runtime:
                runtimeContent
            case .toolkit:
                toolkitContent
            case .ready:
                readyContent
            }
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Run Windows apps without learning Windows setup tools", systemImage: "sparkles")
                .font(.title2.weight(.semibold))

            Text(
                store.canDownloadGPTKAutomatically
                    ? "Switchyard will check this Mac, download its compatibility files, and show Apple's license before retrieving the reviewed GPTK 3 component. Your apps and games stay on this Mac."
                    : "Switchyard will check this Mac, download its compatibility files, and guide you through the one Apple download it cannot provide itself. Your apps and games stay on this Mac."
            )
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                WelcomeFeature(
                    icon: "checkmark.shield",
                    title: String(
                        localized: "Safe, matching runtime",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "The app verifies the exact signed runtime made for this version of Switchyard.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                WelcomeFeature(
                    icon: "folder.badge.gearshape",
                    title: String(
                        localized: "Sensible defaults",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "Storage and technical paths are chosen automatically. You can change them under Advanced Options.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                WelcomeFeature(
                    icon: "gamecontroller",
                    title: String(
                        localized: "Steam next",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "When Switchyard is ready, it can take you directly to the official Windows Steam installer.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
            }

            Label("Allow about 5–15 minutes and roughly 1 GB of free space. Download time depends on your connection.", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var checkingContent: some View {
        SetupCenteredProgress(
            title: String(
                localized: "Checking this Mac…",
                bundle: SwitchyardStrings.bundle
            ),
            detail: String(
                localized: "This normally takes only a moment.",
                bundle: SwitchyardStrings.bundle
            )
        )
    }

    private var unsupportedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("This Mac is not supported", systemImage: "xmark.octagon.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("Switchyard currently requires an Apple Silicon Mac running macOS 14 or later.")
                .font(.title3)
                .foregroundStyle(.secondary)
            friendlyDiagnostics
        }
    }

    private var rosettaContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeading(
                icon: "apple.logo",
                title: String(
                    localized: "Install Apple's compatibility support",
                    bundle: SwitchyardStrings.bundle
                ),
                detail: String(
                    localized: "Rosetta 2 lets this Apple Silicon Mac open the Intel-based part of the Windows runtime.",
                    bundle: SwitchyardStrings.bundle
                )
            )

            Text("Clicking Install opens Apple's Rosetta installer and accepts Apple's Rosetta software license. macOS handles any approval that is required.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = store.rosettaInstallationState.errorMessage {
                ErrorBanner(
                    title: String(
                        localized: "Rosetta was not installed",
                        bundle: SwitchyardStrings.bundle
                    ),
                    message: message
                )
            }

            Button {
                store.installRosetta(licenseNoticeAccepted: true)
            } label: {
                if store.rosettaInstallationState.isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing Rosetta 2…")
                } else {
                    Label("Accept and Install Rosetta 2", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.rosettaInstallationState.isWorking)
            .accessibilityIdentifier("setup.rosetta.install")
        }
    }

    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeading(
                icon: "shippingbox.and.arrow.backward",
                title: String(
                    localized: "Preparing Windows support",
                    bundle: SwitchyardStrings.bundle
                ),
                detail: String(
                    localized: "Switchyard is downloading and verifying the files it needs. Keep the app open while this finishes.",
                    bundle: SwitchyardStrings.bundle
                )
            )

            runningAppsBlocker

            SetupStatusLine(
                title: String(
                    localized: "Windows compatibility files",
                    bundle: SwitchyardStrings.bundle
                ),
                detail: runtimeStatusDetail,
                status: store.runtimeStatus.wine == .ok && store.runtimeStatus.wineSource == .ok
                    ? .ok
                    : (runtimeFailed ? .warning : .unknown),
                showsProgress: store.runtimeInstallationState.isWorking
            )
            .accessibilityIdentifier("setup.runtime.progress")

            SetupStatusLine(
                title: String(
                    localized: "Fonts for Korean, Japanese, and other languages",
                    bundle: SwitchyardStrings.bundle
                ),
                detail: fontStatusDetail,
                status: fontStatus,
                showsProgress: store.fontPackPreparationState.isWorking
            )

            if case .failed(let message) = store.runtimeInstallationState {
                ErrorBanner(
                    title: String(
                        localized: "Download could not finish",
                        bundle: SwitchyardStrings.bundle
                    ),
                    message: message
                )
                Button("Try Again") {
                    store.installCompatibleWineRuntime()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canChangeCompatibilityConfiguration)
            }

            Text("The main runtime download is about 700 MB. Switchyard checks its size, fingerprint, developer signature, and Apple notarization before using it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var toolkitContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeading(
                icon: "cube.transparent",
                title: String(
                    localized: "Get Apple's graphics support",
                    bundle: SwitchyardStrings.bundle
                ),
                detail: store.canDownloadGPTKAutomatically
                    ? String(
                        localized: "Review Apple's license, then let Switchyard download and verify the approved GPTK 3 component.",
                        bundle: SwitchyardStrings.bundle
                    )
                    : String(
                        localized: "This release opens Apple's download page so you can sign in, review its terms, and choose the toolkit copy to import.",
                        bundle: SwitchyardStrings.bundle
                    )
            )

            runningAppsBlocker

            if store.gptkComponentDownloadState == .preparingConsent {
                SetupCenteredProgress(
                    title: String(
                        localized: "Loading the reviewed Apple license…",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "The component archive will not download until you review and acknowledge the license.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
            } else if store.gptkComponentDownloadState == .downloading {
                SetupCenteredProgress(
                    title: String(
                        localized: "Downloading and verifying GPTK 3…",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "Switchyard is checking the signed manifest, file tree, notices, and Apple code signature.",
                        bundle: SwitchyardStrings.bundle
                    )
                )

                Button("Cancel Download") {
                    store.cancelGPTKComponentDownload()
                }
            } else if store.isImportingGPTK {
                SetupCenteredProgress(
                    title: String(
                        localized: "Checking and importing the Apple download…",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "Switchyard verifies the executable code before copying it into its private cache.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
            } else if let downloadedPath = store.downloadedGPTKDiskImagePath {
                SetupFoundDownload(
                    fileName: URL(fileURLWithPath: downloadedPath).lastPathComponent,
                    detail: String(
                        localized: "The download is ready. Switchyard will verify Apple's signature before importing it.",
                        bundle: SwitchyardStrings.bundle
                    )
                )

                Button("Verify and Continue") {
                    store.importLatestDownloadedGPTK()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!store.canChangeCompatibilityConfiguration)
                .accessibilityIdentifier("setup.gptk.import")
            } else if store.canDownloadGPTKAutomatically {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Switchyard will show the exact Apple license before downloading.",
                        systemImage: "doc.text"
                    )
                    Label(
                        "The separate component is verified against the reviewed GPTK 3 identity.",
                        systemImage: "checkmark.shield"
                    )
                    Label(
                        "Apple's official download remains available below.",
                        systemImage: "safari"
                    )
                }
                .font(.callout)

                HStack {
                    Button("Review License and Download") {
                        store.prepareAutomaticGPTKDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!store.canChangeCompatibilityConfiguration)
                    .accessibilityIdentifier("setup.gptk.automaticDownload")

                    Button("Download from Apple") {
                        store.openGPTKDownloadPage()
                    }

                    Button("Choose Downloaded File…") {
                        store.chooseGPTKDiskImageAndImport()
                    }
                    .disabled(!store.canChangeCompatibilityConfiguration)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("1. Open Apple's download page", systemImage: "safari")
                    Label("2. Sign in and download the newest Game Porting Toolkit .dmg", systemImage: "arrow.down")
                    Label("3. Return here — Switchyard will find it automatically", systemImage: "arrow.uturn.backward")
                }
                .font(.callout)

                HStack {
                    Button("Download from Apple") {
                        store.openGPTKDownloadPage()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("setup.gptk.download")

                    Button("Choose Downloaded File…") {
                        store.chooseGPTKDiskImageAndImport()
                    }
                    .disabled(!store.canChangeCompatibilityConfiguration)
                }
            }

            if let message = store.gptkSetupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            advancedOptions
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Switchyard is ready", systemImage: "checkmark.circle.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(.green)

            Text("The compatibility runtime and Apple's graphics support are ready. You can now install a Windows app.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                SetupStatusLine(
                    title: String(localized: "This Mac", bundle: SwitchyardStrings.bundle),
                    detail: String(localized: "Compatible", bundle: SwitchyardStrings.bundle),
                    status: .ok
                )
                SetupStatusLine(
                    title: String(
                        localized: "Windows support",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "Installed and verified",
                        bundle: SwitchyardStrings.bundle
                    ),
                    status: .ok
                )
                SetupStatusLine(
                    title: String(
                        localized: "Apple graphics support",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "Imported and verified",
                        bundle: SwitchyardStrings.bundle
                    ),
                    status: .ok
                )
            }

            Button {
                isSettingUpSteam = true
                if store.downloadedSteamInstallerPath == nil {
                    store.downloadSteamInstaller()
                }
            } label: {
                Label("Set Up Steam", systemImage: "gamecontroller.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("setup.steam.start")

            Text("Steam is optional. You can finish now and install any Windows .exe later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var steamContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupStepHeading(
                icon: "gamecontroller.fill",
                title: String(
                    localized: "Install Steam for Windows",
                    bundle: SwitchyardStrings.bundle
                ),
                detail: String(
                    localized: "Steam will be kept in its own private Switchyard container. Games installed through Steam will stay there too.",
                    bundle: SwitchyardStrings.bundle
                )
            )

            if store.steamInstallationState.isWorking {
                SetupCenteredProgress(
                    title: steamWorkingTitle,
                    detail: store.steamInstallationState.isInstallerOpen
                        ? String(
                            localized: "Finish the standard Steam installer. Switchyard will detect Steam and continue automatically.",
                            bundle: SwitchyardStrings.bundle
                        )
                        : String(
                            localized: "The standard Windows installer will appear in a moment.",
                            bundle: SwitchyardStrings.bundle
                        )
                )
                if store.steamInstallationState.isInstallerOpen {
                    Button("Stop Steam Setup") {
                        store.cancelSteamInstallation()
                    }
                    .disabled(
                        store.steamInstallationState.containerID.map {
                            store.isStoppingWineServer(in: $0)
                        } ?? true
                    )
                }
            } else if store.isDownloadingSteamInstaller {
                SetupCenteredProgress(
                    title: String(
                        localized: "Downloading securely from Valve…",
                        bundle: SwitchyardStrings.bundle
                    ),
                    detail: String(
                        localized: "Switchyard accepts only the official HTTPS download and keeps it in a private cache.",
                        bundle: SwitchyardStrings.bundle
                    )
                )

                HStack {
                    Button("Cancel Download") {
                        store.cancelSteamDownloadWait()
                    }
                }
            } else if let downloadedPath = store.downloadedSteamInstallerPath {
                SetupFoundDownload(
                    fileName: URL(fileURLWithPath: downloadedPath).lastPathComponent,
                    detail: String(
                        localized: "This Windows installer is ready to open in Switchyard.",
                        bundle: SwitchyardStrings.bundle
                    )
                )

                Button("Install Steam") {
                    store.installSteam()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("setup.steam.install")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Switchyard downloads SteamSetup.exe directly from Valve over HTTPS.", systemImage: "lock.shield")
                    Label("The file is checked and stored only on this Mac.", systemImage: "internaldrive")
                }
                .font(.callout)

                Button("Download Steam") {
                    store.downloadSteamInstaller()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("setup.steam.download")
            }

            if let message = store.steamInstallationState.errorMessage {
                ErrorBanner(
                    title: String(
                        localized: "Steam could not be started",
                        bundle: SwitchyardStrings.bundle
                    ),
                    message: message
                )
            } else if let message = store.steamSetupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Switchyard downloads only Valve's installer. The normal Steam screens handle games, updates, and account sign-in.", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedOptions: some View {
        DisclosureGroup("Advanced Options") {
            VStack(alignment: .leading, spacing: 12) {
                PathPickerRow(
                    title: String(localized: "Storage", bundle: SwitchyardStrings.bundle),
                    message: String(
                        localized: "Choose where Switchyard stores containers and manifests.",
                        bundle: SwitchyardStrings.bundle
                    ),
                    path: $store.libraryPath
                ) {
                    store.persistPreferences()
                }
                PathPickerRow(
                    title: String(localized: "Toolkit", bundle: SwitchyardStrings.bundle),
                    message: String(
                        localized: "Choose a local GPTK directory or disk image.",
                        bundle: SwitchyardStrings.bundle
                    ),
                    path: gptkPathBinding
                ) {}
                .disabled(
                    !store.canChangeCompatibilityConfiguration
                        || store.isImportingGPTK
                        || store.gptkComponentDownloadState.isWorking
                )
                if URL(fileURLWithPath: store.gptkPath).pathExtension.lowercased() == "dmg" {
                    Button("Import Selected Toolkit") {
                        store.importSelectedGPTKDiskImage()
                    }
                    .disabled(
                        store.isImportingGPTK
                            || store.gptkComponentDownloadState.isWorking
                            || !store.canChangeCompatibilityConfiguration
                    )
                }
#if DEBUG
                PathPickerRow(
                    title: String(
                        localized: "Development Runtime",
                        bundle: SwitchyardStrings.bundle
                    ),
                    message: String(
                        localized: "Choose a locally built Wine executable or runtime folder.",
                        bundle: SwitchyardStrings.bundle
                    ),
                    path: $store.winePath
                ) {
                    store.useSelectedLocalDevelopmentRuntime()
                }
                .disabled(
                    !store.canChangeCompatibilityConfiguration
                        || store.runtimeInstallationState.isWorking
                        || store.runtimeManagementState.isWorking
                )
#endif
            }
            .padding(.top, 12)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var friendlyDiagnostics: some View {
        VStack(spacing: 10) {
            SetupStatusLine(
                title: "Apple Silicon",
                detail: store.runtimeStatus.architecture == .ok
                    ? String(localized: "Compatible", bundle: SwitchyardStrings.bundle)
                    : String(localized: "Required", bundle: SwitchyardStrings.bundle),
                status: store.runtimeStatus.architecture
            )
            SetupStatusLine(
                title: String(
                    localized: "macOS 14 or later",
                    bundle: SwitchyardStrings.bundle
                ),
                detail: store.runtimeStatus.macOS == .ok
                    ? String(localized: "Compatible", bundle: SwitchyardStrings.bundle)
                    : String(
                        localized: "Update macOS to continue",
                        bundle: SwitchyardStrings.bundle
                    ),
                status: store.runtimeStatus.macOS
            )
        }
    }

    @ViewBuilder
    private var setupFooter: some View {
        HStack {
            if isSettingUpSteam {
                Button("Back") {
                    store.cancelSteamDownloadWait()
                    isSettingUpSteam = false
                }
                .disabled(store.steamInstallationState.isWorking)
            } else {
                Button(hasStarted ? "Set Up Later" : "Not Now") {
                    dismiss()
                }
                .disabled(isBusy)
            }

            Spacer()

            if !hasStarted {
                Button("Set Up Switchyard") {
                    hasStarted = true
                    store.beginGuidedSetup()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup.primaryAction")
            } else if isSettingUpSteam || requirement == .ready {
                Button("Finish Without Steam") {
                    finishSetup()
                }
                .disabled(!GuidedSetupPolicy.canComplete(with: store.runtimeStatus) || isBusy)
                .accessibilityIdentifier("setup.finish")
            }
        }
    }

    private var automaticSetupTaskID: String {
        "\(hasStarted)-\(isSettingUpSteam)-\(requirement.rawValue)"
    }

    private var gptkPathBinding: Binding<String> {
        Binding {
            store.gptkPath
        } set: { path in
            store.selectGPTKPath(path)
        }
    }

    private var downloadScanTaskID: String {
        "downloads-\(shouldScanDownloads)-\(requirement.rawValue)"
    }

    private var shouldScanDownloads: Bool {
        hasStarted && requirement == .toolkit
    }

    private var isBusy: Bool {
        store.runtimeInstallationState.isWorking
            || store.rosettaInstallationState.isWorking
            || store.isImportingGPTK
            || store.gptkComponentDownloadState.isWorking
            || store.steamInstallationState.isWorking
            || store.isDownloadingSteamInstaller
            || isStoppingAppsForSetup
    }

    private var runtimeFailed: Bool {
        if case .failed = store.runtimeInstallationState { return true }
        return false
    }

    private var steamWorkingTitle: String {
        if store.steamInstallationState == .preparing {
            return String(
                localized: "Preparing a place for Steam…",
                bundle: SwitchyardStrings.bundle
            )
        }
        if store.steamInstallationState.isInstallerOpen {
            return String(
                localized: "Finish installing Steam…",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Opening the Steam installer…",
            bundle: SwitchyardStrings.bundle
        )
    }

    private var runtimeStatusDetail: String {
        switch store.runtimeInstallationState {
        case .idle:
            String(localized: "Starting automatically…", bundle: SwitchyardStrings.bundle)
        case .working:
            String(
                localized: "Downloading and verifying about 700 MB…",
                bundle: SwitchyardStrings.bundle
            )
        case .ready:
            String(localized: "Installed and verified", bundle: SwitchyardStrings.bundle)
        case .failed:
            String(localized: "Needs another try", bundle: SwitchyardStrings.bundle)
        }
    }

    private var fontStatus: HealthStatus {
        switch store.fontPackPreparationState {
        case .ready: .ok
        case .failed: .warning
        case .idle, .working: .unknown
        }
    }

    private var fontStatusDetail: String {
        switch store.fontPackPreparationState {
        case .idle:
            String(localized: "Preparing automatically…", bundle: SwitchyardStrings.bundle)
        case .working:
            String(
                localized: "Downloading open-licensed fonts…",
                bundle: SwitchyardStrings.bundle
            )
        case .ready:
            String(localized: "Ready", bundle: SwitchyardStrings.bundle)
        case .failed:
            String(
                localized: "Optional — Switchyard will try again before launch",
                bundle: SwitchyardStrings.bundle
            )
        }
    }

    private var headerTitle: String {
        isSettingUpSteam
            ? String(localized: "One more step", bundle: SwitchyardStrings.bundle)
            : String(localized: "Set Up Switchyard", bundle: SwitchyardStrings.bundle)
    }

    private var headerSubtitle: String {
        isSettingUpSteam
            ? String(
                localized: "Install your first Windows app",
                bundle: SwitchyardStrings.bundle
            )
            : String(
                localized: "A guided setup with safe defaults",
                bundle: SwitchyardStrings.bundle
            )
    }

    private var progressValue: Double {
        guard hasStarted else { return 0 }
        if isSettingUpSteam { return 4 }
        return switch requirement {
        case .checking, .unsupportedMac, .rosetta: 1
        case .runtime: 2
        case .toolkit: 3
        case .ready: 3.5
        }
    }

    private var progressLabel: String {
        guard hasStarted else {
            return String(localized: "Ready to begin", bundle: SwitchyardStrings.bundle)
        }
        if isSettingUpSteam {
            return String(localized: "First app", bundle: SwitchyardStrings.bundle)
        }
        return switch requirement {
        case .checking:
            String(localized: "Checking Mac", bundle: SwitchyardStrings.bundle)
        case .unsupportedMac:
            String(localized: "Mac check", bundle: SwitchyardStrings.bundle)
        case .rosetta:
            String(localized: "Mac support", bundle: SwitchyardStrings.bundle)
        case .runtime:
            String(localized: "Windows support", bundle: SwitchyardStrings.bundle)
        case .toolkit:
            String(localized: "Apple graphics", bundle: SwitchyardStrings.bundle)
        case .ready:
            String(localized: "Ready", bundle: SwitchyardStrings.bundle)
        }
    }

    private func finishSetup() {
        guard store.completeSetup() else { return }
        store.cancelSteamDownloadWait()
        dismiss()
    }

    @ViewBuilder
    private var runningAppsBlocker: some View {
        if store.hasRunningContainers {
            ErrorBanner(
                title: String(
                    localized: "Close Windows apps to continue",
                    bundle: SwitchyardStrings.bundle
                ),
                message: String(
                    localized: "Compatibility files cannot be changed while a Windows app is still running.",
                    bundle: SwitchyardStrings.bundle
                ),
                actionTitle: isStoppingAppsForSetup
                    ? String(localized: "Stopping…", bundle: SwitchyardStrings.bundle)
                    : String(localized: "Stop and Continue", bundle: SwitchyardStrings.bundle)
            ) {
                guard !isStoppingAppsForSetup else { return }
                isConfirmingStopAll = true
            }
            .allowsHitTesting(!isStoppingAppsForSetup)
        }

        if let setupStopError {
            ErrorBanner(
                title: String(
                    localized: "Windows apps are still running",
                    bundle: SwitchyardStrings.bundle
                ),
                message: setupStopError
            )
        }
    }

    private func stopRunningAppsAndResume() {
        guard !isStoppingAppsForSetup else { return }
        let blockedRequirement = requirement
        setupStopError = nil
        isStoppingAppsForSetup = true
        Task {
            let stopped = await store.stopAllWindowsAppsForSetup()
            isStoppingAppsForSetup = false
            guard stopped else {
                setupStopError = String(
                    localized: "Switchyard could not close every Windows app. Save your work, close any remaining windows, and try again.",
                    bundle: SwitchyardStrings.bundle
                )
                return
            }

            switch blockedRequirement {
            case .runtime:
                store.installCompatibleWineRuntimeIfNeeded()
            case .toolkit:
                if store.downloadedGPTKDiskImagePath != nil {
                    store.importLatestDownloadedGPTK()
                }
            case .checking, .unsupportedMac, .rosetta, .ready:
                break
            }
        }
    }
}

private struct SetupStepHeading: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupStatusLine: View {
    let title: String
    let detail: String
    let status: HealthStatus
    var showsProgress = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: status.symbolName)
                        .foregroundStyle(status.tint)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SetupCenteredProgress: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct SetupFoundDownload: View {
    let fileName: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Download found")
                    .font(.headline)
                Text(fileName)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WelcomeFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
