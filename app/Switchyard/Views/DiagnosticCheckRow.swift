import AppCore
import SwiftUI

struct DiagnosticCheckRow: View {
    let check: DiagnosticCheck
    var recovery: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: check.status.symbolName)
                .foregroundStyle(check.status.tint)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.headline)
                Text(check.result)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            StatusBadge(status: check.status, label: statusLabel)

            if let recoveryAction = check.recoveryAction {
                Button(recoveryAction) {
                    recovery()
                }
                .help(recoveryAction)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var statusLabel: String {
        guard check.status == .ok else { return check.status.label }

        switch check.id {
        case "apple-silicon", "macos-version": return "Supported"
        case "rosetta", "open-font-pack": return "Installed"
        case "gptk": return "Verified"
        case "wine-runtime": return "Selected"
        case "runtime-source": return "Current"
        default: return check.status.label
        }
    }
}
