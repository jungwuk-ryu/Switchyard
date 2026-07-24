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
        case .dashboard:
            String(localized: "Dashboard", bundle: SwitchyardStrings.bundle)
        case .applications:
            String(localized: "Applications", bundle: SwitchyardStrings.bundle)
        case .files:
            String(localized: "Files", bundle: SwitchyardStrings.bundle)
        case .activity:
            String(localized: "Activity", bundle: SwitchyardStrings.bundle)
        case .settings:
            String(localized: "Settings", bundle: SwitchyardStrings.bundle)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: container.id) {
            store.refreshInstalledPrograms(for: container.id)
            selectInitialProgram()
            await store.monitorContainerSession(for: container.id)
        }
        .onChange(of: programs) { _, _ in
            selectInitialProgram()
        }
        .windowsApplicationDropTarget(
            containerName: container.name,
            isEnabled: !store.isContainerTransitioning(container.id)
        ) { url in
            store.runWindowsApplication(at: url, in: container.id)
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label("Containers", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to Containers")

                Spacer()

                Button {
                    store.chooseExecutableAndRun(in: container.id)
                } label: {
                    Label("Install or Run App…", systemImage: "plus.app.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isContainerTransitioning(container.id))
                .help("Choose an .exe or .msi file, or drop one onto this container")
                .accessibilityIdentifier("container.installOrRun")

                Menu {
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

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(container.name)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(1)

                    Label(containerSummary, systemImage: containerSummarySymbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(containerSummaryColor)
                }

                Spacer(minLength: 24)
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
            let usesWideLayout = proxy.size.width >= 1_400
            let detailPanelHeight = dashboardDetailPanelHeight(for: proxy.size.height)
            let detailRowCount = maximumDashboardDetailRows(for: detailPanelHeight)

            ScrollView {
                VStack(spacing: 16) {
                    if usesWideLayout {
                        HStack(alignment: .top, spacing: 16) {
                            ProgramHeroView(container: container, program: selectedProgram)
                                .frame(maxWidth: .infinity)
                            InstalledProgramShelf(
                                container: container,
                                programs: programs,
                                recentPrograms: recentPrograms,
                                maximumVisiblePrograms: maximumShelfProgramCount(
                                    for: proxy.size.width
                                ),
                                selectedProgramID: $selectedProgramID,
                                onViewAll: { selectedSection = .applications }
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .frame(minHeight: 185)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 16) {
                            ProgramHeroView(container: container, program: selectedProgram)
                            InstalledProgramShelf(
                                container: container,
                                programs: programs,
                                recentPrograms: recentPrograms,
                                maximumVisiblePrograms: 6,
                                selectedProgramID: $selectedProgramID,
                                onViewAll: { selectedSection = .applications }
                            )
                        }
                    }

                    if usesWideLayout {
                        HStack(alignment: .top, spacing: 16) {
                            ContainerFileBrowserView(
                                container: container,
                                initialDirectoryURL: selectedProgram.map {
                                    URL(fileURLWithPath: $0.executablePath).deletingLastPathComponent()
                                },
                                compact: true,
                                maximumVisibleEntries: detailRowCount,
                                minimumHeight: detailPanelHeight
                            )
                            .id(selectedProgram?.id ?? container.id.uuidString)
                            .frame(maxWidth: .infinity, alignment: .top)

                            ContainerSessionPanel(
                                container: container,
                                compact: true,
                                maximumVisibleProcesses: detailRowCount,
                                minimumHeight: detailPanelHeight,
                                onShowAll: { selectedSection = .activity }
                            )
                            .frame(maxWidth: .infinity, alignment: .top)
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
            let selected = selectablePrograms.first(where: { $0.id == selectedProgramID })
        {
            return selected
        }
        return programs.first(where: { $0.executablePath == container.executablePath })
            ?? programs.first
    }

    private var recentPrograms: [RecentInstalledProgram] {
        store.recentInstalledPrograms(for: container.id)
    }

    private var selectablePrograms: [InstalledProgram] {
        var seenPaths: Set<String> = []
        return (recentPrograms.map(\.program) + programs).filter { program in
            seenPaths.insert(program.executablePath).inserted
        }
    }

    private func maximumShelfProgramCount(for width: CGFloat) -> Int {
        if width >= 1_520 { return 6 }
        if width >= 1_400 { return 5 }
        return 4
    }

    private func dashboardDetailPanelHeight(for availableHeight: CGFloat) -> CGFloat {
        max(290, availableHeight - 237)
    }

    private func maximumDashboardDetailRows(for panelHeight: CGFloat) -> Int {
        max(4, Int((panelHeight - 150) / 42))
    }

    private var containerSummary: String {
        switch store.sessionSnapshot(for: container.id).wineServerState {
        case .active:
            String(localized: "Running", bundle: SwitchyardStrings.bundle)
        case .orphaned:
            String(localized: "Cleanup needed", bundle: SwitchyardStrings.bundle)
        case .checking:
            String(localized: "Checking", bundle: SwitchyardStrings.bundle)
        case .inactive, .unavailable:
            container.executablePath?.isEmpty == false
                ? String(localized: "Ready", bundle: SwitchyardStrings.bundle)
                : String(localized: "Choose an application", bundle: SwitchyardStrings.bundle)
        }
    }

    private var containerSummarySymbol: String {
        switch store.sessionSnapshot(for: container.id).wineServerState {
        case .active: "play.circle.fill"
        case .orphaned: "exclamationmark.triangle.fill"
        case .checking: "clock"
        case .inactive:
            container.executablePath?.isEmpty == false ? "checkmark.circle.fill" : "plus.circle"
        case .unavailable: "questionmark.circle"
        }
    }

    private var containerSummaryColor: Color {
        switch store.sessionSnapshot(for: container.id).wineServerState {
        case .orphaned:
            .orange
        case .active, .checking, .inactive, .unavailable:
            .secondary
        }
    }

    private func selectInitialProgram() {
        guard selectedProgramID == nil
                || !selectablePrograms.contains(where: { $0.id == selectedProgramID })
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
                    Text(
                        program?.presentationName
                            ?? (
                                isSteamStarterContainer
                                    ? String(
                                        localized: "Finish setting up Steam",
                                        bundle: SwitchyardStrings.bundle
                                    )
                                    : String(
                                        localized: "Choose an application",
                                        bundle: SwitchyardStrings.bundle
                                    )
                            )
                    )
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
                    Text(ContainerPathPresentation.windowsPath(for: program.executablePath, in: container))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
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
                    } else if isSteamStarterContainer {
                        store.continueSteamSetup()
                    } else {
                        store.chooseExecutableAndRun(in: container.id)
                    }
                } label: {
                    if starterSetupIsBusy {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Continuing Steam Setup…")
                        }
                        .frame(minWidth: 150)
                    } else if store.isStoppingWineServer(in: container.id) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Stopping…")
                        }
                        .frame(minWidth: 150)
                    } else if let program, store.isLaunchingProgram(program, in: container.id) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting…")
                        }
                        .frame(minWidth: 150)
                    } else {
                        Label(
                            program.map {
                                String(
                                    localized: "Launch \($0.presentationName)",
                                    bundle: SwitchyardStrings.bundle
                                )
                            }
                                ?? (
                                    isSteamStarterContainer
                                        ? String(
                                            localized: "Continue Steam Setup",
                                            bundle: SwitchyardStrings.bundle
                                        )
                                        : String(
                                            localized: "Install or Run App…",
                                            bundle: SwitchyardStrings.bundle
                                        )
                                ),
                            systemImage: "play.fill"
                        )
                        .frame(minWidth: 150)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isContainerTransitioning(container.id) || starterSetupIsBusy)

                if isSteamStarterContainer,
                   let message = store.steamInstallationState.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .frame(maxWidth: 260, alignment: .trailing)
                } else if let launchHint {
                    Text(launchHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .dashboardPanel(emphasized: true)
    }

    private var isSteamStarterContainer: Bool {
        program == nil
            && container.starterApplicationID == StarterApplicationCatalog.steam.id
    }

    private var starterSetupIsBusy: Bool {
        isSteamStarterContainer
            && (store.isDownloadingSteamInstaller || store.steamInstallationState.isWorking)
    }

    private var launchHint: String? {
        switch store.sessionSnapshot(for: container.id).wineServerState {
        case .orphaned:
            String(
                localized: "Remaining Wine processes will be cleaned up before launch",
                bundle: SwitchyardStrings.bundle
            )
        case .active, .checking, .inactive, .unavailable:
            nil
        }
    }
}

private enum ProgramShelfSelection: Hashable {
    case recent
    case all
}

private struct ProgramShelfEntry: Identifiable {
    var id: String { program.id }
    let program: InstalledProgram
    let launchedAt: Date?
}

private struct InstalledProgramShelf: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let programs: [InstalledProgram]
    let recentPrograms: [RecentInstalledProgram]
    let maximumVisiblePrograms: Int
    @Binding var selectedProgramID: String?
    let onViewAll: () -> Void
    @State private var selection: ProgramShelfSelection = .recent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(
                    recentPrograms.isEmpty
                        ? String(
                            localized: "Installed Programs",
                            bundle: SwitchyardStrings.bundle
                        )
                        : String(localized: "Programs", bundle: SwitchyardStrings.bundle)
                )
                    .font(.headline)
                Spacer()

                if !recentPrograms.isEmpty {
                    Picker("Program Group", selection: $selection) {
                        Text("Recent").tag(ProgramShelfSelection.recent)
                        Text("All").tag(ProgramShelfSelection.all)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 138)
                }

                Button("View all", systemImage: "chevron.right", action: onViewAll)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.link)
            }

            if displayedEntries.isEmpty {
                ContentUnavailableView("No Programs Found", systemImage: "app.dashed")
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(displayedEntries.prefix(maximumVisiblePrograms)) { entry in
                        Button {
                            selectedProgramID = entry.program.id
                        } label: {
                            VStack(spacing: 6) {
                                WindowsProgramIconView(program: entry.program, size: 62)
                                Text(entry.program.presentationName)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 92)

                                if let launchedAt = entry.launchedAt {
                                    Text(relativeLaunchDescription(for: launchedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(9)
                            .background(
                                selectedProgramID == entry.program.id
                                    ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                if selectedProgramID == entry.program.id {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Launch") {
                                selectedProgramID = entry.program.id
                                store.runInstalledProgram(entry.program, in: container.id)
                            }
                            .disabled(store.isContainerTransitioning(container.id))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .dashboardPanel()
    }

    private var displayedEntries: [ProgramShelfEntry] {
        if selection == .recent, !recentPrograms.isEmpty {
            return recentPrograms.map {
                ProgramShelfEntry(program: $0.program, launchedAt: $0.launchedAt)
            }
        }
        return programs.map { ProgramShelfEntry(program: $0, launchedAt: nil) }
    }

    private func relativeLaunchDescription(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
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
