import AppCore
import SwiftUI

struct LoginCallbackRecoverySection: View {
    @EnvironmentObject private var store: AppStore
    let container: Container

    var body: some View {
        GroupBox("Login Callback") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "If Safari says the address is invalid after signing in, press Command-L and Command-C in Safari, then recover the copied callback here."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    store.recoverCopiedLoginCallback(in: container.id)
                } label: {
                    Label("Recover Copied Callback", systemImage: "link.badge.plus")
                }
                .disabled(store.isRecoveringLoginCallback(in: container.id))

                if let state = store.loginCallbackRecoveryState(for: container.id) {
                    Label(state.message, systemImage: statusImage(for: state))
                        .font(.callout)
                        .foregroundStyle(statusStyle(for: state))
                        .fixedSize(horizontal: false, vertical: true)

                    if case let .choosing(_, candidates) = state {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(candidates, id: \.self) { candidate in
                                Button {
                                    store.chooseLoginCallbackTarget(candidate, in: container.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(executableName(candidate))
                                        Text(candidate)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                            }

                            Button("Cancel") {
                                store.cancelLoginCallbackTargetSelection(in: container.id)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                if !learnedSchemes.isEmpty {
                    LabeledContent("Learned Schemes") {
                        Text(learnedSchemes.map { "\($0):" }.joined(separator: ", "))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Text("Callback URLs and sign-in tokens are passed through a protected one-time file and are not saved or logged.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var learnedSchemes: [String] {
        store.learnedLoginCallbackSchemes(for: container.id)
    }

    private func statusImage(for state: LoginCallbackRecoveryState) -> String {
        switch state {
        case .inspecting, .choosing, .forwarding:
            "arrow.triangle.2.circlepath"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private func statusStyle(for state: LoginCallbackRecoveryState) -> AnyShapeStyle {
        switch state {
        case .inspecting, .choosing, .forwarding:
            AnyShapeStyle(.secondary)
        case .succeeded:
            AnyShapeStyle(.green)
        case .failed:
            AnyShapeStyle(.red)
        }
    }

    private func executableName(_ windowsPath: String) -> String {
        windowsPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? windowsPath
    }
}
