import AppCore
import SwiftUI

struct DiagnosticCheckRow: View {
    let check: DiagnosticCheck
    var rerun: () -> Void

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

            if let recoveryAction = check.recoveryAction {
                Button(recoveryAction) {
                    rerun()
                }
                .help(recoveryAction)
            } else {
                Button("Re-run") {
                    rerun()
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
