import SwiftUI

/// A compact host-side view of the Wine session that complements the window grid.
///
/// Resource totals are sampled from the macOS processes associated with the
/// container. They intentionally do not claim to be guest-only Windows metrics.
struct SessionStageInspector: View {
    let wineServerState: WineServerState
    let windows: [WineWindowSnapshot]
    let processes: [WindowsProcessSnapshot]
    let resources: WineSessionResourceSnapshot?
    let notice: String?
    let isStoppingSession: Bool
    let onRefresh: () -> Void
    let onOpenActivity: () -> Void
    let onEndSession: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var processScope: ProcessScope = .applications

    init(
        wineServerState: WineServerState,
        windows: [WineWindowSnapshot],
        processes: [WindowsProcessSnapshot],
        resources: WineSessionResourceSnapshot?,
        notice: String? = nil,
        isStoppingSession: Bool,
        onRefresh: @escaping () -> Void,
        onOpenActivity: @escaping () -> Void,
        onEndSession: @escaping () -> Void
    ) {
        self.wineServerState = wineServerState
        self.windows = windows
        self.processes = processes
        self.resources = resources
        self.notice = notice
        self.isStoppingSession = isStoppingSession
        self.onRefresh = onRefresh
        self.onOpenActivity = onOpenActivity
        self.onEndSession = onEndSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            metrics

            if let notice = normalizedNotice {
                noticeView(notice)
            }

            processBrowser

            Divider()
                .overlay(Color.white.opacity(0.09))

            actions
        }
        .padding(16)
        .frame(
            minWidth: 320,
            idealWidth: 328,
            maxWidth: 336,
            maxHeight: .infinity,
            alignment: .top
        )
        .background {
            panelBackground
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.17),
                            Color(red: 0.30, green: 0.50, blue: 1).opacity(0.16),
                            Color(red: 0.55, green: 0.35, blue: 1).opacity(0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.black.opacity(0.38), radius: 26, y: 14)
        .shadow(
            color: Color(red: 0.19, green: 0.42, blue: 1).opacity(0.10),
            radius: 22
        )
        .accessibilityIdentifier("sessionStage.inspector")
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(statusPresentation.color.opacity(0.14))
                Circle()
                    .strokeBorder(statusPresentation.color.opacity(0.35))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusPresentation.color)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    String(
                        localized: "Wine Session",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))

                HStack(spacing: 5) {
                    Image(systemName: statusPresentation.systemImage)
                        .font(.system(size: 9, weight: .bold))
                    Text(statusPresentation.label)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusPresentation.color)
            }

            Spacer(minLength: 8)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.055), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.10))
                    }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.76))
            .help(
                String(
                    localized: "Refresh",
                    bundle: SwitchyardStrings.bundle
                )
            )
            .accessibilityLabel(
                String(
                    localized: "Refresh",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var metrics: some View {
        VStack(spacing: 8) {
            SessionInspectorMemorySummary(
                title: String(
                    localized: "Host memory estimate",
                    bundle: SwitchyardStrings.bundle
                ),
                value: formattedPrimaryMemory,
                measurementLabel: memoryMeasurementLabel,
                secondaryTitle: usesPhysicalFootprint
                    ? String(
                        localized: "Resident memory",
                        bundle: SwitchyardStrings.bundle
                    )
                    : nil,
                secondaryValue: usesPhysicalFootprint
                    ? formattedResidentMemory
                    : nil,
                explanation: String(
                    localized: "GPU memory is not reported separately here. Activity Monitor may show a different total.",
                    bundle: SwitchyardStrings.bundle
                ),
                helpText: memoryHelpText
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                SessionInspectorMetric(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: String(
                        localized: "Threads",
                        bundle: SwitchyardStrings.bundle
                    ),
                    value: nonemptyResources.map {
                        String($0.threadCount)
                    } ?? "—",
                    accent: Color(red: 0.58, green: 0.44, blue: 1)
                )

                SessionInspectorMetric(
                    systemImage: "cpu",
                    title: String(
                        localized: "Host processes",
                        bundle: SwitchyardStrings.bundle
                    ),
                    value: nonemptyResources.map {
                        String($0.sampledProcessCount)
                    } ?? "—",
                    accent: Color(red: 0.33, green: 0.76, blue: 0.84)
                )

                SessionInspectorMetric(
                    systemImage: "macwindow.on.rectangle",
                    title: String(
                        localized: "App windows",
                        bundle: SwitchyardStrings.bundle
                    ),
                    value: String(windows.count),
                    accent: Color(red: 0.32, green: 0.64, blue: 1)
                )

                SessionInspectorMetric(
                    systemImage: "clock",
                    title: String(
                        localized: "Last refresh",
                        bundle: SwitchyardStrings.bundle
                    ),
                    value: formattedRefreshTime,
                    accent: Color.white.opacity(0.66)
                )
            }
        }
    }

    private func noticeView(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.43, green: 0.68, blue: 1))
                .padding(.top, 1)

            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(red: 0.15, green: 0.38, blue: 0.78).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.15))
        }
        .accessibilityElement(children: .combine)
    }

    private var processBrowser: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(
                    String(
                        localized: "Processes",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))

                Spacer()

                Text(String(processes.count))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }

            HStack(spacing: 6) {
                ForEach(ProcessScope.allCases) { scope in
                    processFilter(scope)
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if processScope != .system {
                        processSection(
                            title: String(
                                localized: "Applications",
                                bundle: SwitchyardStrings.bundle
                            ),
                            items: applicationProcesses
                        )
                    }

                    if processScope != .applications {
                        processSection(
                            title: String(
                                localized: "System",
                                bundle: SwitchyardStrings.bundle
                            ),
                            items: systemProcesses
                        )
                    }

                    if filteredProcesses.isEmpty {
                        emptyProcesses
                    }
                }
                .padding(.trailing, 3)
            }
            .frame(minHeight: 116, maxHeight: .infinity)
            .accessibilityLabel(
                String(
                    localized: "Processes",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func processFilter(_ scope: ProcessScope) -> some View {
        let isSelected = scope == processScope
        return Button {
            processScope = scope
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }

                Text(scope.label)
                    .lineLimit(1)

                Text(String(processCount(for: scope)))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        isSelected
                            ? Color.white.opacity(0.86)
                            : Color.white.opacity(0.42)
                    )
            }
            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(
                isSelected
                    ? Color.white.opacity(0.94)
                    : Color.white.opacity(0.60)
            )
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 29)
            .background(
                isSelected
                    ? Color(red: 0.18, green: 0.45, blue: 0.95).opacity(0.28)
                    : Color.white.opacity(0.035),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected
                            ? Color(red: 0.39, green: 0.66, blue: 1).opacity(0.48)
                            : Color.white.opacity(0.08),
                        lineWidth: isSelected ? 1.25 : 1
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scope.label), \(processCount(for: scope))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func processSection(
        title: String,
        items: [WindowsProcessSnapshot]
    ) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .textCase(.uppercase)
                .padding(.top, 2)

            ForEach(items) { process in
                SessionInspectorProcessChip(process: process)
            }
        }
    }

    private var emptyProcesses: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.white.opacity(0.28))
            Text(
                String(
                    localized: "No matching processes",
                    bundle: SwitchyardStrings.bundle
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onOpenActivity) {
                Label(
                    String(
                        localized: "Activity",
                        bundle: SwitchyardStrings.bundle
                    ),
                    systemImage: "waveform.path.ecg"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SessionInspectorActionButtonStyle())
            .accessibilityIdentifier("sessionStage.inspector.activity")

            Button(role: .destructive, action: onEndSession) {
                HStack(spacing: 7) {
                    if isStoppingSession {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "power")
                    }

                    Text(
                        String(
                            localized: "End Session",
                            bundle: SwitchyardStrings.bundle
                        )
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SessionInspectorActionButtonStyle(isDestructive: true))
            .disabled(!wineServerState.hasRunningProcesses || isStoppingSession)
            .help(
                String(
                    localized: "End Windows Session",
                    bundle: SwitchyardStrings.bundle
                )
            )
            .accessibilityIdentifier("sessionStage.inspector.endSession")
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            shape.fill(Color.black.opacity(0.94))
        } else {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.24))
        }
    }

    private var statusPresentation: StatusPresentation {
        switch wineServerState {
        case .active:
            StatusPresentation(
                label: String(
                    localized: "Running",
                    bundle: SwitchyardStrings.bundle
                ),
                systemImage: "checkmark.circle.fill",
                color: Color(red: 0.27, green: 0.83, blue: 0.53)
            )
        case .orphaned:
            StatusPresentation(
                label: String(
                    localized: "Cleanup needed",
                    bundle: SwitchyardStrings.bundle
                ),
                systemImage: "exclamationmark.triangle.fill",
                color: Color(red: 1, green: 0.65, blue: 0.24)
            )
        case .checking:
            StatusPresentation(
                label: String(
                    localized: "Checking",
                    bundle: SwitchyardStrings.bundle
                ),
                systemImage: "arrow.triangle.2.circlepath",
                color: Color(red: 0.39, green: 0.67, blue: 1)
            )
        case .inactive:
            StatusPresentation(
                label: String(
                    localized: "Idle",
                    bundle: SwitchyardStrings.bundle
                ),
                systemImage: "pause.circle.fill",
                color: Color.white.opacity(0.48)
            )
        case .unavailable:
            StatusPresentation(
                label: String(
                    localized: "Unavailable",
                    bundle: SwitchyardStrings.bundle
                ),
                systemImage: "slash.circle.fill",
                color: Color(red: 1, green: 0.48, blue: 0.48)
            )
        }
    }

    private var normalizedNotice: String? {
        guard let notice else { return nil }
        let value = notice.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var applicationProcesses: [WindowsProcessSnapshot] {
        sortedProcesses(processes.filter { !$0.isSystemProcess })
    }

    private var systemProcesses: [WindowsProcessSnapshot] {
        sortedProcesses(processes.filter(\.isSystemProcess))
    }

    private var filteredProcesses: [WindowsProcessSnapshot] {
        switch processScope {
        case .applications:
            applicationProcesses
        case .system:
            systemProcesses
        case .all:
            applicationProcesses + systemProcesses
        }
    }

    private func processCount(for scope: ProcessScope) -> Int {
        switch scope {
        case .applications:
            applicationProcesses.count
        case .system:
            systemProcesses.count
        case .all:
            processes.count
        }
    }

    private func sortedProcesses(
        _ processes: [WindowsProcessSnapshot]
    ) -> [WindowsProcessSnapshot] {
        processes.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var formattedPrimaryMemory: String {
        guard let resources = nonemptyResources else { return "—" }
        return formattedBytes(
            resources.physicalFootprintBytes ??
                resources.residentMemoryBytes
        )
    }

    private var formattedResidentMemory: String? {
        guard let resources = nonemptyResources else { return nil }
        return formattedBytes(resources.residentMemoryBytes)
    }

    private var usesPhysicalFootprint: Bool {
        nonemptyResources?.hasCompletePhysicalFootprint == true
    }

    private var memoryMeasurementLabel: String {
        guard nonemptyResources != nil else {
            return String(
                localized: "Unavailable",
                bundle: SwitchyardStrings.bundle
            )
        }
        if usesPhysicalFootprint {
            return String(
                localized: "Physical footprint",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Resident memory",
            bundle: SwitchyardStrings.bundle
        )
    }

    private var memoryHelpText: String {
        guard nonemptyResources != nil else {
            return String(
                localized: "Unavailable",
                bundle: SwitchyardStrings.bundle
            )
        }
        if usesPhysicalFootprint {
            return String(
                localized: "This estimate sums the macOS physical footprint of the host processes associated with this Wine session.",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Physical footprint was unavailable for part of this session, so this estimate uses resident memory instead.",
            bundle: SwitchyardStrings.bundle
        )
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        let boundedBytes = min(bytes, UInt64(Int64.max))
        return ByteCountFormatter.string(
            fromByteCount: Int64(boundedBytes),
            countStyle: .memory
        )
    }

    private var formattedRefreshTime: String {
        resources?.sampledAt.formatted(date: .omitted, time: .shortened) ?? "—"
    }

    private var nonemptyResources: WineSessionResourceSnapshot? {
        guard let resources, !resources.isEmpty else { return nil }
        return resources
    }
}

private struct SessionInspectorMemorySummary: View {
    let title: String
    let value: String
    let measurementLabel: String
    let secondaryTitle: String?
    let secondaryValue: String?
    let explanation: String
    let helpText: String

    private let accent = Color(red: 0.28, green: 0.62, blue: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.20),
                                Color(red: 0.46, green: 0.35, blue: 1)
                                    .opacity(0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))

                Spacer(minLength: 6)

                Text(measurementLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background(accent.opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(accent.opacity(0.19))
                    }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 6)

                if let secondaryTitle, let secondaryValue {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(secondaryTitle)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(secondaryValue)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.80))
                    .padding(.top, 1)

                Text(explanation)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.28, blue: 0.62).opacity(0.17),
                    Color.white.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.24),
                            Color.white.opacity(0.07),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(measurementLabel). \(explanation)")
    }
}

private extension SessionStageInspector {
    enum ProcessScope: CaseIterable, Identifiable {
        case applications
        case system
        case all

        var id: Self { self }

        var label: String {
            switch self {
            case .applications:
                String(
                    localized: "Apps",
                    bundle: SwitchyardStrings.bundle
                )
            case .system:
                String(
                    localized: "System",
                    bundle: SwitchyardStrings.bundle
                )
            case .all:
                String(
                    localized: "All",
                    bundle: SwitchyardStrings.bundle
                )
            }
        }
    }

    struct StatusPresentation {
        let label: String
        let systemImage: String
        let color: Color
    }
}

private struct SessionInspectorMetric: View {
    let systemImage: String
    let title: String
    let value: String
    let accent: Color
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 9 : 8) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: isCompact ? 22 : 24, height: isCompact ? 22 : 24)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

            if isCompact {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.53))

                Spacer(minLength: 4)

                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(1)

                    Text(value)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: isCompact ? 38 : 54)
        .background(
            Color.white.opacity(0.038),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct SessionInspectorProcessChip: View {
    let process: WindowsProcessSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: process.isSystemProcess
                    ? "gearshape.2.fill"
                    : "macwindow"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
                process.isSystemProcess
                    ? Color.white.opacity(0.42)
                    : Color(red: 0.39, green: 0.67, blue: 1)
            )
            .frame(width: 19)

            Text(process.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(process.kind)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(Color.white.opacity(0.035), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.07))
        }
        .contentShape(Capsule())
        .help(process.executablePath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(process.name), \(process.kind)")
        .accessibilityValue(process.executablePath)
    }
}

private struct SessionInspectorActionButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                isDestructive
                    ? Color(red: 1, green: 0.76, blue: 0.76)
                    : Color.white.opacity(0.86)
            )
            .frame(minHeight: 39)
            .background(
                actionBackground(isPressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isDestructive
                            ? Color.red.opacity(0.24)
                            : Color.white.opacity(0.10)
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }

    private func actionBackground(isPressed: Bool) -> Color {
        if isDestructive {
            return Color.red.opacity(isPressed ? 0.26 : 0.13)
        }
        return Color.white.opacity(isPressed ? 0.10 : 0.055)
    }
}
