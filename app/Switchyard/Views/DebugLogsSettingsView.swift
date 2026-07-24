import AppCore
import SwiftUI

struct DebugLogsSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("developerLogging") private var developerLogging = false
    @AppStorage("verboseWineLogging") private var verboseWineLogging = false
    @AppStorage("debugRunLogRetentionDays")
    private var retentionDays = DebugRunLogRetentionPolicy.defaultRetentionDays
    @AppStorage("debugRunLogMaximumFileCount")
    private var maximumFileCount = DebugRunLogRetentionPolicy.defaultMaximumFileCount
    @State private var isConfirmingDelete = false

    var body: some View {
        SettingsPage(title: "Logs", systemImage: "doc.text.fill") {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Developer logging", isOn: $developerLogging)
                        .help("When enabled, launches record Wine errors and warnings in a protected per-run file under ~/Library/Application Support/Switchyard/Logs/DebugRuns.")

                    Divider()

                    Toggle("Verbose Wine logging", isOn: $verboseWineLogging)
                        .disabled(!developerLogging)
                        .help("Verbose mode additionally records Wine fixme output and targeted SEH, graphics, and window-system traces. It can produce very large logs, so the live view is batched and keeps only its latest 5,000 entries while the protected file keeps the complete run output.")
                }
                .padding(4)
            } label: {
                Label(
                    "Developer logging",
                    systemImage: "doc.text.magnifyingglass"
                )
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Retention (days)") {
                        Picker(
                            "Retention (days)",
                            selection: $retentionDays
                        ) {
                            ForEach(
                                DebugRunLogRetentionPolicy
                                    .supportedRetentionDays,
                                id: \.self
                            ) { days in
                                Text(verbatim: String(days)).tag(days)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    LabeledContent("Maximum stored files") {
                        Picker(
                            "Maximum stored files",
                            selection: $maximumFileCount
                        ) {
                            ForEach(
                                DebugRunLogRetentionPolicy
                                    .supportedMaximumFileCounts,
                                id: \.self
                            ) { count in
                                Text(verbatim: String(count)).tag(count)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                }
                .padding(4)
            } label: {
                Label("Retention (days)", systemImage: "calendar.badge.clock")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Logs") {
                        Text(verbatim: storageSummary)
                            .foregroundStyle(.secondary)
                    }

                    Text(verbatim: store.debugRunLogDirectoryPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            .quaternary.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 8)
                        )

                    HStack(spacing: 8) {
                        Button("Open in Finder") {
                            store.openDebugRunLogFolder()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Delete Stored Logs", role: .destructive) {
                            isConfirmingDelete = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            store.debugRunLogStorage.fileCount == 0
                                || store.hasRunningContainers
                        )
                    }

                    if store.hasRunningContainers {
                        SettingsNotice(
                            message: String(
                                localized: "Stop running containers before deleting stored debug logs.",
                                bundle: SwitchyardStrings.bundle
                            ),
                            systemImage: "exclamationmark.triangle.fill",
                            color: .orange
                        )
                    }
                }
                .padding(4)
            } label: {
                Label("Storage", systemImage: "internaldrive")
            }
        }
        .onAppear {
            normalizeAndApplyRetentionPolicy()
            store.refreshDebugRunLogStorage()
        }
        .onChange(of: retentionDays) {
            normalizeAndApplyRetentionPolicy()
        }
        .onChange(of: maximumFileCount) {
            normalizeAndApplyRetentionPolicy()
        }
        .confirmationDialog(
            "Delete all stored debug logs?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Stored Logs", role: .destructive) {
                store.deleteStoredDebugRunLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every per-run debug log file. Logs currently shown in Switchyard are not affected.")
        }
    }

    private var storageSummary: String {
        let size = ByteCountFormatter.string(
            fromByteCount: store.debugRunLogStorage.totalBytes,
            countStyle: .file
        )
        return "\(store.debugRunLogStorage.fileCount) · \(size)"
    }

    private func normalizeAndApplyRetentionPolicy() {
        let policy = DebugRunLogRetentionPolicy(
            retentionDays: retentionDays,
            maximumFileCount: maximumFileCount
        )
        if retentionDays != policy.retentionDays {
            retentionDays = policy.retentionDays
        }
        if maximumFileCount != policy.maximumFileCount {
            maximumFileCount = policy.maximumFileCount
        }
        store.applyDebugRunLogRetentionPolicy(policy)
    }
}
