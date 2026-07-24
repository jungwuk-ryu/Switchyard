import AppCore
import Foundation
import RuntimeCatalog
import SwiftUI

struct RuntimeSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                pageHeader
                activeRuntimeSection
                officialReleasesSection

                if !unmatchedInstallations.isEmpty {
                    otherManagedRuntimesSection
                }

#if DEBUG
                localDevelopmentRuntimeSection
#endif

                technicalDetailsSection
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            store.refreshOfficialRuntimeReleases()
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text("Wine Runtime")
                    .font(.title2.weight(.semibold))
                Text("The active runtime is used by every container.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 5) {
                Button {
                    store.refreshOfficialRuntimeReleases(force: true)
                } label: {
                    HStack(spacing: 6) {
                        if store.isRefreshingOfficialRuntimeReleases {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Check for Releases")
                    }
                }
                .disabled(store.isRefreshingOfficialRuntimeReleases)

                if let lastChecked = store.lastOfficialRuntimeCatalogRefreshDate {
                    Text(
                        String(
                            localized: "Last checked \(lastChecked.formatted(date: .omitted, time: .shortened))",
                            bundle: SwitchyardStrings.bundle
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var activeRuntimeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activeRuntimeTitle)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(activeRuntimeSubtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        if let activeRelease,
                           store.isRecommendedRuntime(activeRelease) {
                            RuntimePill(
                                title: String(
                                    localized: "Recommended",
                                    bundle: SwitchyardStrings.bundle
                                ),
                                color: .accentColor
                            )
                        }
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    RuntimeMetadataValue(
                        title: String(
                            localized: "Version Date",
                            bundle: SwitchyardStrings.bundle
                        ),
                        value: activeVersionDateLabel,
                        systemImage: "calendar"
                    )
                    RuntimeMetadataValue(
                        title: String(
                            localized: "Installed",
                            bundle: SwitchyardStrings.bundle
                        ),
                        value: activeInstalledDateLabel,
                        systemImage: "internaldrive"
                    )
                    RuntimeMetadataValue(
                        title: String(
                            localized: "Source Revision",
                            bundle: SwitchyardStrings.bundle
                        ),
                        value: activeSourceRevisionLabel,
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                }

                Divider()

                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: runtimeCompatibilityStatus == .ok
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundStyle(
                            runtimeCompatibilityStatus == .ok ? .green : .orange
                        )
                    Text(runtimeCompatibilityMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Re-run Runtime Diagnostics") {
                        store.refreshRuntimeStatus()
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Active Runtime", systemImage: "checkmark.seal.fill")
        }
    }

    private var officialReleasesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if !store.canInstallOfficialRuntimeReleases {
                    RuntimeSettingsNotice(
                        message: String(
                            localized: "This development build has no official Developer ID trust configuration. Release browsing remains available, but downloads are disabled.",
                            bundle: SwitchyardStrings.bundle
                        ),
                        systemImage: "hammer",
                        color: .secondary
                    )
                }

                if let error = store.officialRuntimeCatalogError {
                    RuntimeSettingsNotice(
                        message: error,
                        systemImage: "exclamationmark.triangle.fill",
                        color: .red
                    )
                }

                if let message = store.runtimeManagementState.message {
                    RuntimeSettingsNotice(
                        message: message,
                        systemImage: runtimeManagementMessageIsFailure
                            ? "xmark.circle.fill"
                            : "info.circle.fill",
                        color: runtimeManagementMessageIsFailure ? .red : .secondary,
                        showsProgress: store.runtimeManagementState.isWorking
                    )
                }

                if store.officialRuntimeReleases.isEmpty {
                    if store.isRefreshingOfficialRuntimeReleases {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking the latest GitHub runtime…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                    } else if store.officialRuntimeCatalogError == nil {
                        Label(
                            "No eligible official runtime releases were found.",
                            systemImage: "shippingbox"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.officialRuntimeReleases) { release in
                            OfficialRuntimeReleaseRow(release: release)
                        }
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Official Releases", systemImage: "square.stack.3d.up.fill")
        }
    }

    private var otherManagedRuntimesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("These runtimes are in Switchyard's managed cache but do not match the currently loaded official release list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(spacing: 10) {
                    ForEach(unmatchedInstallations) { installation in
                        ManagedRuntimeInstallationRow(installation: installation)
                    }
                }
            }
            .padding(4)
        } label: {
            Label("Other Managed Runtimes", systemImage: "archivebox.fill")
        }
    }

#if DEBUG
    private var localDevelopmentRuntimeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                PathPickerRow(
                    title: String(
                        localized: "Wine Path",
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

                Text("Local paths bypass the official release catalog but must still match this development build's pinned source revision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label("Local Development Runtime", systemImage: "hammer.fill")
        }
    }
#endif

    private var technicalDetailsSection: some View {
        DisclosureGroup {
            RuntimeBuildTechnicalDetailsView(runtime: store.currentRuntime)
                .padding(4)
        } label: {
            Label("Technical Details", systemImage: "info.circle")
        }
    }

    private var activeInstallation: ManagedRuntimeInstallation? {
        store.installedManagedRuntimes.first {
            store.isActiveRuntime($0)
        }
    }

    private var activeRelease: OfficialRuntimeRelease? {
        activeInstallation.flatMap {
            store.officialRelease(for: $0)
        }
    }

    private var activeRuntimeTitle: String {
        if let activeRelease {
            return activeRelease.release.tagName
        }
        if let buildNumber = store.currentRuntime.buildNumber {
            return String(
                localized: "Build \(buildNumber)",
                bundle: SwitchyardStrings.bundle
            )
        }
        return store.currentRuntime.id
    }

    private var activeRuntimeSubtitle: String {
        if activeRelease != nil,
           let buildNumber = store.currentRuntime.buildNumber {
            return String(
                localized: "Build \(buildNumber)",
                bundle: SwitchyardStrings.bundle
            )
        }
        return store.currentRuntime.id
    }

    private var activeVersionDateLabel: String {
        let date = activeRelease?.release.publishedAt
            ?? store.currentRuntime.versionDate
        return date.map {
            $0.formatted(date: .long, time: .shortened)
        } ?? String(
            localized: "Not available",
            bundle: SwitchyardStrings.bundle
        )
    }

    private var activeInstalledDateLabel: String {
        activeInstallation?.installedAt.formatted(
            date: .abbreviated,
            time: .shortened
        ) ?? String(
            localized: "Not available",
            bundle: SwitchyardStrings.bundle
        )
    }

    private var activeSourceRevisionLabel: String {
        store.currentRuntime.sourceRevision.isEmpty
            ? String(
                localized: "Not available",
                bundle: SwitchyardStrings.bundle
            )
            : String(store.currentRuntime.sourceRevision.prefix(12))
    }

    private var unmatchedInstallations: [ManagedRuntimeInstallation] {
        store.installedManagedRuntimes.filter {
            store.officialRelease(for: $0) == nil
        }
    }

    private var runtimeManagementMessageIsFailure: Bool {
        if case .failed = store.runtimeManagementState {
            return true
        }
        return false
    }

    private var wineRuntimeMessage: String {
        store.diagnostics.first { $0.id == "wine-runtime" }?.result
            ?? String(
                localized: "Install an official Switchyard runtime, then run diagnostics.",
                bundle: SwitchyardStrings.bundle
            )
    }

    private var runtimeCompatibilityStatus: HealthStatus {
        store.runtimeStatus.wine == .ok
            ? store.runtimeStatus.wineSource
            : store.runtimeStatus.wine
    }

    private var runtimeCompatibilityMessage: String {
        if store.runtimeStatus.wine == .ok && store.runtimeStatus.wineSource == .ok {
            return String(
                localized: "The active runtime is ready.",
                bundle: SwitchyardStrings.bundle
            )
        }
        if store.runtimeStatus.wine == .ok {
            return String(
                localized: "The runtime is runnable, but its source identity could not be verified.",
                bundle: SwitchyardStrings.bundle
            )
        }
        return wineRuntimeMessage
    }
}

private struct OfficialRuntimeReleaseRow: View {
    @EnvironmentObject private var store: AppStore
    let release: OfficialRuntimeRelease
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(release.release.tagName)
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                if store.isRecommendedRuntime(release) {
                    RuntimePill(
                        title: String(
                            localized: "Recommended",
                            bundle: SwitchyardStrings.bundle
                        ),
                        color: .accentColor
                    )
                }
                if installation != nil {
                    RuntimePill(
                        title: String(
                            localized: "Installed",
                            bundle: SwitchyardStrings.bundle
                        ),
                        color: .secondary
                    )
                }
                if isActive {
                    RuntimePill(
                        title: String(
                            localized: "Active",
                            bundle: SwitchyardStrings.bundle
                        ),
                        color: .green
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    releaseDateMetadata
                    archiveSizeMetadata
                    sourceRevisionMetadata
                }
                VStack(alignment: .leading, spacing: 5) {
                    releaseDateMetadata
                    archiveSizeMetadata
                    sourceRevisionMetadata
                }
            }

            Divider()

            HStack {
                Spacer()
                releaseActions
            }
        }
        .padding(12)
        .background(
            .quaternary.opacity(0.18),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        }
    }

    private var releaseDateMetadata: some View {
        RuntimeInlineMetadata(
            systemImage: "calendar",
            text: release.release.publishedAt.formatted(
                date: .long,
                time: .omitted
            )
        )
    }

    private var archiveSizeMetadata: some View {
        RuntimeInlineMetadata(
            systemImage: "externaldrive",
            text: archiveSizeLabel
        )
    }

    private var sourceRevisionMetadata: some View {
        RuntimeInlineMetadata(
            systemImage: "point.3.connected.trianglepath.dotted",
            text: String(
                localized: "Source \(release.manifest.sourceRevision.prefix(12))",
                bundle: SwitchyardStrings.bundle
            )
        )
    }

    @ViewBuilder
    private var releaseActions: some View {
        if isOperating {
            ProgressView()
                .controlSize(.small)
                .frame(width: 72)
        } else if let installation {
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    Button("Use") {
                        store.activateOfficialRuntime(release)
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(!store.canChangeCompatibilityConfiguration || managerIsBusy)

                    Button(role: .destructive) {
                        isConfirmingRemoval = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove this inactive runtime")
                    .accessibilityLabel("Remove \(release.release.tagName)")
                    .disabled(!store.canChangeCompatibilityConfiguration || managerIsBusy)
                    .confirmationDialog(
                        "Remove \(release.release.tagName)?",
                        isPresented: $isConfirmingRemoval
                    ) {
                        Button("Remove Runtime", role: .destructive) {
                            store.removeManagedRuntime(installation)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The runtime cache will be deleted. You can download this official release again later.")
                    }
                }
            }
        } else {
            Button {
                store.installOfficialRuntime(release)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(
                !store.canInstallOfficialRuntime(release) || managerIsBusy
            )
        }
    }

    private var installation: ManagedRuntimeInstallation? {
        store.installedRuntime(for: release)
    }

    private var isActive: Bool {
        installation.map(store.isActiveRuntime) == true
    }

    private var managerIsBusy: Bool {
        store.runtimeManagementState.isWorking
            || store.runtimeInstallationState.isWorking
    }

    private var isOperating: Bool {
        store.runtimeManagementState.operationID == release.id
            || store.runtimeManagementState.operationID == installation?.id
    }

    private var archiveSizeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(release.manifest.archiveSize),
            countStyle: .file
        )
    }
}

private struct ManagedRuntimeInstallationRow: View {
    @EnvironmentObject private var store: AppStore
    let installation: ManagedRuntimeInstallation
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(runtimeTitle)
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                if isActive {
                    RuntimePill(
                        title: String(
                            localized: "Active",
                            bundle: SwitchyardStrings.bundle
                        ),
                        color: .green
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    installedDateMetadata
                    installedSourceMetadata
                }
                VStack(alignment: .leading, spacing: 5) {
                    installedDateMetadata
                    installedSourceMetadata
                }
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()

                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else if store.runtimeManagementState.operationID == installation.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
#if DEBUG
                    Button("Use") {
                        store.useManagedDevelopmentRuntime(installation)
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(
                        !store.canChangeCompatibilityConfiguration
                            || store.runtimeInstallationState.isWorking
                            || store.runtimeManagementState.isWorking
                    )
#endif

                    Button(role: .destructive) {
                        isConfirmingRemoval = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove this inactive managed runtime")
                    .accessibilityLabel("Remove \(installation.runtime.id)")
                    .disabled(
                        !store.canChangeCompatibilityConfiguration
                            || store.runtimeInstallationState.isWorking
                            || store.runtimeManagementState.isWorking
                    )
                    .confirmationDialog(
                        "Remove this managed runtime?",
                        isPresented: $isConfirmingRemoval
                    ) {
                        Button("Remove Runtime", role: .destructive) {
                            store.removeManagedRuntime(installation)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Only the Switchyard-managed runtime cache will be deleted.")
                    }
                }
            }
        }
        .padding(12)
        .background(
            .quaternary.opacity(0.18),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        }
    }

    private var installedDateMetadata: some View {
        RuntimeInlineMetadata(
            systemImage: "calendar.badge.clock",
            text: installation.installedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
        )
    }

    private var installedSourceMetadata: some View {
        RuntimeInlineMetadata(
            systemImage: "point.3.connected.trianglepath.dotted",
            text: String(
                localized: "Source \(installation.runtime.sourceRevision.prefix(12))",
                bundle: SwitchyardStrings.bundle
            )
        )
    }

    private var isActive: Bool {
        store.isActiveRuntime(installation)
    }

    private var runtimeTitle: String {
        installation.runtime.buildNumber.map {
            String(
                localized: "Build \($0)",
                bundle: SwitchyardStrings.bundle
            )
        } ?? installation.runtime.id
    }
}

private struct RuntimeMetadataValue: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RuntimeInlineMetadata: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

private struct RuntimePill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct RuntimeSettingsNotice: View {
    let message: String
    let systemImage: String
    let color: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
            }
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
