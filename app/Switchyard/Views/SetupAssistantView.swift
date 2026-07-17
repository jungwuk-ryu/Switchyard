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
                  !store.hasRunningContainers else { return }
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

            Text("Switchyard will check this Mac, download its compatibility files, and guide you through the one Apple download it cannot provide itself. Your apps and games stay on this Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                WelcomeFeature(
                    icon: "checkmark.shield",
                    title: "Safe, matching runtime",
                    detail: "The app verifies the exact signed runtime made for this version of Switchyard."
                )
                WelcomeFeature(
                    icon: "folder.badge.gearshape",
                    title: "Sensible defaults",
                    detail: "Storage and technical paths are chosen automatically. You can change them under Advanced Options."
                )
                WelcomeFeature(
                    icon: "gamecontroller",
                    title: "Steam next",
                    detail: "When Switchyard is ready, it can take you directly to the official Windows Steam installer."
                )
            }

            Label("Allow about 5–15 minutes and roughly 1 GB of free space. Download time depends on your connection.", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var checkingContent: some View {
        SetupCenteredProgress(
            title: "Checking this Mac…",
            detail: "This normally takes only a moment."
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
                title: "Install Apple's compatibility support",
                detail: "Rosetta 2 lets this Apple Silicon Mac open the Intel-based part of the Windows runtime."
            )

            Text("Clicking Install opens Apple's Rosetta installer and accepts Apple's Rosetta software license. macOS handles any approval that is required.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = store.rosettaInstallationState.errorMessage {
                ErrorBanner(title: "Rosetta was not installed", message: message)
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
                title: "Preparing Windows support",
                detail: "Switchyard is downloading and verifying the files it needs. Keep the app open while this finishes."
            )

            runningAppsBlocker

            SetupStatusLine(
                title: "Windows compatibility files",
                detail: runtimeStatusDetail,
                status: store.runtimeStatus.wine == .ok && store.runtimeStatus.patchset == .ok
                    ? .ok
                    : (runtimeFailed ? .warning : .unknown),
                showsProgress: store.runtimeInstallationState.isWorking
            )
            .accessibilityIdentifier("setup.runtime.progress")

            SetupStatusLine(
                title: "Fonts for Korean, Japanese, and other languages",
                detail: fontStatusDetail,
                status: fontStatus,
                showsProgress: store.fontPackPreparationState.isWorking
            )

            if case .failed(let message) = store.runtimeInstallationState {
                ErrorBanner(title: "Download could not finish", message: message)
                Button("Try Again") {
                    store.installCompatibleWineRuntime()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.hasRunningContainers)
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
                title: "Get Apple's graphics support",
                detail: "Apple requires you to sign in and accept its terms before downloading Game Porting Toolkit. Switchyard cannot redistribute it."
            )

            runningAppsBlocker

            if store.isImportingGPTK {
                SetupCenteredProgress(
                    title: "Checking and importing the Apple download…",
                    detail: "Switchyard verifies the executable code before copying it into its private cache."
                )
            } else if let downloadedPath = store.downloadedGPTKDiskImagePath {
                SetupFoundDownload(
                    fileName: URL(fileURLWithPath: downloadedPath).lastPathComponent,
                    detail: "The download is ready. Switchyard will verify Apple's signature before importing it."
                )

                Button("Verify and Continue") {
                    store.importLatestDownloadedGPTK()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.hasRunningContainers)
                .accessibilityIdentifier("setup.gptk.import")
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
                SetupStatusLine(title: "This Mac", detail: "Compatible", status: .ok)
                SetupStatusLine(title: "Windows support", detail: "Installed and verified", status: .ok)
                SetupStatusLine(title: "Apple graphics support", detail: "Imported and verified", status: .ok)
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
                title: "Install Steam for Windows",
                detail: "Steam will be kept in its own private Switchyard container. Games installed through Steam will stay there too."
            )

            if store.steamInstallationState.isWorking {
                SetupCenteredProgress(
                    title: steamWorkingTitle,
                    detail: store.steamInstallationState.isInstallerOpen
                        ? "Finish the standard Steam installer. Switchyard will detect Steam and continue automatically."
                        : "The standard Windows installer will appear in a moment."
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
                    title: "Downloading securely from Valve…",
                    detail: "Switchyard accepts only the official HTTPS download and keeps it in a private cache."
                )

                HStack {
                    Button("Cancel Download") {
                        store.cancelSteamDownloadWait()
                    }
                }
            } else if let downloadedPath = store.downloadedSteamInstallerPath {
                SetupFoundDownload(
                    fileName: URL(fileURLWithPath: downloadedPath).lastPathComponent,
                    detail: "This Windows installer is ready to open in Switchyard."
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
                ErrorBanner(title: "Steam could not be started", message: message)
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
                    title: "Storage",
                    message: "Choose where Switchyard stores containers and manifests.",
                    path: $store.libraryPath
                ) {
                    store.persistPreferences()
                }
                PathPickerRow(
                    title: "Toolkit",
                    message: "Choose a local GPTK directory or disk image.",
                    path: $store.gptkPath
                ) {
                    store.refreshRuntimeStatus()
                }
                if URL(fileURLWithPath: store.gptkPath).pathExtension.lowercased() == "dmg" {
                    Button("Import Selected Toolkit") {
                        store.importSelectedGPTKDiskImage()
                    }
                    .disabled(store.isImportingGPTK)
                }
                PathPickerRow(
                    title: "Runtime",
                    message: "Choose a Wine executable or runtime folder manually.",
                    path: $store.winePath
                ) {
                    store.refreshRuntimeStatus()
                }
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
                detail: store.runtimeStatus.architecture == .ok ? "Compatible" : "Required",
                status: store.runtimeStatus.architecture
            )
            SetupStatusLine(
                title: "macOS 14 or later",
                detail: store.runtimeStatus.macOS == .ok ? "Compatible" : "Update macOS to continue",
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
            return "Preparing a place for Steam…"
        }
        if store.steamInstallationState.isInstallerOpen {
            return "Finish installing Steam…"
        }
        return "Opening the Steam installer…"
    }

    private var runtimeStatusDetail: String {
        switch store.runtimeInstallationState {
        case .idle: "Starting automatically…"
        case .working: "Downloading and verifying about 700 MB…"
        case .ready: "Installed and verified"
        case .failed: "Needs another try"
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
        case .idle: "Preparing automatically…"
        case .working: "Downloading open-licensed fonts…"
        case .ready: "Ready"
        case .failed: "Optional — Switchyard will try again before launch"
        }
    }

    private var headerTitle: String {
        isSettingUpSteam ? "One more step" : "Set Up Switchyard"
    }

    private var headerSubtitle: String {
        isSettingUpSteam
            ? "Install your first Windows app"
            : "A guided setup with safe defaults"
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
        guard hasStarted else { return "Ready to begin" }
        if isSettingUpSteam { return "First app" }
        return switch requirement {
        case .checking: "Checking Mac"
        case .unsupportedMac: "Mac check"
        case .rosetta: "Mac support"
        case .runtime: "Windows support"
        case .toolkit: "Apple graphics"
        case .ready: "Ready"
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
                title: "Close Windows apps to continue",
                message: "Compatibility files cannot be changed while a Windows app is still running.",
                actionTitle: isStoppingAppsForSetup ? "Stopping…" : "Stop and Continue"
            ) {
                guard !isStoppingAppsForSetup else { return }
                isConfirmingStopAll = true
            }
            .allowsHitTesting(!isStoppingAppsForSetup)
        }

        if let setupStopError {
            ErrorBanner(title: "Windows apps are still running", message: setupStopError)
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
                setupStopError = "Switchyard could not close every Windows app. Save your work, close any remaining windows, and try again."
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
