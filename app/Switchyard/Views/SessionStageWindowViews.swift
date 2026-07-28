import AppCore
import CoreGraphics
import SwiftUI

struct SessionStageWindowGridMetrics: Equatable {
    let columns: Int
    let rows: Int
    let cardSize: CGSize
    let spacing: CGFloat

    static func make(
        windowCount: Int,
        availableSize: CGSize
    ) -> SessionStageWindowGridMetrics {
        let count = max(1, windowCount)
        let spacing: CGFloat = 16
        let availableWidth = max(220, availableSize.width)
        let availableHeight = max(156, availableSize.height)
        let minimumCardWidth = min(260, availableWidth)
        let minimumCardHeight = min(190, availableHeight)

        let preferredColumns: Int
        switch count {
        case 1:
            preferredColumns = 1
        case 2:
            preferredColumns = 2
        case 3:
            preferredColumns = 3
        case 4:
            preferredColumns = availableWidth >= 1_088 ? 4 : 2
        case 5...6:
            preferredColumns = 3
        case 7...8:
            preferredColumns = 4
        case 9:
            preferredColumns = 3
        case 10...12:
            preferredColumns = 4
        default:
            preferredColumns = min(5, max(3, Int(ceil(sqrt(Double(count))))))
        }

        let columnsAllowedByWidth = max(
            1,
            Int((availableWidth + spacing) / (minimumCardWidth + spacing))
        )
        let columns = min(count, min(preferredColumns, columnsAllowedByWidth))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let widthBeforeCap = (
            availableWidth - CGFloat(columns - 1) * spacing
        ) / CGFloat(columns)
        let heightBeforeCap = (
            availableHeight - CGFloat(rows - 1) * spacing
        ) / CGFloat(rows)
        let maximumCardWidth: CGFloat = count == 1 ? 760 : 460
        let maximumCardHeight: CGFloat = count == 1 ? 500 : 320
        let cardWidth = min(
            availableWidth,
            max(minimumCardWidth, min(maximumCardWidth, widthBeforeCap))
        )
        let cardHeight = max(
            minimumCardHeight,
            min(maximumCardHeight, heightBeforeCap)
        )

        return SessionStageWindowGridMetrics(
            columns: columns,
            rows: rows,
            cardSize: CGSize(width: cardWidth, height: cardHeight),
            spacing: spacing
        )
    }

    var contentHeight: CGFloat {
        CGFloat(rows) * cardSize.height + CGFloat(max(0, rows - 1)) * spacing
    }
}

struct SessionStageWindowPresentation: Equatable {
    let title: String
    let detail: String
    let position: Int
    let total: Int

    static func make(
        window: WineWindowSnapshot,
        programName: String?,
        fallbackName: String,
        position: Int,
        total: Int
    ) -> SessionStageWindowPresentation {
        let matchedProgramName = nonempty(programName)
        let windowTitle = window.meaningfulTitle
        let executableName = safeExecutableName(window.executableDisplayName)
        let title = matchedProgramName
            ?? windowTitle
            ?? executableName
            ?? nonempty(fallbackName)
            ?? "#\(position)"

        var detailParts: [String] = []
        if matchedProgramName != nil,
           let windowTitle,
           normalized(windowTitle) != normalized(title) {
            detailParts.append(windowTitle)
        }
        if total > 1 {
            detailParts.append("#\(position)/\(total)")
        }
        detailParts.append(
            "\(Int(window.frame.width.rounded())) × \(Int(window.frame.height.rounded()))"
        )

        return SessionStageWindowPresentation(
            title: title,
            detail: detailParts.joined(separator: " · "),
            position: position,
            total: total
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? nil : candidate
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func safeExecutableName(_ value: String?) -> String? {
        guard let candidate = nonempty(value) else { return nil }
        let key = normalized(candidate)
        let helperNames: Set<String> = [
            "explorer",
            "steamwebhelper",
            "wine",
            "wine64",
            "wine64preloader",
            "wineserver",
            "xdt",
        ]
        return helperNames.contains(key) ? nil : candidate
    }
}

struct SessionStageWindowGrid<Content: View>: View {
    let itemCount: Int
    let metrics: SessionStageWindowGridMetrics
    private let content: (Int) -> Content

    init(
        itemCount: Int,
        metrics: SessionStageWindowGridMetrics,
        @ViewBuilder content: @escaping (Int) -> Content
    ) {
        self.itemCount = itemCount
        self.metrics = metrics
        self.content = content
    }

    var body: some View {
        VStack(spacing: metrics.spacing) {
            ForEach(0..<metrics.rows, id: \.self) { row in
                let start = row * metrics.columns
                let end = min(itemCount, start + metrics.columns)
                HStack(spacing: metrics.spacing) {
                    ForEach(start..<end, id: \.self) { index in
                        content(index)
                            .frame(
                                width: metrics.cardSize.width,
                                height: metrics.cardSize.height
                            )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct SessionStageWindowCard: View {
    let window: WineWindowSnapshot?
    let program: InstalledProgram?
    let presentation: SessionStageWindowPresentation
    let isRunning: Bool
    let isSelected: Bool
    var isClosing = false
    var onClose: (() -> Void)?
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isCloseHovering = false
    @FocusState private var activationIsFocused: Bool
    @FocusState private var closeIsFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                windowSurface
                    .contentShape(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .focused($activationIsFocused)
            .disabled(isClosing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(activationAccessibilityHint)

            closeControl
        }
        .onHover { isHovering = $0 }
    }

    private var windowSurface: some View {
        VStack(spacing: 0) {
            titleBar

            ZStack {
                Color.black.opacity(0.86)

                if let image = window?.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    previewFallback
                }

                if isClosing {
                    Color.black.opacity(0.38)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(red: 0.12, green: 0.55, blue: 1)
                        : Color.white.opacity(isHovering ? 0.24 : 0.14),
                    lineWidth: isSelected ? 2.5 : 1
                )
        }
        .background(
            Color.white.opacity(isHovering ? 0.035 : 0),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(
            color: isSelected
                ? Color(red: 0.08, green: 0.46, blue: 1).opacity(0.38)
                : .black.opacity(0.34),
            radius: isSelected ? 15 : 9,
            y: 8
        )
        .opacity(isClosing ? 0.62 : 1)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isHovering
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: isSelected
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isClosing
        )
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            programIcon(size: 25)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.leading, 12)
        .padding(.trailing, onClose == nil ? 12 : 48)
        .frame(height: 44)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.14, blue: 0.17),
                    Color(red: 0.09, green: 0.1, blue: 0.13),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var closeControl: some View {
        if let onClose {
            Button(action: onClose) {
                Group {
                    if isClosing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .foregroundStyle(
                    isCloseHovering ? Color.white : Color.white.opacity(0.68)
                )
                .frame(width: 28, height: 28)
                .background(
                    isCloseHovering
                        ? Color.red.opacity(0.86)
                        : Color.black.opacity(0.22),
                    in: Circle()
                )
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .focused($closeIsFocused)
            .disabled(isClosing)
            .opacity(
                isHovering || activationIsFocused || closeIsFocused || isClosing
                    ? 1
                    : 0
            )
            .onHover { isCloseHovering = $0 }
            .help(closeAccessibilityLabel)
            .accessibilityLabel(closeAccessibilityLabel)
            .accessibilityHint(
                String(
                    localized: "Closes only this Windows window",
                    bundle: SwitchyardStrings.bundle
                )
            )
            .padding(.top, 6)
            .padding(.trailing, 8)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: isHovering
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: closeIsFocused
            )
        }
    }

    private var previewFallback: some View {
        VStack(spacing: 12) {
            programIcon(size: 54)
            Text(
                isRunning
                    ? String(
                        localized: "Live preview unavailable",
                        bundle: SwitchyardStrings.bundle
                    )
                    : String(
                        localized: "Ready to launch",
                        bundle: SwitchyardStrings.bundle
                    )
            )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.46))
        }
    }

    @ViewBuilder
    private func programIcon(size: CGFloat) -> some View {
        if let program {
            WindowsProgramIconView(program: program, size: size)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.56, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: size, height: size)
                .background(
                    Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                )
        }
    }

    private var accessibilityValue: Text {
        var value = presentation.detail
        if isSelected {
            value += ", " + String(
                localized: "Selected",
                bundle: SwitchyardStrings.bundle
            )
        }
        if isClosing {
            value += ", " + String(
                localized: "Closing",
                bundle: SwitchyardStrings.bundle
            )
        }
        return Text(value)
    }

    private var activationAccessibilityHint: String {
        if window != nil {
            return String(
                localized: "Bring this Windows window forward",
                bundle: SwitchyardStrings.bundle
            )
        }
        return isRunning
            ? String(
                localized: "Open Activity",
                bundle: SwitchyardStrings.bundle
            )
            : String(
                localized: "Launch this Windows app",
                bundle: SwitchyardStrings.bundle
            )
    }

    private var closeAccessibilityLabel: String {
        if isClosing {
            return String(
                localized: "Closing window",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Close window",
            bundle: SwitchyardStrings.bundle
        )
    }
}

struct SessionStagePreviewPermissionBanner: View {
    let message: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.slash")
                Text(message)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.black.opacity(0.42), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
    }
}
