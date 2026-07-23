import AppCore
import RuntimeCatalog
import SwiftUI

struct RuntimeSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Active Runtime") {
                RuntimeBuildSummaryView(runtime: store.currentRuntime)
                LabeledContent("Compatibility") {
                    StatusBadge(
                        status: runtimeCompatibilityStatus,
                        label: runtimeCompatibilityStatus == .ok
                            ? "Compatible"
                            : "Needs Attention"
                    )
                }
                Text(runtimeCompatibilityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The active runtime is used by every container.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Official Releases") {
                HStack {
                    Text("Download and switch between signed Switchyard Wine releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.isRefreshingOfficialRuntimeReleases {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        store.refreshOfficialRuntimeReleases(force: true)
                    } label: {
                        Label("Check for Releases", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshingOfficialRuntimeReleases)
                }

                if !store.canInstallOfficialRuntimeReleases {
                    Label(
                        "This development build has no official Developer ID trust configuration. Release browsing remains available, but downloads are disabled.",
                        systemImage: "hammer"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let error = store.officialRuntimeCatalogError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if store.officialRuntimeReleases.isEmpty,
                          !store.isRefreshingOfficialRuntimeReleases {
                    Text("No eligible official runtime releases were found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(
                            Array(store.officialRuntimeReleases.enumerated()),
                            id: \.element.id
                        ) { index, release in
                            OfficialRuntimeReleaseRow(release: release)
                            if index < store.officialRuntimeReleases.count - 1 {
                                Divider()
                            }
                        }
                    }
                }

                if let message = store.runtimeManagementState.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(
                            runtimeManagementMessageIsFailure ? .red : .secondary
                        )
                }
            }

            if !unmatchedInstallations.isEmpty {
                Section("Other Managed Runtimes") {
                    Text("These runtimes are in Switchyard's managed cache but do not match the currently loaded official release list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(unmatchedInstallations) { installation in
                        ManagedRuntimeInstallationRow(installation: installation)
                    }
                }
            }

#if DEBUG
            Section("Local Development Runtime") {
                PathPickerRow(
                    title: "Wine Path",
                    message: "Choose a locally built Wine executable or runtime folder.",
                    path: $store.winePath
                ) {
                    store.useSelectedLocalDevelopmentRuntime()
                }
                .disabled(
                    !store.canChangeActiveRuntime
                        || store.runtimeInstallationState.isWorking
                        || store.runtimeManagementState.isWorking
                )
                Text("Local paths bypass the official release catalog but must still match this development build's pinned source revision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            Section {
                Button("Re-run Runtime Diagnostics") {
                    store.refreshRuntimeStatus()
                }
                DisclosureGroup("Technical Details") {
                    RuntimeBuildTechnicalDetailsView(runtime: store.currentRuntime)
                        .padding(.top, 6)
                }
            }
        }
        .padding()
        .task {
            store.refreshOfficialRuntimeReleases()
        }
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
            ?? "Install an official Switchyard runtime, then run diagnostics."
    }

    private var runtimeCompatibilityStatus: HealthStatus {
        store.runtimeStatus.wine == .ok
            ? store.runtimeStatus.patchset
            : store.runtimeStatus.wine
    }

    private var runtimeCompatibilityMessage: String {
        if store.runtimeStatus.wine == .ok && store.runtimeStatus.patchset == .ok {
            return "The active runtime is ready."
        }
        if store.runtimeStatus.wine == .ok {
            return "The runtime is runnable, but its source identity could not be verified."
        }
        return wineRuntimeMessage
    }
}

private struct OfficialRuntimeReleaseRow: View {
    @EnvironmentObject private var store: AppStore
    let release: OfficialRuntimeRelease
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(release.release.tagName)
                        .font(.body.weight(.medium))
                    if store.isRecommendedRuntime(release) {
                        runtimeBadge("Recommended", color: .accentColor)
                    }
                    if installation != nil {
                        runtimeBadge("Installed", color: .secondary)
                    }
                    if isActive {
                        runtimeBadge("Active", color: .green)
                    }
                }
                Text(releaseDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isOperating {
                ProgressView()
                    .controlSize(.small)
            } else if let installation {
                if !isActive {
                    Button("Use") {
                        store.activateOfficialRuntime(release)
                    }
                    .disabled(!store.canChangeActiveRuntime || managerIsBusy)
                    Button(role: .destructive) {
                        isConfirmingRemoval = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove this inactive runtime")
                    .accessibilityLabel("Remove \(release.release.tagName)")
                    .disabled(!store.canChangeActiveRuntime || managerIsBusy)
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
                } else {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                Button {
                    store.installOfficialRuntime(release)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(
                    !store.canInstallOfficialRuntime(release) || managerIsBusy
                )
            }
        }
        .padding(.vertical, 8)
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

    private var releaseDetail: String {
        let published = release.release.publishedAt.formatted(
            date: .abbreviated,
            time: .omitted
        )
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(release.manifest.archiveSize),
            countStyle: .file
        )
        return "\(published) · \(size) · source \(release.manifest.sourceRevision.prefix(12))"
    }

    private func runtimeBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ManagedRuntimeInstallationRow: View {
    @EnvironmentObject private var store: AppStore
    let installation: ManagedRuntimeInstallation
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(installation.runtime.buildNumber.map { "Build \($0)" }
                    ?? installation.runtime.id)
                    .font(.body.weight(.medium))
                Text("Source \(installation.runtime.sourceRevision.prefix(12))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isActiveRuntime(installation) {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if store.runtimeManagementState.operationID == installation.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove this inactive managed runtime")
                .accessibilityLabel("Remove \(installation.runtime.id)")
                .disabled(
                    !store.canChangeActiveRuntime
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
        .padding(.vertical, 6)
    }
}
