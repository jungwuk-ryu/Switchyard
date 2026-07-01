import AppKit
import SwiftUI

struct PathPickerRow: View {
    let title: String
    let message: String
    @Binding var path: String
    var onChange: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .frame(width: 150, alignment: .leading)

            Text(path.isEmpty ? "Not selected" : path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)

            Spacer(minLength: 12)

            Button("Choose...") {
                choosePath()
            }
        }
        .help(message)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            onChange()
        }
    }
}
