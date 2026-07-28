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

enum SessionStageTaskbarPolicy {
    private struct RunningGroup {
        let identity: String
        let windowsPath: String?
        var windows: [WineWindowSnapshot]
    }

    static func makeItems(
        windows: [WineWindowSnapshot],
        programs: [InstalledProgram],
        pinnedWindowsPaths: [String],
        prefixPath: String,
        selectedWindowID: CGWindowID?,
        fallbackName: String
    ) -> [SessionStageTaskbarItem] {
        let groups = runningGroups(windows: windows, prefixPath: prefixPath)
        let normalizedPins = pinnedWindowsPaths.compactMap {
            WineProtocolAssociationFormat.normalizedWindowsExecutablePath($0)
        }
        let pinSet = Set(normalizedPins.map { $0.lowercased() })

        let candidates = groups.map { group -> RunningCandidate in
            let catalogProgram = group.windows.lazy.compactMap {
                SessionStageWindowProgramMatcher.match(
                    window: $0,
                    programs: programs,
                    prefixPath: prefixPath
                )
            }.first
            let program = catalogProgram ?? group.windowsPath.flatMap {
                syntheticProgram(
                    windowsPath: $0,
                    prefixPath: prefixPath
                )
            }
            let programPath = program.flatMap {
                normalizedWindowsPath(
                    executablePath: $0.executablePath,
                    prefixPath: prefixPath
                )
            }
            let pinKey = [programPath, group.windowsPath]
                .compactMap { $0?.lowercased() }
                .first(where: pinSet.contains)
            let firstWindow = group.windows[0]
            let title = program?.presentationName
                ?? firstWindow.meaningfulTitle
                ?? firstWindow.executableDisplayName
                ?? fallbackName
            return RunningCandidate(
                identity: group.identity,
                pinKey: pinKey,
                program: program,
                title: title,
                windows: group.windows,
                isActive: group.windows.contains {
                    $0.id == selectedWindowID
                }
            )
        }

        var items: [SessionStageTaskbarItem] = []
        var consumedRunningIDs: Set<String> = []

        for pin in normalizedPins {
            if let candidate = candidates.first(where: {
                !consumedRunningIDs.contains($0.identity)
                    && $0.pinKey?.lowercased() == pin.lowercased()
            }) {
                consumedRunningIDs.insert(candidate.identity)
                items.append(
                    candidate.item(
                        isPinned: true,
                        stableID: "pin:\(pin.lowercased())"
                    )
                )
                continue
            }

            let program = programs.first(where: {
                normalizedWindowsPath(
                    executablePath: $0.executablePath,
                    prefixPath: prefixPath
                )?.lowercased() == pin.lowercased()
            }) ?? syntheticProgram(
                windowsPath: pin,
                prefixPath: prefixPath
            )
            guard let program else {
                continue
            }
            items.append(
                SessionStageTaskbarItem(
                    id: "pin:\(pin.lowercased())",
                    title: program.presentationName,
                    program: program,
                    windows: [],
                    isPinned: true,
                    isRunning: false,
                    isActive: false
                )
            )
        }

        items.append(contentsOf: candidates.compactMap { candidate in
            guard !consumedRunningIDs.contains(candidate.identity) else {
                return nil
            }
            return candidate.item(
                isPinned: false,
                stableID: "running:\(candidate.identity)"
            )
        })
        return items
    }

    private struct RunningCandidate {
        let identity: String
        let pinKey: String?
        let program: InstalledProgram?
        let title: String
        let windows: [WineWindowSnapshot]
        let isActive: Bool

        func item(isPinned: Bool, stableID: String) -> SessionStageTaskbarItem {
            SessionStageTaskbarItem(
                id: stableID,
                title: title,
                program: program,
                windows: windows,
                isPinned: isPinned,
                isRunning: true,
                isActive: isActive
            )
        }
    }

    private static func runningGroups(
        windows: [WineWindowSnapshot],
        prefixPath: String
    ) -> [RunningGroup] {
        var orderedIdentities: [String] = []
        var groups: [String: RunningGroup] = [:]

        for window in windows {
            let windowsPath = window.executablePath.flatMap {
                normalizedWindowsPath(
                    executablePath: $0,
                    prefixPath: prefixPath
                )
            }
            let identity = windowsPath.map { "exe:\($0.lowercased())" }
                ?? "pid:\(window.ownerProcessID)"
            if groups[identity] == nil {
                orderedIdentities.append(identity)
                groups[identity] = RunningGroup(
                    identity: identity,
                    windowsPath: windowsPath,
                    windows: []
                )
            }
            groups[identity]?.windows.append(window)
        }

        return orderedIdentities.compactMap { groups[$0] }
    }

    private static func normalizedWindowsPath(
        executablePath: String,
        prefixPath: String
    ) -> String? {
        let windowsPath = WineProtocolAssociationFormat.windowsExecutablePath(
            hostPath: executablePath,
            prefixPath: prefixPath
        ) ?? executablePath
        return WineProtocolAssociationFormat.normalizedWindowsExecutablePath(
            windowsPath.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'")
            )
        )
    }

    private static func syntheticProgram(
        windowsPath: String,
        prefixPath: String
    ) -> InstalledProgram? {
        guard let normalizedPath = WineProtocolAssociationFormat
            .normalizedWindowsExecutablePath(windowsPath),
            normalizedPath.prefix(3).lowercased() == "c:\\"
        else {
            return nil
        }

        let prefixURL = URL(
            fileURLWithPath: prefixPath,
            isDirectory: true
        ).standardizedFileURL
        let driveURL = prefixURL
            .appendingPathComponent("drive_c", isDirectory: true)
            .standardizedFileURL
        let components = normalizedPath
            .dropFirst(3)
            .split(separator: "\\")
            .map(String.init)
        let executableURL = components.reduce(driveURL) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL

        let resolvedDriveURL = driveURL.resolvingSymlinksInPath()
        let resolvedExecutableURL = executableURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(executableURL.lastPathComponent)
            .standardizedFileURL
        guard resolvedExecutableURL.path.hasPrefix(
            resolvedDriveURL.path + "/"
        ) else {
            return nil
        }

        let executableName = executableURL.deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executableName.isEmpty else { return nil }
        return InstalledProgram(
            name: executableName,
            executablePath: executableURL.path,
            installDirectory: executableURL.deletingLastPathComponent().path,
            source: .programFiles
        )
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
    @State private var inspectorPopoverPresented = false
    @State private var endSessionConfirmationPresented = false
    @State private var closeNotice: String?
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SessionStageBackdrop(container: liveContainer)

                VStack(spacing: 0) {
                    header
                        .frame(height: 76)
                        .padding(.horizontal, 28)

                    workspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    dock
                        .padding(.horizontal, 28)
                        .padding(.bottom, 20)
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
                        .padding(.bottom, 108)
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
                Text(liveContainer.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)

                if containerIsLaunching {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.72))
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(sessionStatusColor)
                        .frame(width: 8, height: 8)
                }

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
            let showsPersistentInspector = proxy.size.width >= 1_180

            HStack(spacing: 20) {
                windowGridWorkspace

                if showsPersistentInspector {
                    inspector
                        .frame(width: 328)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .overlay(alignment: .topTrailing) {
                if !showsPersistentInspector {
                    Button {
                        inspectorPopoverPresented.toggle()
                    } label: {
                        Label(
                            String(
                                localized: "Session Info",
                                bundle: SwitchyardStrings.bundle
                            ),
                            systemImage: "gauge.with.dots.needle.67percent"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                    }
                    .buttonStyle(SessionStageHeaderButtonStyle())
                    .padding(.trailing, 34)
                    .padding(.top, 20)
                    .popover(isPresented: $inspectorPopoverPresented, arrowEdge: .trailing) {
                        inspector
                            .frame(width: 328, height: min(620, proxy.size.height - 24))
                            .padding(8)
                            .preferredColorScheme(.dark)
                    }
                }
            }
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

    private var windowGridWorkspace: some View {
        GeometryReader { proxy in
            let bannerHeight: CGFloat = stageModel.screenRecordingAccessUnavailable ? 44 : 0
            let availableSize = CGSize(
                width: max(260, proxy.size.width - 24),
                height: max(190, proxy.size.height - 12 - bannerHeight)
            )
            let metrics = SessionStageWindowGridMetrics.make(
                windowCount: max(1, stageModel.windows.count),
                availableSize: availableSize
            )

            VStack(spacing: 12) {
                if stageModel.windows.isEmpty {
                    emptyWindowState
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
                                isSelected: window.id == stageModel.selectedWindowID,
                                isClosing: stageModel.closingWindowIDs.contains(window.id),
                                onClose: {
                                    requestClose(window)
                                }
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
                        stageModel.requestScreenRecordingAccess()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var dock: some View {
        SessionStageDock(
            items: taskbarItems,
            isStopping: store.isStoppingWineServer(in: container.id),
            onActivateOrLaunch: { item in
                startMenuPresented = false
                if let selectedWindow = item.windows.first(where: {
                    $0.id == stageModel.selectedWindowID
                }) ?? item.windows.first {
                    stageModel.activate(selectedWindow)
                } else if let program = item.program {
                    store.runInstalledProgram(program, in: container.id)
                }
            },
            onSetPinned: { item, pinned in
                guard let program = item.program else { return }
                store.setTaskbarProgram(program, pinned: pinned, in: container.id)
            },
            onAddApplication: {
                store.chooseExecutableAndRun(in: container.id)
            },
            startMenuPresented: $startMenuPresented
        )
    }

    private var startMenuPanel: some View {
        SessionStageStartMenu(
            container: container,
            entries: startMenuEntries,
            programs: programs,
            recentPrograms: recentPrograms,
            onLaunchProgram: { program in
                startMenuPresented = false
                store.runInstalledProgram(program, in: container.id)
            },
            onOpenShortcut: { entry in
                startMenuPresented = false
                store.runStartMenuEntry(entry, in: container.id)
            }
        )
    }

    private var inspector: some View {
        SessionStageInspector(
            wineServerState: sessionState,
            windows: stageModel.windows,
            processes: visibleProcesses,
            resources: stageModel.resourceSnapshot,
            notice: closeNotice ?? sessionSnapshot.message,
            isStoppingSession: store.isStoppingWineServer(in: container.id),
            onRefresh: refreshSession,
            onOpenActivity: {
                inspectorPopoverPresented = false
                onOpenDestination(.activity)
            },
            onEndSession: {
                endSessionConfirmationPresented = true
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
            let lhsDefault = lhs.executablePath == liveContainer.executablePath
            let rhsDefault = rhs.executablePath == liveContainer.executablePath
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
        sessionSnapshot.processes
    }

    private var liveContainer: Container {
        store.containers.first(where: { $0.id == container.id }) ?? container
    }

    private var sessionSnapshot: ContainerSessionSnapshot {
        store.sessionSnapshot(for: container.id)
    }

    private var sessionIsActive: Bool {
        sessionState.hasRunningProcesses
    }

    private var containerIsLaunching: Bool {
        store.isContainerLaunching(container.id)
    }

    private var sessionState: WineServerState {
        sessionSnapshot.wineServerState
    }

    private var sessionStatusColor: Color {
        switch sessionState {
        case .active:
            .green
        case .orphaned:
            .orange
        case .unavailable:
            .red.opacity(0.72)
        case .checking, .inactive:
            .white.opacity(0.32)
        }
    }

    private var sessionStatusText: String {
        if containerIsLaunching {
            return String(localized: "Starting…", bundle: SwitchyardStrings.bundle)
        }

        return switch sessionState {
        case .active:
            String(localized: "Running", bundle: SwitchyardStrings.bundle)
        case .orphaned:
            String(localized: "Cleanup needed", bundle: SwitchyardStrings.bundle)
        case .checking:
            String(localized: "Checking", bundle: SwitchyardStrings.bundle)
        case .inactive:
            String(localized: "Ready", bundle: SwitchyardStrings.bundle)
        case .unavailable:
            String(localized: "Unavailable", bundle: SwitchyardStrings.bundle)
        }
    }

    private var emptyWindowState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.045))
                Circle()
                    .strokeBorder(Color.white.opacity(0.09))

                if let fallbackProgram {
                    WindowsProgramIconView(program: fallbackProgram, size: 46)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .frame(width: 70, height: 70)

            VStack(spacing: 6) {
                Text(
                    containerIsLaunching
                        ? String(
                            localized: "Starting…",
                            bundle: SwitchyardStrings.bundle
                        )
                        : sessionIsActive
                        ? String(
                            localized: "No visible Windows app windows",
                            bundle: SwitchyardStrings.bundle
                        )
                        : String(
                            localized: "Ready",
                            bundle: SwitchyardStrings.bundle
                        )
                )
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))

                if let fallbackProgram, !sessionIsActive {
                    Text(fallbackProgram.presentationName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Button {
                if sessionIsActive {
                    onOpenDestination(.activity)
                } else if let fallbackProgram {
                    store.runInstalledProgram(fallbackProgram, in: container.id)
                } else {
                    store.chooseExecutableAndRun(in: container.id)
                }
            } label: {
                Group {
                    if containerIsLaunching {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.88))
                            .frame(width: 44)
                    } else {
                        Label(
                            sessionIsActive
                                ? String(
                                    localized: "Activity",
                                    bundle: SwitchyardStrings.bundle
                                )
                                : String(
                                    localized: "Run",
                                    bundle: SwitchyardStrings.bundle
                                ),
                            systemImage: sessionIsActive ? "waveform.path.ecg" : "play.fill"
                        )
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
            }
            .buttonStyle(SessionStageHeaderButtonStyle())
            .disabled(containerIsLaunching)
            .accessibilityLabel(
                containerIsLaunching
                    ? String(localized: "Starting…", bundle: SwitchyardStrings.bundle)
                    : sessionIsActive
                    ? String(localized: "Activity", bundle: SwitchyardStrings.bundle)
                    : String(localized: "Run", bundle: SwitchyardStrings.bundle)
            )
            .accessibilityIdentifier("sessionStage.primaryAction")
        }
        .padding(28)
        .background(
            Color.black.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055))
        }
        .accessibilityElement(children: .contain)
    }

    private var fallbackProgram: InstalledProgram? {
        programs.first(where: { $0.executablePath == liveContainer.executablePath })
            ?? programs.first
    }

    private var taskbarItems: [SessionStageTaskbarItem] {
        SessionStageTaskbarPolicy.makeItems(
            windows: stageModel.windows,
            programs: programs,
            pinnedWindowsPaths: liveContainer.pinnedWindowsExecutablePaths,
            prefixPath: liveContainer.path,
            selectedWindowID: stageModel.selectedWindowID,
            fallbackName: liveContainer.name
        )
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
            prefixPath: liveContainer.path
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
            fallbackName: liveContainer.name,
            position: index + 1,
            total: stageModel.windows.count
        )
    }

    private func refreshSession() {
        Task {
            await store.refreshContainerSession(for: container.id)
            await stageModel.refresh(containerID: container.id, store: store)
        }
    }

    private func requestClose(_ window: WineWindowSnapshot) {
        Task {
            let result = await stageModel.close(window)
            await stageModel.refresh(containerID: container.id, store: store)
            guard result != .requested else { return }

            let notice = closeNotice(for: result)
            closeNotice = notice
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, closeNotice == notice {
                closeNotice = nil
            }
        }
    }

    private func closeNotice(for result: WineWindowCloseResult) -> String {
        switch result {
        case .requested:
            return ""
        case .accessibilityPermissionRequired:
            return String(
                localized: "Allow Accessibility access to close individual Windows app windows.",
                bundle: SwitchyardStrings.bundle
            )
        case .staleWindow:
            return String(
                localized: "This window is no longer available.",
                bundle: SwitchyardStrings.bundle
            )
        case .ambiguousWindow:
            return String(
                localized: "Switchyard could not safely identify this window.",
                bundle: SwitchyardStrings.bundle
            )
        case .closeUnsupported:
            return String(
                localized: "This app does not expose a close control for this window.",
                bundle: SwitchyardStrings.bundle
            )
        case .unresponsive:
            return String(
                localized: "The app did not respond to the close request.",
                bundle: SwitchyardStrings.bundle
            )
        case .operationFailed:
            return String(
                localized: "Could not close this window.",
                bundle: SwitchyardStrings.bundle
            )
        }
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
