import AppCore
import SwiftUI

struct SessionStageDock<TaskViewContent: View>: View {
    let container: Container
    let programs: [InstalledProgram]
    let runningExecutablePaths: Set<String>
    let windowCount: Int
    let processCount: Int
    let sessionIsActive: Bool
    let isStoppingSession: Bool
    let onLaunchProgram: (InstalledProgram) -> Void
    let onAddApplication: () -> Void
    let onEndSession: () -> Void
    let taskViewContent: () -> TaskViewContent
    @Binding var startMenuPresented: Bool
    @Binding var taskViewPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var powerIsHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                taskViewPresented = false
                startMenuPresented.toggle()
            } label: {
                SessionStageDockItem(
                    title: "Start Menu",
                    systemImage: "square.grid.3x3.fill",
                    isSelected: startMenuPresented,
                    statusColor: .blue
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessionStage.startMenu")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(programs.prefix(6)) { program in
                        Button {
                            onLaunchProgram(program)
                        } label: {
                            SessionStageProgramDockItem(
                                program: program,
                                isRunning: programIsRunning(program)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isStoppingSession)
                    }

                    Button(action: onAddApplication) {
                        SessionStageDockItem(
                            title: "Add App",
                            systemImage: "plus",
                            isSelected: false,
                            statusColor: nil
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isStoppingSession)
                }
            }
            .frame(maxWidth: 650, alignment: .leading)

            dockDivider

            Button {
                startMenuPresented = false
                taskViewPresented.toggle()
            } label: {
                SessionStageDockItem(
                    title: "Task View",
                    systemImage: "square.on.square",
                    isSelected: taskViewPresented,
                    statusColor: nil,
                    badge: windowCount > 0 ? windowCount : nil
                )
            }
            .buttonStyle(.plain)
            .popover(
                isPresented: $taskViewPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                taskViewContent()
            }
            .accessibilityIdentifier("sessionStage.taskView")

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text(sessionSummary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(sessionIsActive ? 0.82 : 0.48))
                        .lineLimit(1)

                    if sessionIsActive {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
                .padding(.leading, 16)

                Button(action: onEndSession) {
                    Group {
                        if isStoppingSession {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white.opacity(sessionIsActive ? 0.96 : 0.34))
                    .background(
                        sessionIsActive && powerIsHovering
                            ? Color.red.opacity(0.92)
                            : Color.white.opacity(sessionIsActive ? 0.08 : 0.035),
                        in: Circle()
                    )
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.16),
                        value: powerIsHovering
                    )
                }
                .buttonStyle(.plain)
                .disabled(!sessionIsActive || isStoppingSession)
                .onHover { powerIsHovering = $0 }
                .help("End Windows Session")
                .accessibilityIdentifier("sessionStage.endSession")
            }
            .padding(5)
            .background(.black.opacity(0.24), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.13))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 116, maxHeight: 124)
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.34), radius: 24, y: 12)
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 88)
            .padding(.horizontal, 4)
    }

    private var sessionSummary: String {
        guard sessionIsActive else {
            return String(localized: "Session idle", bundle: SwitchyardStrings.bundle)
        }
        if windowCount > 0 {
            if windowCount == 1 {
                return String(
                    localized: "\(windowCount) window running",
                    bundle: SwitchyardStrings.bundle
                )
            }
            return String(
                localized: "\(windowCount) windows running",
                bundle: SwitchyardStrings.bundle
            )
        }
        if processCount == 1 {
            return String(
                localized: "\(processCount) process running",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "\(processCount) processes running",
            bundle: SwitchyardStrings.bundle
        )
    }

    private func programIsRunning(_ program: InstalledProgram) -> Bool {
        guard let windowsPath = WineProtocolAssociationFormat.windowsExecutablePath(
            hostPath: program.executablePath,
            prefixPath: container.path
        ) else {
            return false
        }
        return runningExecutablePaths.contains(windowsPath.lowercased())
    }
}

private struct SessionStageProgramDockItem: View {
    let program: InstalledProgram
    let isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 7) {
            WindowsProgramIconView(
                program: program,
                size: isHovering && !reduceMotion ? 54 : 49
            )
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.18),
                    value: isHovering
                )
                .frame(width: 58, height: 58, alignment: .bottom)

            Text(program.presentationName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 82, height: 28, alignment: .top)

            Circle()
                .fill(isRunning ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
        }
        .frame(width: 88, height: 100)
        .background(
            isHovering ? Color.white.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

private struct SessionStageDockItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let statusColor: Color?
    var badge: Int?

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 52, height: 52)
                    .background(
                        Color.white.opacity(isSelected ? 0.13 : 0.065),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(isSelected ? 0.22 : 0.1))
                    }

                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 21, minHeight: 21)
                        .background(Color.blue, in: Capsule())
                        .offset(x: 7, y: -7)
                }
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)

            Circle()
                .fill(statusColor ?? .clear)
                .frame(width: 6, height: 6)
        }
        .frame(width: 88, height: 100)
        .background(
            isHovering || isSelected ? Color.white.opacity(0.07) : .clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

struct SessionStageStartMenu: View {
    let container: Container
    let entries: [WindowsStartMenuEntry]
    let programs: [InstalledProgram]
    let recentPrograms: [RecentInstalledProgram]
    let onLaunchProgram: (InstalledProgram) -> Void
    let onOpenShortcut: (WindowsStartMenuEntry) -> Void
    let onOpenWindowsDesktop: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Start Menu", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 11)
            .frame(height: 35)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.white.opacity(0.1))
            }
            .padding(12)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if query.isEmpty, let defaultProgram = defaultProgram {
                        menuSectionTitle(container.name)
                        programRow(defaultProgram, trailing: "Run")
                    }

                    if !filteredEntries.isEmpty {
                        menuSectionTitle(query.isEmpty ? "Start Menu" : "Results")
                        ForEach(filteredEntries.prefix(14)) { entry in
                            shortcutRow(entry)
                        }
                    } else if !query.isEmpty, matchingPrograms.isEmpty {
                        Text("No matching apps")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }

                    if !matchingPrograms.isEmpty {
                        menuSectionTitle(query.isEmpty ? "Installed Apps" : "Apps")
                        ForEach(matchingPrograms.prefix(8)) { program in
                            programRow(program)
                        }
                    }

                    if query.isEmpty, !recentPrograms.isEmpty {
                        menuSectionTitle("Recently Opened")
                        ForEach(recentPrograms.prefix(3)) { recent in
                            programRow(recent.program)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 330)

            Divider()
                .overlay(Color.white.opacity(0.12))

            Button(action: onOpenWindowsDesktop) {
                HStack {
                    Image(systemName: "rectangle.inset.filled")
                    Text("Open Windows Desktop")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 44)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 344)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14))
        }
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
        .preferredColorScheme(.dark)
    }

    private var defaultProgram: InstalledProgram? {
        programs.first(where: { $0.executablePath == container.executablePath })
            ?? programs.first
    }

    private var filteredEntries: [WindowsStartMenuEntry] {
        let source = entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard !query.isEmpty else { return source }
        return source.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.groupPath.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingPrograms: [InstalledProgram] {
        let unique = programs.filter { $0.executablePath != defaultProgram?.executablePath }
        guard !query.isEmpty else {
            return unique.filter { !$0.isSystemUtility }
        }
        return unique.filter {
            $0.presentationName.localizedCaseInsensitiveContains(query)
        }
    }

    private func matchingProgram(for entry: WindowsStartMenuEntry) -> InstalledProgram? {
        let normalizedEntry = normalizedName(entry.displayName)
        return programs.first { program in
            let normalizedProgram = normalizedName(program.presentationName)
            return normalizedProgram == normalizedEntry
                || normalizedProgram.contains(normalizedEntry)
                || normalizedEntry.contains(normalizedProgram)
        }
    }

    private func normalizedName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func menuSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.top, 7)
            .padding(.bottom, 2)
    }

    private func shortcutRow(_ entry: WindowsStartMenuEntry) -> some View {
        Button {
            onOpenShortcut(entry)
        } label: {
            HStack(spacing: 10) {
                if let program = matchingProgram(for: entry) {
                    WindowsProgramIconView(program: program, size: 30)
                } else {
                    Image(systemName: entry.kind == .url ? "link" : "app.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(
                            Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if !entry.groupPath.isEmpty {
                        Text(entry.groupPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionStageMenuRowStyle())
    }

    private func programRow(
        _ program: InstalledProgram,
        trailing: String? = nil
    ) -> some View {
        Button {
            onLaunchProgram(program)
        } label: {
            HStack(spacing: 10) {
                WindowsProgramIconView(program: program, size: 30)
                Text(program.presentationName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionStageMenuRowStyle())
    }
}

private struct SessionStageMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.white.opacity(configuration.isPressed ? 0.1 : 0),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}

struct SessionStageTaskView: View {
    let windows: [WineWindowSnapshot]
    let processes: [WindowsProcessSnapshot]
    let selectedWindowID: CGWindowID?
    let onSelectWindow: (WineWindowSnapshot) -> Void
    let onOpenActivity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Task View")
                .font(.headline)
                .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(windows) { window in
                        Button {
                            onSelectWindow(window)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "macwindow")
                                    .foregroundStyle(
                                        window.id == selectedWindowID ? Color.blue : Color.secondary
                                    )
                                Text(window.title)
                                    .lineLimit(1)
                                Spacer()
                                if window.id == selectedWindowID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SessionStageMenuRowStyle())
                    }

                    if windows.isEmpty {
                        Text("No visible Windows app windows")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 70)
                    }

                    if !processes.isEmpty {
                        Divider().padding(.vertical, 5)
                        ForEach(processes.prefix(8)) { process in
                            HStack {
                                Image(systemName: process.isSystemProcess ? "gearshape.2" : "app")
                                    .foregroundStyle(.secondary)
                                Text(process.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(process.kind)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 330)

            Divider()

            Button(action: onOpenActivity) {
                Label("Open Activity", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 330)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }
}
