import SwiftUI

struct GPTKComponentLicenseConsentView: View {
    let request: GPTKComponentConsentRequest
    let cancel: () -> Void
    let accept: () -> Void

    @State private var acknowledgesAppleLicense = false
    @State private var acknowledgesEvaluationUse = false
    @State private var acknowledgesAuthorizedMaterial = false

    private var canAccept: Bool {
        acknowledgesAppleLicense
            && acknowledgesEvaluationUse
            && acknowledgesAuthorizedMaterial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Game Porting Toolkit License")
                    .font(.title2.weight(.semibold))
                Text(
                    "GPTK \(request.version) · \(request.licenseIdentifier)"
                )
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            }

            Text("Switchyard does not accept this agreement for you. Read the accompanying Apple license before downloading.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(verbatim: request.licenseText)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(minHeight: 260)
            .background(
                .background.secondary,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.separator, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "I understand this is Apple-licensed software, not MIT-licensed Switchyard software, and it comes without Switchyard or Apple warranty.",
                    isOn: $acknowledgesAppleLicense
                )
                Toggle(
                    "I will use it only on supported Apple-branded hardware for developing, testing, or evaluating video games.",
                    isOn: $acknowledgesEvaluationUse
                )
                Toggle(
                    "I will use it only with games or other material I own or am authorized or legally permitted to use.",
                    isOn: $acknowledgesAuthorizedMaterial
                )
            }
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel, action: cancel)

                Spacer()

                Button("Agree and Download", action: accept)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAccept)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup.gptk.acceptLicense")
            }
        }
        .padding(24)
        .frame(width: 760)
        .frame(minHeight: 620)
    }
}
