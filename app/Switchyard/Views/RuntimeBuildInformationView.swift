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
        runtime.buildNumber.map {
            String(localized: "Build \($0)", bundle: SwitchyardStrings.bundle)
        } ?? String(localized: "Build Not Available", bundle: SwitchyardStrings.bundle)
    }

    private var versionDateLabel: String {
        guard let versionDate = runtime.versionDate else {
            return String(localized: "Not available", bundle: SwitchyardStrings.bundle)
        }

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
            technicalValue(
                String(localized: "Runtime ID", bundle: SwitchyardStrings.bundle),
                runtime.id
            )
            technicalValue(
                String(localized: "Patch Set", bundle: SwitchyardStrings.bundle),
                runtime.patchsetID
            )
            technicalValue(
                String(localized: "Source Revision", bundle: SwitchyardStrings.bundle),
                runtime.sourceRevision.isEmpty
                    ? String(localized: "Unpinned", bundle: SwitchyardStrings.bundle)
                    : runtime.sourceRevision
            )
            technicalValue(
                String(localized: "Executable", bundle: SwitchyardStrings.bundle),
                runtime.winePath
            )
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
