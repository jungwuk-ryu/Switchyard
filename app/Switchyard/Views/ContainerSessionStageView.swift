import AppCore
import CoreGraphics
import SwiftUI

enum ContainerDetailDestination {
    case applications
    case files
    case activity
    case settings
}

enum SessionStageWindowProgramMatcher {
    static func match(
        window: WineWindowSnapshot,
        programs: [InstalledProgram],
        prefixPath: String
    ) -> InstalledProgram? {
        if let executablePath = window.executablePath {
            let capturedWindowsPath = WineProtocolAssociationFormat.windowsExecutablePath(
                hostPath: executablePath,
                prefixPath: prefixPath
            ) ?? executablePath
            let normalizedExecutablePath = normalizedWindowsPath(capturedWindowsPath)
            if let exactMatch = programs.first(where: { program in
                guard let windowsPath = WineProtocolAssociationFormat.windowsExecutablePath(
                    hostPath: program.executablePath,
                    prefixPath: prefixPath
                ) else {
                    return false
                }
                return normalizedWindowsPath(windowsPath) == normalizedExecutablePath
            }) {
                return exactMatch
            }

            let executableName = normalizedWindowsExecutableName(capturedWindowsPath)
            let basenameMatches = programs.filter { program in
                guard let windowsPath = WineProtocolAssociationFormat.windowsExecutablePath(
                    hostPath: program.executablePath,
                    prefixPath: prefixPath
                ) else {
                    return false
                }
                return normalizedWindowsExecutableName(windowsPath) == executableName
            }
            if basenameMatches.count == 1 {
                return basenameMatches[0]
            }
        }

        guard let meaningfulTitle = window.meaningfulTitle else { return nil }
        let normalizedTitle = normalizedName(meaningfulTitle)
        guard !normalizedTitle.isEmpty else { return nil }
        return programs.first { program in
            let normalizedProgram = normalizedName(program.presentationName)
            guard !normalizedProgram.isEmpty else { return false }
            return normalizedTitle.contains(normalizedProgram)
                || normalizedProgram.contains(normalizedTitle)
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalizedWindowsPath(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "/", with: "\\")
            .lowercased()
    }

    private static func normalizedWindowsExecutableName(_ value: String) -> String {
        normalizedWindowsPath(value)
            .split(separator: "\\")
            .last
            .map(String.init)
            ?? ""
    }
}

struct ContainerSessionStageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let container: Container
    let onBack: () -> Void
    let onOpenDestination: (ContainerDetailDestination) -> Void
    let onDelete: () -> Void

    @StateObject private var stageModel = ContainerSessionStageModel()
    @State private var searchText = ""
    @State private var startMenuPresented = false
    @State private var endSessionConfirmationPresented = false
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SessionStageBackdrop()

                VStack(spacing: 0) {
                    header
                        .frame(height: 76)
                        .padding(.horizontal, 28)

                    workspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    dock
                        .padding(.horizontal, 28)
                        .padding(.bottom, 24)
                }

                if searchIsFocused, !searchText.isEmpty {
                    searchResults
                        .frame(width: min(430, max(320, proxy.size.width * 0.34)))
                        .position(x: proxy.size.width / 2, y: 145)
                        .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                        .zIndex(20)
                }

                if startMenuPresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            startMenuPresented = false
                        }
                        .zIndex(21)

                    startMenuPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 52)
                        .padding(.bottom, 142)
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .scale(scale: 0.97, anchor: .bottomLeading))
                                .combined(with: .opacity)
                        )
                        .zIndex(22)
                }

                commandKShortcut
            }
        }
        .preferredColorScheme(.dark)
        .task(id: container.id) {
            await stageModel.monitor(containerID: container.id, store: store)
        }
        .confirmationDialog(
            "End Windows Session?",
            isPresented: $endSessionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("End Session", role: .destructive) {
                Task {
                    await store.stopWineServer(in: container.id)
                    await stageModel.refresh(containerID: container.id, store: store)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Windows app in this container will close. Unsaved work may be lost.")
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.25),
            value: searchIsFocused && !searchText.isEmpty
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: startMenuPresented
        )
        .accessibilityIdentifier("container.sessionStage")
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white.opacity(0.82))
                    .background(.black.opacity(0.23), in: Circle())
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.14))
                    }
            }
            .buttonStyle(.plain)
            .help("Back to Containers")

            HStack(spacing: 9) {
                Text(container.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)

                Circle()
                    .fill(sessionStatusColor)
                    .frame(width: 8, height: 8)

                Text(sessionStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            .frame(maxWidth: 250, alignment: .leading)

            Spacer(minLength: 20)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.58))

                TextField("Search apps or tasks", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .onSubmit(launchFirstSearchResult)

                Text("⌘K")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .frame(width: 360, height: 39)
            .background(.black.opacity(0.24), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    searchIsFocused
                        ? Color.blue.opacity(0.52)
                        : Color.white.opacity(0.13)
                )
            }

            Spacer(minLength: 20)

            Button {
                store.chooseExecutableAndRun(in: container.id)
            } label: {
                Label("New App", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 39)
            }
            .buttonStyle(SessionStageHeaderButtonStyle())
            .disabled(store.isContainerTransitioning(container.id))
            .accessibilityIdentifier("sessionStage.newApp")

            Menu {
                Button("Applications") {
                    onOpenDestination(.applications)
                }
                Button("Files") {
                    onOpenDestination(.files)
                }
                Button("Activity") {
                    onOpenDestination(.activity)
                }
                Divider()
                Button("Show in Finder") {
                    store.openContainerInFinder(container.id)
                }
                Button("Container Settings") {
                    onOpenDestination(.settings)
                }
                Divider()
                Button("Move to Trash", role: .destructive, action: onDelete)
            } label: {
                Label("More", systemImage: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 39)
            }
            .menuStyle(.button)
            .buttonStyle(SessionStageHeaderButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Container Actions")
            .accessibilityLabel("More Container Actions")
        }
    }

    private var workspace: some View {
        GeometryReader { proxy in
            let bannerHeight: CGFloat = stageModel.screenRecordingAccessUnavailable ? 44 : 0
            let availableSize = CGSize(
                width: max(220, proxy.size.width - 96),
                height: max(156, proxy.size.height - 36 - bannerHeight)
            )
            let metrics = SessionStageWindowGridMetrics.make(
                windowCount: max(1, stageModel.windows.count),
                availableSize: availableSize
            )

            VStack(spacing: 12) {
                if stageModel.windows.isEmpty {
                    emptyWindowCard
                        .frame(
                            width: metrics.cardSize.width,
                            height: metrics.cardSize.height
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(
                        .vertical,
                        showsIndicators: metrics.contentHeight > availableSize.height
                    ) {
                        SessionStageWindowGrid(
                            itemCount: stageModel.windows.count,
                            metrics: metrics
                        ) { index in
                            let window = stageModel.windows[index]
                            let program = program(for: window)
                            SessionStageWindowCard(
                                window: window,
                                program: program,
                                presentation: windowPresentation(
                                    for: window,
                                    program: program,
                                    index: index
                                ),
                                isRunning: true,
                                isSelected: window.id == stageModel.selectedWindowID
                            ) {
                                stageModel.activate(window)
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: min(metrics.contentHeight, availableSize.height)
                        )
                        .padding(.vertical, 8)
                    }
                }

                if stageModel.screenRecordingAccessUnavailable,
                   let message = stageModel.previewMessage {
                    SessionStagePreviewPermissionBanner(message: message) {
                        stageModel.openScreenRecordingSettings()
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 18)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84),
            value: stageModel.selectedWindowID
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.28),
            value: stageModel.windows.map(\.id)
        )
    }

    private var dock: some View {
        SessionStageDock(
            container: container,
            programs: dockPrograms,
            runningExecutablePaths: runningExecutablePaths,
            windowCount: stageModel.windows.count,
            processCount: visibleProcesses.count,
            sessionIsActive: sessionIsActive,
            isStoppingSession: store.isStoppingWineServer(in: container.id),
            onLaunchProgram: { program in
                startMenuPresented = false
                store.runInstalledProgram(program, in: container.id)
            },
            onAddApplication: {
                store.chooseExecutableAndRun(in: container.id)
            },
            onEndSession: {
                endSessionConfirmationPresented = true
            },
            startMenuPresented: $startMenuPresented
        )
    }

    private var startMenuPanel: some View {
        SessionStageStartMenu(
            container: container,
            entries: startMenuEntries,
            programs: dockPrograms,
            recentPrograms: recentPrograms,
            onLaunchProgram: { program in
                startMenuPresented = false
                store.runInstalledProgram(program, in: container.id)
            },
            onOpenShortcut: { entry in
                startMenuPresented = false
                store.runStartMenuEntry(entry, in: container.id)
            },
            onOpenWindowsDesktop: {
                startMenuPresented = false
                store.openWindowsDesktop(in: container.id)
            }
        )
    }

    private var searchResults: some View {
        VStack(spacing: 4) {
            ForEach(searchPrograms.prefix(5)) { program in
                Button {
                    searchText = ""
                    searchIsFocused = false
                    store.runInstalledProgram(program, in: container.id)
                } label: {
                    HStack(spacing: 10) {
                        WindowsProgramIconView(program: program, size: 30)
                        Text(program.presentationName)
                            .lineLimit(1)
                        Spacer()
                        Text("Run")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 43)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SessionStageSearchRowStyle())
            }

            ForEach(searchStartMenuEntries.prefix(max(0, 7 - searchPrograms.count))) { entry in
                Button {
                    searchText = ""
                    searchIsFocused = false
                    store.runStartMenuEntry(entry, in: container.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.kind == .url ? "link" : "app.fill")
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .lineLimit(1)
                            if !entry.groupPath.isEmpty {
                                Text(entry.groupPath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 43)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SessionStageSearchRowStyle())
            }

            if searchPrograms.isEmpty, searchStartMenuEntries.isEmpty {
                Text("No matching apps or tasks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.13))
        }
        .shadow(color: .black.opacity(0.44), radius: 20, y: 10)
    }

    private var commandKShortcut: some View {
        Button {
            searchIsFocused = true
        } label: {
            Color.clear.frame(width: 1, height: 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var programs: [InstalledProgram] {
        let sortedPrograms = store.installedPrograms(for: container.id).sorted { lhs, rhs in
            let lhsDefault = lhs.executablePath == container.executablePath
            let rhsDefault = rhs.executablePath == container.executablePath
            if lhsDefault != rhsDefault { return lhsDefault }
            if lhs.isSystemUtility != rhs.isSystemUtility { return !lhs.isSystemUtility }
            return lhs.presentationName.localizedStandardCompare(rhs.presentationName)
                == .orderedAscending
        }
        var seenNames: Set<String> = []
        return sortedPrograms.filter {
            seenNames.insert($0.presentationName.lowercased()).inserted
        }
    }

    private var recentPrograms: [RecentInstalledProgram] {
        store.recentInstalledPrograms(for: container.id)
    }

    private var startMenuEntries: [WindowsStartMenuEntry] {
        store.startMenuEntries(for: container.id)
    }

    private var visibleProcesses: [WindowsProcessSnapshot] {
        store.sessionSnapshot(for: container.id).processes
    }

    private var sessionIsActive: Bool {
        sessionState.hasRunningProcesses
    }

    private var sessionState: WineServerState {
        store.sessionSnapshot(for: container.id).wineServerState
    }

    private var sessionStatusColor: Color {
        switch sessionState {
        case .active:
            .green
        case .orphaned:
            .orange
        case .checking, .inactive, .unavailable:
            .white.opacity(0.32)
        }
    }

    private var sessionStatusText: String {
        switch sessionState {
        case .active:
            String(localized: "Running", bundle: SwitchyardStrings.bundle)
        case .orphaned:
            String(localized: "Cleanup needed", bundle: SwitchyardStrings.bundle)
        case .checking:
            String(localized: "Checking", bundle: SwitchyardStrings.bundle)
        case .inactive, .unavailable:
            String(localized: "Ready", bundle: SwitchyardStrings.bundle)
        }
    }

    private var runningExecutablePaths: Set<String> {
        Set(visibleProcesses.map { $0.executablePath.lowercased() })
    }

    private var emptyWindowCard: some View {
        let title = sessionIsActive
            ? String(localized: "Windows Session", bundle: SwitchyardStrings.bundle)
            : fallbackProgram?.presentationName
                ?? String(localized: "Windows Session", bundle: SwitchyardStrings.bundle)
        let detail = sessionIsActive
            ? String(
                localized: "No visible Windows app windows",
                bundle: SwitchyardStrings.bundle
            )
            : String(localized: "Ready", bundle: SwitchyardStrings.bundle)
        return SessionStageWindowCard(
            window: nil,
            program: fallbackProgram,
            presentation: SessionStageWindowPresentation(
                title: title,
                detail: detail,
                position: 1,
                total: 1
            ),
            isRunning: sessionIsActive,
            isSelected: false
        ) {
            if sessionIsActive {
                onOpenDestination(.activity)
            } else if let fallbackProgram {
                store.runInstalledProgram(fallbackProgram, in: container.id)
            } else {
                store.chooseExecutableAndRun(in: container.id)
            }
        }
    }

    private var fallbackProgram: InstalledProgram? {
        programs.first(where: { $0.executablePath == container.executablePath })
            ?? programs.first
    }

    private var dockPrograms: [InstalledProgram] {
        var seenPaths: Set<String> = []
        return (recentPrograms.map(\.program) + programs)
            .filter { !$0.isSystemUtility }
            .filter { seenPaths.insert($0.executablePath).inserted }
    }

    private var searchPrograms: [InstalledProgram] {
        guard !normalizedSearchQuery.isEmpty else { return [] }
        return programs.filter {
            $0.presentationName.localizedCaseInsensitiveContains(normalizedSearchQuery)
        }
    }

    private var searchStartMenuEntries: [WindowsStartMenuEntry] {
        guard !normalizedSearchQuery.isEmpty else { return [] }
        return startMenuEntries.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalizedSearchQuery)
                || $0.groupPath.localizedCaseInsensitiveContains(normalizedSearchQuery)
        }
    }

    private func launchFirstSearchResult() {
        guard !normalizedSearchQuery.isEmpty else { return }
        if let program = searchPrograms.first {
            searchText = ""
            searchIsFocused = false
            store.runInstalledProgram(program, in: container.id)
        } else if let entry = searchStartMenuEntries.first {
            searchText = ""
            searchIsFocused = false
            store.runStartMenuEntry(entry, in: container.id)
        }
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func program(for window: WineWindowSnapshot?) -> InstalledProgram? {
        guard let window else { return nil }
        return SessionStageWindowProgramMatcher.match(
            window: window,
            programs: programs,
            prefixPath: container.path
        )
    }

    private func windowPresentation(
        for window: WineWindowSnapshot,
        program: InstalledProgram?,
        index: Int
    ) -> SessionStageWindowPresentation {
        SessionStageWindowPresentation.make(
            window: window,
            programName: program?.presentationName,
            fallbackName: container.name,
            position: index + 1,
            total: stageModel.windows.count
        )
    }

}

private struct SessionStageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.018, green: 0.03, blue: 0.055),
                    Color(red: 0.025, green: 0.055, blue: 0.105),
                    Color(red: 0.035, green: 0.075, blue: 0.145),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.3, blue: 0.62).opacity(0.25),
                    .clear,
                ],
                center: UnitPoint(x: 0.45, y: 0.61),
                startRadius: 30,
                endRadius: 560
            )

            RadialGradient(
                colors: [
                    Color(red: 0.18, green: 0.35, blue: 0.66).opacity(0.13),
                    .clear,
                ],
                center: UnitPoint(x: 0.84, y: 0.43),
                startRadius: 20,
                endRadius: 420
            )

            VStack {
                Spacer()
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.blue.opacity(0.08), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 150)
                    .blur(radius: 32)
                    .offset(y: 42)
            }
        }
        .ignoresSafeArea()
    }
}

private struct SessionStageHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.88))
            .background(
                Color.black.opacity(configuration.isPressed ? 0.38 : 0.22),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14))
            }
    }
}

private struct SessionStageSearchRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.white.opacity(configuration.isPressed ? 0.1 : 0),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}
