import AppCore
import SwiftUI

struct StatusBadge: View {
    let status: HealthStatus
    let label: String

    var body: some View {
        Label(label, systemImage: status.symbolName)
            .font(.caption)
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("\(label), \(status.label)")
    }
}
