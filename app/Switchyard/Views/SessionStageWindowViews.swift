import AppCore
import CoreGraphics
import SwiftUI

struct SessionStageWindowCard: View {
    let window: WineWindowSnapshot?
    let program: InstalledProgram?
    let fallbackTitle: String
    let isRunning: Bool
    let isSelected: Bool
    var compact = false
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 7 : 10) {
                windowSurface

                if !compact {
                    statusBadge
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && !reduceMotion ? 1.012 : 1)
        .animation(.snappy(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
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
        .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(red: 0.12, green: 0.55, blue: 1)
                        : Color.white.opacity(isHovering ? 0.24 : 0.14),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .shadow(
            color: isSelected
                ? Color(red: 0.08, green: 0.46, blue: 1).opacity(0.44)
                : .black.opacity(0.42),
            radius: isSelected ? 13 : 8,
            y: 7
        )
    }

    private var titleBar: some View {
        HStack(spacing: compact ? 6 : 8) {
            programIcon(size: compact ? 18 : 22)

            Text(title)
                .font(.system(size: compact ? 10 : 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 8)

            if !compact {
                Image(systemName: "minus")
                Image(systemName: "square")
                Image(systemName: "xmark")
            } else {
                Image(systemName: "xmark")
            }
        }
        .font(.system(size: compact ? 9 : 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.64))
        .padding(.horizontal, compact ? 9 : 12)
        .frame(height: compact ? 27 : 36)
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
        VStack(spacing: compact ? 8 : 14) {
            programIcon(size: compact ? 38 : 68)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: compact ? 11 : 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                if !compact {
                    Text(
                        isRunning
                            ? "Live preview unavailable"
                            : "Ready to launch"
                    )
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.46))
                }
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 9) {
            programIcon(size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(isRunning ? "Running" : "Ready")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 6)

            Circle()
                .fill(isRunning ? Color.green : Color.blue)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .frame(width: min(compact ? 180 : 246, compact ? 180 : 246), height: 46)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
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

    private var title: String {
        let windowTitle = window?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let windowTitle, !windowTitle.isEmpty {
            return windowTitle
        }
        return fallbackTitle
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
