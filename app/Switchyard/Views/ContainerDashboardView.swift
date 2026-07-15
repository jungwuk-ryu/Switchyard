import AppCore
import AppKit
import SwiftUI

private enum ContainerDashboardSection: String, CaseIterable, Identifiable {
    case dashboard
    case applications
    case files
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .applications: "Applications"
        case .files: "Files"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }
}

struct ContainerDashboardView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var selectedSection: ContainerDashboardSection = .dashboard
    @State private var selectedProgramID: String?

    var body: some View {
        VStack(spacing: 0) {
            dashboardHeader
            sectionTabs
            Divider()
            sectionContent
        }
        .task(id: container.id) {
            store.refreshInstalledPrograms(for: container.id)
            selectInitialProgram()
            await store.monitorContainerSession(for: container.id)
        }
        .onChange(of: programs) { _, _ in
            selectInitialProgram()
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) {
                Label("Containers", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to Containers")

            HStack(alignment: .center, spacing: 14) {
                Text(container.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)

                Label(containerSummary, systemImage: containerSummarySymbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(containerSummaryColor)

                Spacer(minLength: 24)

                StatusBadge(status: store.runtimeStatus.wine, label: "Wine")
                StatusBadge(status: store.runtimeStatus.gptk, label: "GPTK")
                StatusBadge(status: store.runtimeStatus.patchset, label: "Runtime Source")

                Button("Re-run Diagnostics") {
                    store.refreshRuntimeStatus()
                }

                Menu {
                    Button("Run EXE…") {
                        store.chooseExecutableAndRun(in: container.id)
                    }
                    Button("Show Container in Finder") {
                        store.openContainerInFinder(container.id)
                    }
                    Divider()
                    Button("Container Settings") {
                        selectedSection = .settings
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More Container Actions")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var sectionTabs: some View {
        HStack(spacing: 28) {
            ForEach(ContainerDashboardSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Text(section.title)
                        .font(.callout.weight(selectedSection == section ? .semibold : .regular))
                        .foregroundStyle(selectedSection == section ? .primary : .secondary)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(selectedSection == section ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .dashboard:
            dashboardOverview
        case .applications:
            ContainerApplicationsView(
                container: container,
                selectedProgramID: $selectedProgramID
            )
        case .files:
            ContainerFileBrowserView(
                container: container,
                initialDirectoryURL: nil,
                compact: false
            )
            .padding(18)
        case .activity:
            ContainerActivityView(container: container)
        case .settings:
            ContainerSettingsView(container: container, onDelete: onDelete)
        }
    }

    private var dashboardOverview: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if proxy.size.width >= 1_400 {
                        HStack(alignment: .top, spacing: 16) {
                            ProgramHeroView(container: container, program: selectedProgram)
                                .frame(maxWidth: .infinity)
                            InstalledProgramShelf(
                                container: container,
                                programs: programs,
                                maximumVisiblePrograms: maximumShelfProgramCount(
                                    for: proxy.size.width
                                ),
                                selectedProgramID: $selectedProgramID,
                                onViewAll: { selectedSection = .applications }
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .frame(minHeight: 185)
                    } else {
                        VStack(spacing: 16) {
                            ProgramHeroView(container: container, program: selectedProgram)
                            InstalledProgramShelf(
                                container: container,
                                programs: programs,
                                maximumVisiblePrograms: 6,
                                selectedProgramID: $selectedProgramID,
                                onViewAll: { selectedSection = .applications }
                            )
                        }
                    }

                    if proxy.size.width >= 1_400 {
                        HStack(alignment: .top, spacing: 16) {
                            ContainerFileBrowserView(
                                container: container,
                                initialDirectoryURL: selectedProgram.map {
                                    URL(fileURLWithPath: $0.executablePath).deletingLastPathComponent()
                                },
                                compact: true
                            )
                            .id(selectedProgram?.id ?? container.id.uuidString)
                            .frame(maxWidth: .infinity, minHeight: 290, alignment: .top)

                            ContainerSessionPanel(
                                container: container,
                                compact: true,
                                onShowAll: { selectedSection = .activity }
                            )
                            .frame(maxWidth: .infinity, minHeight: 290, alignment: .top)
                        }
                    } else {
                        VStack(spacing: 16) {
                            ContainerFileBrowserView(
                                container: container,
                                initialDirectoryURL: selectedProgram.map {
                                    URL(fileURLWithPath: $0.executablePath).deletingLastPathComponent()
                                },
                                compact: true
                            )
                            .id(selectedProgram?.id ?? container.id.uuidString)

                            ContainerSessionPanel(
                                container: container,
                                compact: true,
                                onShowAll: { selectedSection = .activity }
                            )
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var programs: [InstalledProgram] {
        let sortedPrograms = store.installedPrograms(for: container.id).sorted { lhs, rhs in
            let lhsDefault = lhs.executablePath == container.executablePath
            let rhsDefault = rhs.executablePath == container.executablePath
            if lhsDefault != rhsDefault {
                return lhsDefault
            }
            if lhs.isSystemUtility != rhs.isSystemUtility {
                return !lhs.isSystemUtility
            }
            return lhs.presentationName.localizedStandardCompare(rhs.presentationName)
                == .orderedAscending
        }
        var seenNames: Set<String> = []
        return sortedPrograms.filter { program in
            seenNames.insert(program.presentationName.lowercased()).inserted
        }
    }

    private var selectedProgram: InstalledProgram? {
        if let selectedProgramID,
            let selected = programs.first(where: { $0.id == selectedProgramID })
        {
            return selected
        }
        return programs.first(where: { $0.executablePath == container.executablePath })
            ?? programs.first
    }

    private func maximumShelfProgramCount(for width: CGFloat) -> Int {
        if width >= 1_520 { return 6 }
        if width >= 1_400 { return 5 }
        return 4
    }

    private var containerSummary: String {
        switch store.sessionSnapshot(for: container.id).wineServerState {
        case .active:
            "Windows session running"
        case .checking:
            "Checking Windows session"
        case .inactive, .unavailable:
            container.executablePath?.isEmpty == false ? "Ready to launch" : "Choose an application"
        }
    }

    private var containerSummarySymbol: String {
        switch store.sessionSnapshot(for: container.id).wineServerState {
        case .active: "play.circle.fill"
        case .checking: "clock"
        case .inactive:
            container.executablePath?.isEmpty == false ? "checkmark.circle.fill" : "plus.circle"
        case .unavailable: "questionmark.circle"
        }
    }

    private var containerSummaryColor: Color {
        switch store.sessionSnapshot(for: container.id).wineServerState {
        case .active, .inactive:
            container.executablePath?.isEmpty == false ? .green : .secondary
        case .checking, .unavailable:
            .secondary
        }
    }

    private func selectInitialProgram() {
        guard selectedProgramID == nil || !programs.contains(where: { $0.id == selectedProgramID })
        else {
            return
        }
        selectedProgramID =
            programs.first(where: { $0.executablePath == container.executablePath })?.id
            ?? programs.first?.id
    }
}

private struct ProgramHeroView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let program: InstalledProgram?

    var body: some View {
        HStack(spacing: 20) {
            if let program {
                WindowsProgramIconView(program: program, size: 106)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                    .frame(width: 106, height: 106)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(program?.presentationName ?? "Choose an application")
                        .font(.title.weight(.semibold))
                        .lineLimit(1)

                    if program?.executablePath == container.executablePath {
                        Text("Default")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    }
                }

                if let program {
                    Text("Location")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(ContainerPathPresentation.windowsPath(for: program.executablePath, in: container))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("Installed Windows applications will appear here after setup.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let lastRun = container.lastRun {
                    Text("Last launched \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 18)

            VStack(spacing: 8) {
                Button {
                    if let program {
                        store.runInstalledProgram(program, in: container.id)
                    } else {
                        store.chooseExecutableAndRun(in: container.id)
                    }
                } label: {
                    Label(
                        program.map { "Launch \($0.presentationName)" } ?? "Run EXE…", systemImage: "play.fill"
                    )
                    .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isContainerBusy(container.id))

                Text(
                    program.map { "Start \($0.presentationName) in this container" }
                        ?? "Choose any Windows executable"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(18)
        .dashboardPanel(emphasized: true)
    }
}

private struct InstalledProgramShelf: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let programs: [InstalledProgram]
    let maximumVisiblePrograms: Int
    @Binding var selectedProgramID: String?
    let onViewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed Programs")
                    .font(.headline)
                Spacer()
                Button("View all", systemImage: "chevron.right", action: onViewAll)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.link)
            }

            if programs.isEmpty {
                ContentUnavailableView(
                    "No Programs Found",
                    systemImage: "app.dashed",
                    description: Text("Install or choose a Windows application to see it here.")
                )
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(programs.prefix(maximumVisiblePrograms)) { program in
                        Button {
                            selectedProgramID = program.id
                        } label: {
                            VStack(spacing: 8) {
                                WindowsProgramIconView(program: program, size: 62)
                                Text(program.presentationName)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 92)
                            }
                            .padding(9)
                            .background(
                                selectedProgramID == program.id ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                if selectedProgramID == program.id {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Launch") {
                                selectedProgramID = program.id
                                store.runInstalledProgram(program, in: container.id)
                            }
                            .disabled(store.isContainerBusy(container.id))
                        }
                    }
                }
            }
        }
        .padding(16)
        .dashboardPanel()
    }
}

struct DashboardPanelModifier: ViewModifier {
    var emphasized = false

    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(
                        emphasized
                            ? Color.accentColor.opacity(0.85) : Color(nsColor: .separatorColor).opacity(0.65),
                        lineWidth: 1
                    )
            }
    }
}

extension View {
    func dashboardPanel(emphasized: Bool = false) -> some View {
        modifier(DashboardPanelModifier(emphasized: emphasized))
    }
}
