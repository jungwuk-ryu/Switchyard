import AppCore
import SwiftUI

struct ContainerSessionPanel: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let compact: Bool
    var maximumVisibleProcesses = 4
    var minimumHeight: CGFloat? = nil
    var onShowAll: (() -> Void)? = nil
    @State private var isConfirmingStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Windows Session")
                        .font(.headline)

                    Spacer()

                    Button {
                        Task {
                            await store.refreshContainerSession(for: container.id)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isStoppingWineServer)
                    .help("Refresh Windows Session")

                    if snapshot.wineServerState.hasRunningProcesses || isStoppingWineServer {
                        Button(role: .destructive) {
                            isConfirmingStop = true
                        } label: {
                            if isStoppingWineServer {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Stopping…")
                                }
                            } else {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            isStoppingWineServer || store.isContainerLaunching(container.id)
                        )
                    }
                }

                Label(sessionLabel, systemImage: sessionSymbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(sessionColor)
            }
            .padding(14)

            Divider()

            HStack {
                Text("Processes")
                    .font(.headline)
                Text("\(snapshot.processes.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            Divider()

            if snapshot.wineServerState == .checking {
                ProgressView("Checking running applications…")
                    .frame(maxWidth: .infinity, minHeight: sessionContentMinimumHeight)
            } else if snapshot.processes.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: emptyProcessesSymbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(
                        snapshot.wineServerState.hasRunningProcesses
                            ? String(
                                localized: "No application details available",
                                bundle: SwitchyardStrings.bundle
                            )
                            : String(
                                localized: "No Windows applications are running",
                                bundle: SwitchyardStrings.bundle
                            )
                    )
                    .font(.callout.weight(.medium))
                    Text(
                        snapshot.message
                            ?? String(
                                localized: "Launch an application to start this container's Windows session.",
                                bundle: SwitchyardStrings.bundle
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: sessionContentMinimumHeight)
                .padding(.horizontal, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(displayedProcesses) { process in
                        WindowsProcessRow(process: process, showsPath: !compact)

                        if process.id != displayedProcesses.last?.id {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }

            if compact && (snapshot.processes.count > displayedProcesses.count || onShowAll != nil) {
                Divider()
                Button {
                    onShowAll?()
                } label: {
                    HStack {
                        Text(
                            snapshot.processes.isEmpty
                                ? String(
                                    localized: "View activity",
                                    bundle: SwitchyardStrings.bundle
                                )
                                : String(
                                    localized: "View all processes",
                                    bundle: SwitchyardStrings.bundle
                                )
                        )
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .dashboardPanel()
        .confirmationDialog(
            "Stop all Windows apps?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop All Windows Apps", role: .destructive) {
                Task {
                    await store.stopWineServer(in: container.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All Windows apps in \(container.name) will close. Unsaved work may be lost.")
        }
    }

    private var snapshot: ContainerSessionSnapshot {
        store.sessionSnapshot(for: container.id)
    }

    private var displayedProcesses: [WindowsProcessSnapshot] {
        compact
            ? Array(snapshot.processes.prefix(max(1, maximumVisibleProcesses)))
            : snapshot.processes
    }

    private var sessionContentMinimumHeight: CGFloat {
        let baseHeight: CGFloat = compact ? 142 : 220
        let chromeHeight: CGFloat = compact ? 185 : 145
        return max(baseHeight, (minimumHeight ?? 0) - chromeHeight)
    }

    private var emptyProcessesSymbol: String {
        switch snapshot.wineServerState {
        case .orphaned: "exclamationmark.triangle"
        case .active: "hourglass"
        case .checking: "clock"
        case .inactive, .unavailable: "moon.zzz"
        }
    }

    private var isStoppingWineServer: Bool {
        store.isStoppingWineServer(in: container.id)
    }

    private var sessionLabel: String {
        if isStoppingWineServer {
            return String(localized: "Stopping", bundle: SwitchyardStrings.bundle)
        }
        return switch snapshot.wineServerState {
        case .checking:
            String(localized: "Checking", bundle: SwitchyardStrings.bundle)
        case .active:
            String(localized: "Running", bundle: SwitchyardStrings.bundle)
        case .orphaned:
            String(localized: "Cleanup needed", bundle: SwitchyardStrings.bundle)
        case .inactive:
            String(localized: "Idle", bundle: SwitchyardStrings.bundle)
        case .unavailable:
            String(localized: "Unavailable", bundle: SwitchyardStrings.bundle)
        }
    }

    private var sessionSymbol: String {
        if isStoppingWineServer { return "stop.circle.fill" }
        return switch snapshot.wineServerState {
        case .checking: "clock"
        case .active: "checkmark.circle.fill"
        case .orphaned: "exclamationmark.triangle.fill"
        case .inactive: "pause.circle.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    private var sessionColor: Color {
        if isStoppingWineServer { return .orange }
        return switch snapshot.wineServerState {
        case .active: .green
        case .orphaned: .orange
        case .checking, .inactive: .secondary
        case .unavailable: .orange
        }
    }

}

struct ContainerActivityView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container

    var body: some View {
        GeometryReader { proxy in
            let usesWideLayout = proxy.size.width >= 1_100
            let panelHeight = max(320, proxy.size.height - 36)
            let activityRowCount = max(10, Int((panelHeight - 70) / 64))

            ScrollView {
                Group {
                    if usesWideLayout {
                        HStack(alignment: .top, spacing: 16) {
                            ContainerSessionPanel(
                                container: container,
                                compact: false,
                                minimumHeight: panelHeight
                            )
                                .frame(maxWidth: .infinity)
                            RecentContainerActivity(
                                container: container,
                                maximumVisibleLogs: activityRowCount,
                                minimumHeight: panelHeight
                            )
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 16) {
                            ContainerSessionPanel(container: container, compact: false)
                            RecentContainerActivity(container: container)
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

private struct WindowsProcessRow: View {
    let process: WindowsProcessSnapshot
    let showsPath: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: process.isSystemProcess ? "gearshape.fill" : "app.fill")
                .foregroundStyle(
                    process.isSystemProcess ? AnyShapeStyle(.secondary) : AnyShapeStyle(.blue)
                )
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if showsPath {
                    Text(process.executablePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(process.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct RecentContainerActivity: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    var maximumVisibleLogs = 10
    var minimumHeight: CGFloat? = nil
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                Button("Open All Logs") {
                    store.selectedSection = .logs
                }
                .buttonStyle(.link)

                Button("Clear") {
                    isConfirmingClear = true
                }
                .buttonStyle(.link)
                .disabled(logs.isEmpty)
            }
            .padding(16)

            Divider()

            if logs.isEmpty {
                ContentUnavailableView("No Recent Activity", systemImage: "clock")
                .frame(maxWidth: .infinity, minHeight: activityContentMinimumHeight)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(logs) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Image(
                                systemName: line.level == "error"
                                    ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                            )
                            .foregroundStyle(line.level == "error" ? .red : .green)
                            .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.message)
                                    .font(.callout)
                                    .lineLimit(2)
                                Text(line.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                        if line.id != logs.last?.id {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .dashboardPanel()
        .confirmationDialog(
            "Clear this container's activity?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Activity", role: .destructive) {
                store.clearLogs(for: container.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The log entries shown for \(container.name) will be removed from Switchyard.")
        }
    }

    private var logs: [LogLine] {
        store.recentLogs(
            for: container.id,
            limit: max(1, maximumVisibleLogs)
        )
    }

    private var activityContentMinimumHeight: CGFloat {
        max(250, (minimumHeight ?? 0) - 53)
    }
}
