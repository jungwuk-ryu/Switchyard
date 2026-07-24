import AppCore
import SwiftUI

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
