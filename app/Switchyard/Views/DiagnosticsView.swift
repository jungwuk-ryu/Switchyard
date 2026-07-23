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
                        title: String(
                            localized: "Setup is incomplete",
                            bundle: SwitchyardStrings.bundle
                        ),
                        message: String(
                            localized: "Resolve missing runtime components before running Windows executables.",
                            bundle: SwitchyardStrings.bundle
                        ),
                        actionTitle: String(
                            localized: "Open Settings",
                            bundle: SwitchyardStrings.bundle
                        )
                    ) {
                        openSettingsTab(preferredSettingsTab)
                    }
                }

                if let message = store.rosettaInstallationState.errorMessage {
                    ErrorBanner(
                        title: String(
                            localized: "Rosetta was not installed",
                            bundle: SwitchyardStrings.bundle
                        ),
                        message: message,
                        actionTitle: String(
                            localized: "Try Again",
                            bundle: SwitchyardStrings.bundle
                        )
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
        case let (.some(version), .some(build)):
            return String(
                localized: "Version \(version) (\(build))",
                bundle: SwitchyardStrings.bundle
            )
        case let (.some(version), .none):
            return String(localized: "Version \(version)", bundle: SwitchyardStrings.bundle)
        case let (.none, .some(build)):
            return String(localized: "Build \(build)", bundle: SwitchyardStrings.bundle)
        case (.none, .none):
            return String(localized: "Development build", bundle: SwitchyardStrings.bundle)
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
            return String(
                localized: "Checking this Mac and online releases",
                bundle: SwitchyardStrings.bundle
            )
        }
        if store.isRefreshingDiagnostics {
            return String(
                localized: "Checking current configuration",
                bundle: SwitchyardStrings.bundle
            )
        }
        if store.isCheckingOnlineReleases {
            return String(
                localized: "Checking latest online releases",
                bundle: SwitchyardStrings.bundle
            )
        }
        let refreshDates = [
            store.lastDiagnosticsRefreshDate,
            store.lastOnlineReleaseCheckDate
        ].compactMap { $0 }
        guard let lastRefresh = refreshDates.max() else {
            return String(
                localized: "Not checked in this session",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Last checked \(lastRefresh.formatted(date: .omitted, time: .standard))",
            bundle: SwitchyardStrings.bundle
        )
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
        runtime.buildNumber.map {
            String(localized: "Build \($0)", bundle: SwitchyardStrings.bundle)
        } ?? String(localized: "Build not available", bundle: SwitchyardStrings.bundle)
    }

    private var runtimeSourceLabel: String {
        runtime.sourceRevision.isEmpty
            ? String(
                localized: "Source revision not available",
                bundle: SwitchyardStrings.bundle
            )
            : String(
                localized: "Source \(runtime.sourceRevision.prefix(12))",
                bundle: SwitchyardStrings.bundle
            )
    }

    private var runtimePathLabel: String {
        runtime.winePath.isEmpty
            ? String(
                localized: "No Wine runtime selected",
                bundle: SwitchyardStrings.bundle
            )
            : runtime.winePath
    }

    private var runtime: RuntimeBuild {
        store.currentRuntime
    }

    private var appOnlineDetail: String {
        guard let release = store.onlineReleaseSnapshot?.appRelease else {
            return store.isCheckingOnlineReleases
                ? String(
                    localized: "Checking the latest GitHub release…",
                    bundle: SwitchyardStrings.bundle
                )
                : String(
                    localized: "Latest online release not available",
                    bundle: SwitchyardStrings.bundle
                )
        }
        if store.onlineReleaseError == nil {
            return String(
                localized: "Latest online: \(release.tagName) · \(release.publishedAt.formatted(date: .abbreviated, time: .omitted))",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Last known online: \(release.tagName) · \(release.publishedAt.formatted(date: .abbreviated, time: .omitted))",
            bundle: SwitchyardStrings.bundle
        )
    }

    private var runtimeOnlineDetail: String {
        guard let snapshot = store.onlineReleaseSnapshot,
              let runtimeRelease = snapshot.runtimeRelease,
              let runtimeManifest = snapshot.runtimeManifest else {
            return store.isCheckingOnlineReleases
                ? String(
                    localized: "Checking the latest GitHub runtime…",
                    bundle: SwitchyardStrings.bundle
                )
                : String(
                    localized: "Latest online runtime not available",
                    bundle: SwitchyardStrings.bundle
                )
        }
        if store.onlineReleaseError == nil {
            return String(
                localized: "Latest online: \(runtimeRelease.tagName) · source \(runtimeManifest.sourceRevision.prefix(12))",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Last known online: \(runtimeRelease.tagName) · source \(runtimeManifest.sourceRevision.prefix(12))",
            bundle: SwitchyardStrings.bundle
        )
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
        if store.isCheckingOnlineReleases {
            return String(localized: "Checking Online", bundle: SwitchyardStrings.bundle)
        }
        if store.onlineReleaseError != nil {
            return String(localized: "Check Failed", bundle: SwitchyardStrings.bundle)
        }
        guard store.onlineReleaseSnapshot != nil else {
            return String(localized: "Online Unknown", bundle: SwitchyardStrings.bundle)
        }
        if appUpdateAvailable {
            return String(localized: "Update Available", bundle: SwitchyardStrings.bundle)
        }
        guard let currentReleaseVersion, let latestReleaseVersion else {
            return String(localized: "Checked Online", bundle: SwitchyardStrings.bundle)
        }
        return currentReleaseVersion > latestReleaseVersion
            ? String(localized: "Newer Build", bundle: SwitchyardStrings.bundle)
            : String(localized: "Latest Online", bundle: SwitchyardStrings.bundle)
    }

    private var latestRuntimeMatchesAppPolicy: Bool {
        guard let manifest = store.onlineReleaseSnapshot?.runtimeManifest else { return false }
        return store.supportsOnlineRuntimeRelease(manifest)
    }

    private var selectedRuntimeMatchesLatest: Bool {
        guard let latestSource = store.onlineReleaseSnapshot?.runtimeManifest?.sourceRevision,
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
            && store.onlineReleaseSnapshot?.runtimeManifest != nil
            && latestRuntimeMatchesAppPolicy
            && (!selectedRuntimeMatchesLatest || !selectedRuntimeIsUsable)
            && store.canInstallCompatibleWineRuntime
    }

    private var runtimeUpdateStatus: HealthStatus {
        if store.isCheckingOnlineReleases || store.onlineReleaseError != nil { return .unknown }
        if store.onlineReleaseSnapshot?.runtimeManifest == nil { return .unknown }
        if !latestRuntimeMatchesAppPolicy { return .warning }
        return selectedRuntimeMatchesLatest && selectedRuntimeIsUsable ? .ok : .warning
    }

    private var runtimeUpdateLabel: String {
        if store.isCheckingOnlineReleases {
            return String(localized: "Checking Online", bundle: SwitchyardStrings.bundle)
        }
        if store.onlineReleaseError != nil {
            return String(localized: "Check Failed", bundle: SwitchyardStrings.bundle)
        }
        guard store.onlineReleaseSnapshot?.runtimeManifest != nil else {
            return String(localized: "Online Unknown", bundle: SwitchyardStrings.bundle)
        }
        if !latestRuntimeMatchesAppPolicy {
            return appUpdateAvailable
                ? String(
                    localized: "New App Recommended",
                    bundle: SwitchyardStrings.bundle
                )
                : String(
                    localized: "Not Recommended",
                    bundle: SwitchyardStrings.bundle
                )
        }
        return selectedRuntimeMatchesLatest && selectedRuntimeIsUsable
            ? String(localized: "Latest Online", bundle: SwitchyardStrings.bundle)
            : String(localized: "Update Available", bundle: SwitchyardStrings.bundle)
    }

    private var runtimeCompatibilityExplanation: String {
        guard store.onlineReleaseSnapshot?.runtimeManifest != nil else {
            return String(
                localized: "Switchyard pins one recommended runtime for automatic setup and verifies every manually selected official release before installation.",
                bundle: SwitchyardStrings.bundle
            )
        }
        if latestRuntimeMatchesAppPolicy {
            if selectedRuntimeMatchesLatest && selectedRuntimeIsUsable {
                return String(
                    localized: "The selected runtime is both the latest online release and the recommended revision for this Switchyard version.",
                    bundle: SwitchyardStrings.bundle
                )
            }
            return String(
                localized: "The latest online runtime is the recommended revision for this Switchyard version and can be installed here.",
                bundle: SwitchyardStrings.bundle
            )
        }
        if appUpdateAvailable {
            return String(
                localized: "A newer Switchyard release recommends the latest runtime. Other signed official versions remain available under Wine Runtime settings.",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "The latest online runtime is not this app version's recommendation. Other signed official versions remain available under Wine Runtime settings.",
            bundle: SwitchyardStrings.bundle
        )
    }
}
