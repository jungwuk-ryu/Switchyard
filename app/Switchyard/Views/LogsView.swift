import AppCore
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var levelFilter = "all"
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search logs", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                Picker("Level", selection: $levelFilter) {
                    Text("All").tag("all")
                    Text("Debug").tag("debug")
                    Text("Info").tag("info")
                    Text("Warning").tag("warning")
                    Text("Error").tag("error")
                }
                .frame(width: 140)

                Text("\(filteredLogs.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Copy Filtered Logs") {
                    ClipboardPrivacy.confirmAndCopy(
                        title: String(
                            localized: "Copy filtered logs?",
                            bundle: SwitchyardStrings.bundle
                        ),
                        message: String(
                            localized: "Switchyard will redact common secrets and your home folder path before copying.",
                            bundle: SwitchyardStrings.bundle
                        ),
                        text: copyText
                    )
                }
                .disabled(filteredLogs.isEmpty)

                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                .disabled(store.logLines.isEmpty)
            }
            .padding()

            Divider()

            if filteredLogs.isEmpty {
                ContentUnavailableView("No Matching Logs", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredLogs) { line in
                            LogLineView(line: line)
                        }
                    }
                    .padding()
                }
                .font(.system(.body, design: .monospaced))
            }
        }
        .navigationTitle("Logs")
        .confirmationDialog(
            "Clear all logs?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) {
                store.clearLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The log entries shown in Switchyard will be removed. Debug run files keep their configured retention period.")
        }
    }

    private var filteredLogs: [LogLine] {
        store.logLines.filter { line in
            let matchesLevel = levelFilter == "all" || line.level == levelFilter
            let matchesSearch = searchText.isEmpty || line.message.localizedCaseInsensitiveContains(searchText) || line.source.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch
        }
    }

    private var copyText: String {
        filteredLogs.map { line in
            "\(switchyardDateFormatter.string(from: line.timestamp)) [\(line.level.uppercased())] [\(line.source)] \(line.message)"
        }
        .joined(separator: "\n")
    }
}

private struct LogLineView: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(switchyardDateFormatter.string(from: line.timestamp))
                .foregroundStyle(.secondary)
            Text(line.level.uppercased())
                .foregroundStyle(levelColor)
                .frame(width: 70, alignment: .leading)
            Text(line.source)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(line.message)
                .textSelection(.enabled)
        }
    }

    private var levelColor: Color {
        switch line.level {
        case "error": .red
        case "warning": .orange
        case "debug": .gray
        default: .secondary
        }
    }
}
