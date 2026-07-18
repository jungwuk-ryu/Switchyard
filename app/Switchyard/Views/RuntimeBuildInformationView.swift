import AppCore
import Foundation
import SwiftUI

struct RuntimeBuildSummaryView: View {
    let runtime: RuntimeBuild

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Version") {
                Text(versionLabel)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }

            LabeledContent("Version Date", value: versionDateLabel)

            if runtime.buildNumber != nil {
                Text("Calendar build numbers use the pinned source revision time in UTC, so later numbers indicate newer runtimes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This runtime has no trusted source revision date for a calendar build number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var versionLabel: String {
        runtime.buildNumber.map { "Build \($0)" } ?? "Build Not Available"
    }

    private var versionDateLabel: String {
        guard let versionDate = runtime.versionDate else { return "Not available" }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: versionDate)) UTC"
    }
}

struct RuntimeBuildTechnicalDetailsView: View {
    let runtime: RuntimeBuild

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            technicalValue("Runtime ID", runtime.id)
            technicalValue("Patch Set", runtime.patchsetID)
            technicalValue(
                "Source Revision",
                runtime.sourceRevision.isEmpty ? "Unpinned" : runtime.sourceRevision
            )
            technicalValue("Executable", runtime.winePath)
        }
    }

    private func technicalValue(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }
}
