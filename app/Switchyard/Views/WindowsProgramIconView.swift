import AppCore
import AppKit
import SwiftUI

struct SessionStageApplicationIconView: View {
    let program: InstalledProgram?
    let applicationIconData: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let applicationIcon {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.025)
            } else if let program {
                WindowsProgramIconView(program: program, size: size)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: size, height: size)
                    .background(
                        Color.white.opacity(0.1),
                        in: RoundedRectangle(
                            cornerRadius: size * 0.22,
                            style: .continuous
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var applicationIcon: NSImage? {
        guard let applicationIconData else { return nil }
        return NSImage(data: applicationIconData)
    }
}

struct WindowsProgramIconView: View {
    let program: InstalledProgram
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.23)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .background(
            fallbackTint.gradient,
            in: RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: program.executablePath) {
            icon = nil
            let data = await InstalledProgramIconResolver.iconData(for: program)
            guard !Task.isCancelled else { return }

            if let data, let resolvedIcon = NSImage(data: data) {
                icon = resolvedIcon
            }
        }
        .accessibilityLabel("\(program.presentationName) icon")
    }

    private var fallbackSystemImage: String {
        let name = program.presentationName.lowercased()
        if name.contains("chrome") || name.contains("browser") {
            return "globe"
        }
        if name.contains("steam") || name.contains("game") {
            return "gamecontroller.fill"
        }
        if name.contains("battle") {
            return "bolt.fill"
        }
        if name.contains("rockstar") {
            return "star.fill"
        }
        if name.contains("kakao") || name.contains("chat") {
            return "bubble.left.and.bubble.right.fill"
        }
        return "app.fill"
    }

    private var fallbackTint: Color {
        let name = program.presentationName.lowercased()
        if name.contains("chrome") || name.contains("browser") {
            return Color(red: 0.18, green: 0.48, blue: 0.94)
        }
        if name.contains("steam") {
            return Color(red: 0.08, green: 0.34, blue: 0.52)
        }
        if name.contains("battle") {
            return Color(red: 0.12, green: 0.45, blue: 0.88)
        }
        if name.contains("rockstar") || name.contains("kakao") {
            return Color(red: 0.91, green: 0.61, blue: 0.08)
        }
        return Color(red: 0.35, green: 0.31, blue: 0.54)
    }
}
