import AppCore
import AppKit
import SwiftUI

struct SessionStageTaskbarItem: Identifiable {
    let id: String
    let title: String
    let program: InstalledProgram?
    let windows: [WineWindowSnapshot]
    let isPinned: Bool
    let isRunning: Bool
    let isActive: Bool

    var applicationIconData: Data? {
        windows.lazy.compactMap(\.applicationIconData).first
    }
}

struct SessionStageDock: View {
    let items: [SessionStageTaskbarItem]
    let isStopping: Bool
    let onActivateOrLaunch: (SessionStageTaskbarItem) -> Void
    let onSetPinned: (SessionStageTaskbarItem, Bool) -> Void
    let onAddApplication: () -> Void
    @Binding var startMenuPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    startMenuPresented.toggle()
                }
            } label: {
                SessionStageTaskbarSystemItem(
                    systemImage: "square.grid.3x3.fill",
                    isActive: startMenuPresented,
                    showsIndicator: startMenuPresented
                )
            }
            .buttonStyle(.plain)
            .help(String(localized: "Start Menu", bundle: SwitchyardStrings.bundle))
            .accessibilityLabel(
                Text(String(localized: "Start Menu", bundle: SwitchyardStrings.bundle))
            )
            .accessibilityValue(
                Text(
                    startMenuPresented
                        ? String(localized: "Open", bundle: SwitchyardStrings.bundle)
                        : String(localized: "Closed", bundle: SwitchyardStrings.bundle)
                )
            )
            .accessibilityIdentifier("sessionStage.startMenu")

            taskbarDivider

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pinnedItems) { item in
                        taskbarButton(for: item)
                    }

                    if !pinnedItems.isEmpty, !runningUnpinnedItems.isEmpty {
                        taskbarDivider
                            .padding(.horizontal, 2)
                    }

                    ForEach(runningUnpinnedItems) { item in
                        taskbarButton(for: item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            taskbarDivider

            Button(action: onAddApplication) {
                SessionStageTaskbarSystemItem(
                    systemImage: "plus",
                    isActive: false,
                    showsIndicator: false
                )
            }
            .buttonStyle(.plain)
            .disabled(isStopping)
            .help(String(localized: "Add App", bundle: SwitchyardStrings.bundle))
            .accessibilityLabel(
                Text(String(localized: "Add App", bundle: SwitchyardStrings.bundle))
            )
            .accessibilityIdentifier("sessionStage.addApplication")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.035, green: 0.05, blue: 0.075).opacity(0.98))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(reduceTransparency ? 0.18 : 0.11))
        }
        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
    }

    private var pinnedItems: [SessionStageTaskbarItem] {
        items.filter(\.isPinned)
    }

    private var runningUnpinnedItems: [SessionStageTaskbarItem] {
        items.filter { !$0.isPinned && $0.isRunning }
    }

    private var taskbarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.13))
            .frame(width: 1, height: 34)
            .accessibilityHidden(true)
    }

    private func taskbarButton(for item: SessionStageTaskbarItem) -> some View {
        Button {
            onActivateOrLaunch(item)
        } label: {
            SessionStageTaskbarProgramItem(item: item)
        }
        .buttonStyle(.plain)
        .disabled(isStopping)
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityValue(Text(accessibilityValue(for: item)))
        .accessibilityHint(
            Text(
                item.isRunning
                    ? String(localized: "Activate", bundle: SwitchyardStrings.bundle)
                    : String(localized: "Open", bundle: SwitchyardStrings.bundle)
            )
        )
        .contextMenu {
            Button {
                onActivateOrLaunch(item)
            } label: {
                Label(
                    item.isRunning
                        ? String(localized: "Activate", bundle: SwitchyardStrings.bundle)
                        : String(localized: "Open", bundle: SwitchyardStrings.bundle),
                    systemImage: item.isRunning ? "rectangle.on.rectangle" : "play.fill"
                )
            }

            if item.program != nil || item.isPinned {
                Divider()

                Button {
                    onSetPinned(item, !item.isPinned)
                } label: {
                    Label(
                        item.isPinned
                            ? String(
                                localized: "Unpin from taskbar",
                                bundle: SwitchyardStrings.bundle
                            )
                            : String(
                                localized: "Pin to taskbar",
                                bundle: SwitchyardStrings.bundle
                            ),
                        systemImage: item.isPinned ? "pin.slash" : "pin"
                    )
                }
            }
        }
    }

    private func accessibilityValue(for item: SessionStageTaskbarItem) -> String {
        var values: [String] = []
        if item.isActive {
            values.append(String(localized: "Active", bundle: SwitchyardStrings.bundle))
        } else if item.isRunning {
            values.append(String(localized: "Running", bundle: SwitchyardStrings.bundle))
        }
        if item.isPinned {
            values.append(String(localized: "Pinned", bundle: SwitchyardStrings.bundle))
        }
        if item.windows.count > 1 {
            values.append(
                String(
                    localized: "\(item.windows.count) windows",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        return values.joined(separator: ", ")
    }
}

private struct SessionStageTaskbarProgramItem: View {
    let item: SessionStageTaskbarItem

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                SessionStageApplicationIconView(
                    program: item.program,
                    applicationIconData: item.applicationIconData,
                    size: 38
                )
                .scaleEffect(isHovering && !reduceMotion ? 1.04 : 1)
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isHovering)

                Capsule()
                    .fill(item.isRunning ? Color.blue : Color.clear)
                    .frame(width: item.isActive ? 22 : 10, height: 3)
                    .shadow(
                        color: item.isActive ? Color.blue.opacity(0.75) : .clear,
                        radius: 4
                    )
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: item.isActive)
            }
            .frame(width: 54, height: 56)

            if item.windows.count > 1 {
                Text(item.windows.count, format: .number)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.blue, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.black.opacity(0.38), lineWidth: 1)
                    }
                    .offset(x: 4, y: -3)
                    .accessibilityHidden(true)
            }
        }
        .background(
            Color.white.opacity(item.isActive ? 0.13 : (isHovering ? 0.085 : 0)),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            if item.isActive {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

private struct SessionStageTaskbarSystemItem: View {
    let systemImage: String
    let isActive: Bool
    let showsIndicator: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 38)

            Capsule()
                .fill(showsIndicator ? Color.blue : Color.clear)
                .frame(width: isActive ? 22 : 10, height: 3)
        }
        .frame(width: 52, height: 56)
        .background(
            Color.white.opacity(isActive ? 0.13 : (isHovering ? 0.08 : 0)),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(isActive ? 0.16 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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

    @State private var query = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    String(
                        localized: "Search Start Menu",
                        bundle: SwitchyardStrings.bundle
                    ),
                    text: $query
                )
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
                        programRow(
                            defaultProgram,
                            trailing: String(
                                localized: "Run",
                                bundle: SwitchyardStrings.bundle
                            )
                        )
                    }

                    if !filteredEntries.isEmpty {
                        menuSectionTitle(
                            query.isEmpty
                                ? String(
                                    localized: "Start Menu",
                                    bundle: SwitchyardStrings.bundle
                                )
                                : String(
                                    localized: "Results",
                                    bundle: SwitchyardStrings.bundle
                                )
                        )
                        ForEach(filteredEntries.prefix(14)) { entry in
                            shortcutRow(entry)
                        }
                    } else if !query.isEmpty, matchingPrograms.isEmpty {
                        Text(
                            String(
                                localized: "No matching apps",
                                bundle: SwitchyardStrings.bundle
                            )
                        )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }

                    if !matchingPrograms.isEmpty {
                        menuSectionTitle(
                            query.isEmpty
                                ? String(
                                    localized: "Installed Apps",
                                    bundle: SwitchyardStrings.bundle
                                )
                                : String(
                                    localized: "Apps",
                                    bundle: SwitchyardStrings.bundle
                                )
                        )
                        ForEach(matchingPrograms.prefix(8)) { program in
                            programRow(program)
                        }
                    }

                    if query.isEmpty, !recentPrograms.isEmpty {
                        menuSectionTitle(
                            String(
                                localized: "Recently Opened",
                                bundle: SwitchyardStrings.bundle
                            )
                        )
                        ForEach(recentPrograms.prefix(3)) { recent in
                            programRow(recent.program)
                        }
                    }

                    if query.isEmpty, !hasVisibleContent {
                        Text(
                            String(
                                localized: "No apps found",
                                bundle: SwitchyardStrings.bundle
                            )
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 96)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 366)
            .padding(.bottom, 8)
        }
        .frame(width: 344)
        .background {
            if reduceTransparency {
                Color(red: 0.075, green: 0.09, blue: 0.12)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
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

    private var hasVisibleContent: Bool {
        defaultProgram != nil
            || !filteredEntries.isEmpty
            || !matchingPrograms.isEmpty
            || !recentPrograms.isEmpty
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
