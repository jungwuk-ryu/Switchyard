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
        let spacing: CGFloat = 18
        let availableWidth = max(220, availableSize.width)
        let availableHeight = max(156, availableSize.height)

        let preferredColumns: Int
        switch count {
        case 1:
            preferredColumns = 1
        case 2:
            preferredColumns = availableWidth < 720 ? 1 : 2
        case 3...4:
            preferredColumns = availableWidth < 720 ? 1 : 2
        case 5...6:
            preferredColumns = availableWidth < 980 ? 2 : 3
        case 7...9:
            preferredColumns = availableWidth < 900 ? 2 : 3
        case 10...12:
            preferredColumns = availableWidth < 1_150 ? 3 : 4
        default:
            preferredColumns = min(5, max(3, Int(ceil(sqrt(Double(count))))))
        }

        let columnsAllowedByWidth = max(
            1,
            Int((availableWidth + spacing) / (220 + spacing))
        )
        let columns = min(count, min(preferredColumns, columnsAllowedByWidth))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let widthBeforeCap = (
            availableWidth - CGFloat(columns - 1) * spacing
        ) / CGFloat(columns)
        let heightBeforeCap = (
            availableHeight - CGFloat(rows - 1) * spacing
        ) / CGFloat(rows)
        let maximumCardWidth: CGFloat = count == 1 ? 820 : 620
        let maximumCardHeight: CGFloat = count == 1 ? 560 : 390
        let cardWidth = min(availableWidth, max(220, min(maximumCardWidth, widthBeforeCap)))
        let cardHeight = max(156, min(maximumCardHeight, heightBeforeCap))

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
        let applicationName = nonempty(programName)
            ?? window.executableDisplayName
        let windowTitle = window.meaningfulTitle
        let title = applicationName
            ?? windowTitle
            ?? nonempty(fallbackName)
            ?? "#\(position)"

        var detailParts: [String] = []
        if let windowTitle,
           normalized(windowTitle) != normalized(title) {
            detailParts.append(windowTitle)
        }
        detailParts.append("#\(position)/\(total)")
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
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            windowSurface
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            window != nil
                ? "Bring this Windows window forward"
                : (isRunning ? "Open Activity" : "Launch this Windows app")
        )
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
                        .transition(.opacity)
                } else {
                    previewFallback
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(red: 0.12, green: 0.55, blue: 1)
                        : Color.white.opacity(isHovering ? 0.24 : 0.14),
                    lineWidth: isSelected ? 2.5 : 1
                )
        }
        .background(
            Color.white.opacity(isHovering ? 0.035 : 0),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .shadow(
            color: isSelected
                ? Color(red: 0.08, green: 0.46, blue: 1).opacity(0.38)
                : .black.opacity(0.34),
            radius: isSelected ? 15 : 9,
            y: 8
        )
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .animation(.snappy(duration: 0.22), value: isSelected)
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

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(Color.blue, in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
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

    private var previewFallback: some View {
        VStack(spacing: 12) {
            programIcon(size: 54)
            Text(isRunning ? "Live preview unavailable" : "Ready to launch")
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
        return Text(value)
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
