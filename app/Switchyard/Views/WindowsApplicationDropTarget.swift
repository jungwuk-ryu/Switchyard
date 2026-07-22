import AppCore
import SwiftUI

private struct WindowsApplicationDropTargetModifier: ViewModifier {
    let containerName: String
    let isEnabled: Bool
    let action: (URL) -> Bool

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard isEnabled,
                      let applicationURL = urls.first(where: WindowsApplicationFileKind.supports)
                else {
                    return false
                }
                return action(applicationURL)
            } isTargeted: { targeted in
                isTargeted = targeted && isEnabled
            }
            .overlay {
                if isTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 3)

                        Label(
                            "Run .exe or .msi in \(containerName)",
                            systemImage: "shippingbox.and.arrow.backward.fill"
                        )
                        .font(.headline)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

extension View {
    func windowsApplicationDropTarget(
        containerName: String,
        isEnabled: Bool = true,
        action: @escaping (URL) -> Bool
    ) -> some View {
        modifier(
            WindowsApplicationDropTargetModifier(
                containerName: containerName,
                isEnabled: isEnabled,
                action: action
            )
        )
    }
}
