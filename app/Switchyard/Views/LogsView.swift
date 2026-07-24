import AppCore
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var levelFilter = "all"
    @State private var containerFilter: UUID?
    @State private var isConfirmingClear = false

    var body: some View {
        let displayedLogs = filteredLogs

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

                Picker("Containers", selection: $containerFilter) {
                    Text("All").tag(nil as UUID?)
                    ForEach(store.containers) { container in
                        Text(container.name).tag(container.id as UUID?)
                    }
                }
                .frame(width: 180)

                Text("\(displayedLogs.count) entries")
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
                        text: copyText(for: displayedLogs)
                    )
                }
                .disabled(displayedLogs.isEmpty)

                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                }
                .disabled(store.logLines.isEmpty)
            }
            .padding()

            Divider()

            if displayedLogs.isEmpty {
                ContentUnavailableView("No Matching Logs", systemImage: "doc.text.magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(displayedLogs) { line in
                            LogLineView(line: line)
                        }
                    }
                    .padding()
                }
                .font(.system(.body, design: .monospaced))
            }
        }
        .navigationTitle("Logs")
        .onChange(of: store.containers.map(\.id)) { _, containerIDs in
            if let containerFilter, !containerIDs.contains(containerFilter) {
                self.containerFilter = nil
            }
        }
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
        LogFilterPolicy.filtering(
            store.logLines,
            containerID: containerFilter,
            level: levelFilter == "all" ? nil : levelFilter,
            searchText: searchText
        )
    }

    private func copyText(for logs: [LogLine]) -> String {
        logs.map { line in
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
