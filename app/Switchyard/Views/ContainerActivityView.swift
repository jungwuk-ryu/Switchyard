import AppCore
import SwiftUI

struct ContainerSessionPanel: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let compact: Bool
    var onShowAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Windows Session")
                        .font(.headline)

                    Spacer()

                    if let refreshedAt = snapshot.refreshedAt {
                        Text("Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        Task {
                            await store.refreshContainerSession(for: container.id)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh Windows Session")
                }

                HStack(spacing: 7) {
                    Text("wineserver")
                        .fontWeight(.semibold)

                    Label(sessionLabel, systemImage: sessionSymbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(sessionColor)
                }

                Text(sessionDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                    .frame(maxWidth: .infinity, minHeight: compact ? 142 : 220)
            } else if snapshot.processes.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: snapshot.wineServerState == .active ? "hourglass" : "moon.zzz")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(
                        snapshot.wineServerState == .active
                            ? "No application details available" : "No Windows applications are running"
                    )
                    .font(.callout.weight(.medium))
                    Text(
                        snapshot.message ?? "Launch an application to start this container's Windows session."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: compact ? 142 : 220)
                .padding(.horizontal, 20)
            } else {
                LazyVStack(spacing: 0) {
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
                        Text(snapshot.processes.isEmpty ? "View activity" : "View all processes")
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
        .dashboardPanel()
    }

    private var snapshot: ContainerSessionSnapshot {
        store.sessionSnapshot(for: container.id)
    }

    private var displayedProcesses: [WindowsProcessSnapshot] {
        compact ? Array(snapshot.processes.prefix(4)) : snapshot.processes
    }

    private var sessionLabel: String {
        return switch snapshot.wineServerState {
        case .checking: "Checking"
        case .active: "Running"
        case .inactive: "Idle"
        case .unavailable: "Unavailable"
        }
    }

    private var sessionSymbol: String {
        return switch snapshot.wineServerState {
        case .checking: "clock"
        case .active: "checkmark.circle.fill"
        case .inactive: "pause.circle.fill"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    private var sessionColor: Color {
        switch snapshot.wineServerState {
        case .active: .green
        case .checking, .inactive: .secondary
        case .unavailable: .orange
        }
    }

    private var sessionDescription: String {
        if let message = snapshot.message {
            return message
        }
        return switch snapshot.wineServerState {
        case .checking: "Inspecting the Wine prefix"
        case .active: "Responding normally"
        case .inactive: "Ready for the next application"
        case .unavailable: "Session status could not be read"
        }
    }
}

struct ContainerActivityView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                Group {
                    if proxy.size.width >= 1_100 {
                        HStack(alignment: .top, spacing: 16) {
                            ContainerSessionPanel(container: container, compact: false)
                                .frame(maxWidth: .infinity)
                            RecentContainerActivity(container: container)
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
            Image(systemName: process.kind == "System" ? "gearshape.fill" : "app.fill")
                .foregroundStyle(
                    process.kind == "System" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.blue)
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

            Spacer()

            Label("Running", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

private struct RecentContainerActivity: View {
    @EnvironmentObject private var store: AppStore
    let container: Container

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
            }
            .padding(16)

            Divider()

            if logs.isEmpty {
                ContentUnavailableView(
                    "No Recent Activity",
                    systemImage: "clock",
                    description: Text("Launches and container events will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 250)
            } else {
                LazyVStack(spacing: 0) {
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
        .dashboardPanel()
    }

    private var logs: [LogLine] {
        Array(
            store.logLines.filter {
                $0.containerID == container.id
            }.prefix(10))
    }
}
