import AppCore
import RuntimeCatalog
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Diagnostics")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text(store.runtimeStatus.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 5) {
                        Button {
                            store.refreshDiagnosticsAndUpdates()
                        } label: {
                            HStack(spacing: 6) {
                                if checksAreRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(checksAreRunning ? "Running…" : "Re-run All Checks")
                            }
                        }
                        .disabled(checksAreRunning)
                        .help("Check this Mac, the selected runtime, and the latest online releases again")

                        Text(diagnosticsActivityLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                DiagnosticsVersionOverview(
                    appVersion: runningAppVersion,
                    appVersionNumber: runningAppVersionNumber
                )

                if !store.runtimeStatus.canLaunch {
                    ErrorBanner(
                        title: "Setup is incomplete",
                        message: "Resolve missing runtime components before running Windows executables.",
                        actionTitle: "Open Settings"
                    ) {
                        openSettingsTab(preferredSettingsTab)
                    }
                }

                if let message = store.rosettaInstallationState.errorMessage {
                    ErrorBanner(
                        title: "Rosetta was not installed",
                        message: message,
                        actionTitle: "Try Again"
                    ) {
                        store.installRosetta()
                    }
                }

                LazyVStack(spacing: 0) {
                    ForEach(store.diagnostics) { check in
                        DiagnosticCheckRow(check: check) {
                            performRecovery(for: check)
                        }

                        if check.id != store.diagnostics.last?.id {
                            Divider()
                                .padding(.leading, 32)
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Diagnostics")
        .task {
            store.refreshOnlineReleaseStatus()
        }
    }

    private var preferredSettingsTab: SettingsTab {
        if store.runtimeStatus.rosetta != .ok {
            return .general
        }
        if store.runtimeStatus.gptk != .ok {
            return .gptk
        }
        if store.runtimeStatus.wine != .ok || store.runtimeStatus.patchset != .ok {
            return .wine
        }
        return .general
    }

    private var runningAppVersion: String {
        let version = runningAppVersionNumber
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)): return "Version \(version) (\(build))"
        case let (.some(version), .none): return "Version \(version)"
        case let (.none, .some(build)): return "Build \(build)"
        case (.none, .none): return "Development build"
        }
    }

    private var runningAppVersionNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var checksAreRunning: Bool {
        store.isRefreshingDiagnostics || store.isCheckingOnlineReleases
    }

    private var diagnosticsActivityLabel: String {
        if store.isRefreshingDiagnostics && store.isCheckingOnlineReleases {
            return "Checking this Mac and online releases"
        }
        if store.isRefreshingDiagnostics {
            return "Checking current configuration"
        }
        if store.isCheckingOnlineReleases {
            return "Checking latest online releases"
        }
        let refreshDates = [
            store.lastDiagnosticsRefreshDate,
            store.lastOnlineReleaseCheckDate
        ].compactMap { $0 }
        guard let lastRefresh = refreshDates.max() else {
            return "Not checked in this session"
        }
        return "Last checked \(lastRefresh.formatted(date: .omitted, time: .standard))"
    }

    private func performRecovery(for check: DiagnosticCheck) {
        switch check.id {
        case "rosetta" where check.recoveryAction != nil:
            store.installRosetta()
        case "gptk":
            openSettingsTab(.gptk)
        case "wine-runtime", "runtime-source":
            openSettingsTab(.wine)
        case "open-font-pack":
            store.ensureOpenFontPack()
        default:
            store.refreshRuntimeStatus()
        }
    }

    private func openSettingsTab(_ tab: SettingsTab) {
        store.selectedSettingsTab = tab
        openSettings()
    }
}

private struct DiagnosticsVersionOverview: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL

    let appVersion: String
    let appVersionNumber: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                appReleaseSection
                Divider()
                runtimeReleaseSection

                if let error = store.onlineReleaseError {
                    Label {
                        Text("Online check failed: \(error)")
                    } icon: {
                        Image(systemName: "wifi.exclamationmark")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                }
            }
        } label: {
            Text("Versions & Updates")
        }
    }

    private var appReleaseSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label("Switchyard", systemImage: "app.fill")
                    .font(.headline)
                Spacer()
                StatusBadge(status: appUpdateStatus, label: appUpdateLabel)
            }

            Text(appVersion)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .textSelection(.enabled)
            Text(appOnlineDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !store.isCheckingOnlineReleases,
               store.onlineReleaseError == nil,
               appUpdateAvailable,
               let releaseURL = store.onlineReleaseSnapshot?.appRelease.webURL {
                Button("View Update") {
                    openURL(releaseURL)
                }
                .help("Open the latest Switchyard release on GitHub")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runtimeReleaseSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label("Active Wine Runtime", systemImage: "shippingbox.fill")
                    .font(.headline)
                Spacer()
                StatusBadge(status: runtimeUpdateStatus, label: runtimeUpdateLabel)
            }

            Text(runtimeVersionLabel)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .textSelection(.enabled)
            Text(runtimeSourceLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(runtimeOnlineDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(runtimeCompatibilityExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(runtimePathLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(runtime.winePath)

            if let message = store.runtimeInstallationState.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shouldOfferRuntimeInstall {
                Button {
                    store.installCompatibleWineRuntime()
                } label: {
                    if store.runtimeInstallationState.isWorking {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing…")
                    } else {
                        Label("Install Latest Runtime", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(store.runtimeInstallationState.isWorking)
                .help("Download, verify, and select the latest runtime supported by this Switchyard version")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runtimeVersionLabel: String {
        runtime.buildNumber.map { "Build \($0)" } ?? "Build not available"
    }

    private var runtimeSourceLabel: String {
        runtime.sourceRevision.isEmpty
            ? "Source revision not available"
            : "Source \(runtime.sourceRevision.prefix(12))"
    }

    private var runtimePathLabel: String {
        runtime.winePath.isEmpty ? "No Wine runtime selected" : runtime.winePath
    }

    private var runtime: RuntimeBuild {
        store.currentRuntime
    }

    private var appOnlineDetail: String {
        guard let release = store.onlineReleaseSnapshot?.appRelease else {
            return store.isCheckingOnlineReleases
                ? "Checking the latest GitHub release…"
                : "Latest online release not available"
        }
        let prefix = store.onlineReleaseError == nil ? "Latest online" : "Last known online"
        return "\(prefix): \(release.tagName) · \(release.publishedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private var runtimeOnlineDetail: String {
        guard let snapshot = store.onlineReleaseSnapshot else {
            return store.isCheckingOnlineReleases
                ? "Checking the latest GitHub runtime…"
                : "Latest online runtime not available"
        }
        let prefix = store.onlineReleaseError == nil ? "Latest online" : "Last known online"
        return "\(prefix): \(snapshot.runtimeRelease.tagName) · source \(snapshot.runtimeManifest.sourceRevision.prefix(12))"
    }

    private var currentReleaseVersion: ReleaseVersion? {
        appVersionNumber.flatMap(ReleaseVersion.init)
    }

    private var latestReleaseVersion: ReleaseVersion? {
        store.onlineReleaseSnapshot.map(\.appRelease.tagName).flatMap(ReleaseVersion.init)
    }

    private var appUpdateAvailable: Bool {
        guard let currentReleaseVersion, let latestReleaseVersion else { return false }
        return currentReleaseVersion < latestReleaseVersion
    }

    private var appUpdateStatus: HealthStatus {
        if store.isCheckingOnlineReleases { return .unknown }
        if store.onlineReleaseError != nil { return .unknown }
        guard store.onlineReleaseSnapshot != nil else { return .unknown }
        guard let currentReleaseVersion, let latestReleaseVersion else { return .unknown }
        return currentReleaseVersion < latestReleaseVersion ? .warning : .ok
    }

    private var appUpdateLabel: String {
        if store.isCheckingOnlineReleases { return "Checking Online" }
        if store.onlineReleaseError != nil { return "Check Failed" }
        guard store.onlineReleaseSnapshot != nil else { return "Online Unknown" }
        if appUpdateAvailable { return "Update Available" }
        guard let currentReleaseVersion, let latestReleaseVersion else { return "Checked Online" }
        return currentReleaseVersion > latestReleaseVersion ? "Newer Build" : "Latest Online"
    }

    private var latestRuntimeMatchesAppPolicy: Bool {
        guard let manifest = store.onlineReleaseSnapshot?.runtimeManifest else { return false }
        return store.supportsOnlineRuntimeRelease(manifest)
    }

    private var selectedRuntimeMatchesLatest: Bool {
        guard let latestSource = store.onlineReleaseSnapshot?.runtimeManifest.sourceRevision,
              !runtime.sourceRevision.isEmpty else {
            return false
        }
        return runtime.sourceRevision == latestSource
    }

    private var selectedRuntimeIsUsable: Bool {
        store.runtimeStatus.wine == .ok && store.runtimeStatus.patchset == .ok
    }

    private var shouldOfferRuntimeInstall: Bool {
        !store.isCheckingOnlineReleases
            && store.onlineReleaseError == nil
            && store.onlineReleaseSnapshot != nil
            && latestRuntimeMatchesAppPolicy
            && (!selectedRuntimeMatchesLatest || !selectedRuntimeIsUsable)
            && store.canInstallCompatibleWineRuntime
    }

    private var runtimeUpdateStatus: HealthStatus {
        if store.isCheckingOnlineReleases || store.onlineReleaseError != nil { return .unknown }
        if store.onlineReleaseSnapshot == nil { return .unknown }
        if !latestRuntimeMatchesAppPolicy { return .warning }
        return selectedRuntimeMatchesLatest && selectedRuntimeIsUsable ? .ok : .warning
    }

    private var runtimeUpdateLabel: String {
        if store.isCheckingOnlineReleases { return "Checking Online" }
        if store.onlineReleaseError != nil { return "Check Failed" }
        guard store.onlineReleaseSnapshot != nil else { return "Online Unknown" }
        if !latestRuntimeMatchesAppPolicy {
            return appUpdateAvailable ? "New App Recommended" : "Not Recommended"
        }
        return selectedRuntimeMatchesLatest && selectedRuntimeIsUsable
            ? "Latest Online"
            : "Update Available"
    }

    private var runtimeCompatibilityExplanation: String {
        guard store.onlineReleaseSnapshot != nil else {
            return "Switchyard pins one recommended runtime for automatic setup and verifies every manually selected official release before installation."
        }
        if latestRuntimeMatchesAppPolicy {
            if selectedRuntimeMatchesLatest && selectedRuntimeIsUsable {
                return "The selected runtime is both the latest online release and the recommended revision for this Switchyard version."
            }
            return "The latest online runtime is the recommended revision for this Switchyard version and can be installed here."
        }
        if appUpdateAvailable {
            return "A newer Switchyard release recommends the latest runtime. Other signed official versions remain available under Wine Runtime settings."
        }
        return "The latest online runtime is not this app version's recommendation. Other signed official versions remain available under Wine Runtime settings."
    }
}
