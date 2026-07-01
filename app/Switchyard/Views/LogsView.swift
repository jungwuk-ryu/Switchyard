import AppCore
import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var levelFilter = "all"
    @State private var isPaused = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sessions")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top)

                List(store.runSessions, selection: $store.selectedLogSessionID) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.launcherName)
                            .font(.headline)
                        Text("\(switchyardDateFormatter.string(from: session.startedAt)) · \(session.outcome.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                }
            }
            .frame(minWidth: 220, idealWidth: 260)

            VStack(spacing: 0) {
                HStack {
                    TextField("Search logs", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)

                    Picker("Level", selection: $levelFilter) {
                        Text("All").tag("all")
                        Text("Info").tag("info")
                        Text("Warning").tag("warning")
                        Text("Error").tag("error")
                    }
                    .frame(width: 140)

                    Toggle("Pause", isOn: $isPaused)
                        .toggleStyle(.checkbox)

                    Spacer()

                    Button("Export") {
                        _ = store.diagnosticBundle()
                    }

                    Button("Copy Selection") {
                        ClipboardPrivacy.confirmAndCopy(
                            title: "Copy log text?",
                            message: "Switchyard will redact common secrets and your home folder path before copying.",
                            text: filteredLogs.map(\.message).joined(separator: "\n")
                        )
                    }
                }
                .padding()

                Divider()

                if filteredLogs.isEmpty {
                    ContentUnavailableView(
                        "No Logs Yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Run diagnostics or launch a supported game launcher to collect logs.")
                    )
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
            .frame(minWidth: 620)
        }
        .navigationTitle("Logs")
    }

    private var filteredLogs: [LogLine] {
        store.logLines.filter { line in
            let matchesLevel = levelFilter == "all" || line.level == levelFilter
            let matchesSearch = searchText.isEmpty || line.message.localizedCaseInsensitiveContains(searchText) || line.source.localizedCaseInsensitiveContains(searchText)
            return matchesLevel && matchesSearch
        }
    }
}

private struct LogLineView: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(switchyardDateFormatter.string(from: line.timestamp))
                .foregroundStyle(.secondary)
            Text(line.level.uppercased())
                .foregroundStyle(line.level == "error" ? .red : .secondary)
                .frame(width: 70, alignment: .leading)
            Text(line.source)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(line.message)
                .textSelection(.enabled)
        }
    }
}
