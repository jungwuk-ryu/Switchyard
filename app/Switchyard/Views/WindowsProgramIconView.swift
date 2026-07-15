import AppCore
import AppKit
import SwiftUI

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
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.23)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(
            .quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .task(id: program.executablePath) {
            icon = nil
            let data = await InstalledProgramIconResolver.iconData(for: program)
            guard !Task.isCancelled else { return }

            if let data, let resolvedIcon = NSImage(data: data) {
                icon = resolvedIcon
            } else {
                icon = NSWorkspace.shared.icon(forFile: program.executablePath)
            }
        }
        .accessibilityLabel("\(program.presentationName) icon")
    }
}
