import Foundation

enum LoginCallbackRecoveryState: Equatable {
    case inspecting(scheme: String)
    case choosing(scheme: String, candidates: [String])
    case forwarding(scheme: String)
    case succeeded(scheme: String)
    case failed(message: String)

    var message: String {
        switch self {
        case let .inspecting(scheme):
            String(
                localized: "Finding the Windows application waiting for the \(scheme): callback…",
                bundle: SwitchyardStrings.bundle
            )
        case let .choosing(scheme, _):
            String(
                localized: "Choose the Windows application that requested the \(scheme): sign-in.",
                bundle: SwitchyardStrings.bundle
            )
        case let .forwarding(scheme):
            String(
                localized: "Forwarding the \(scheme): callback to Wine…",
                bundle: SwitchyardStrings.bundle
            )
        case let .succeeded(scheme):
            String(
                localized: "Recovered the \(scheme): callback. Future sign-ins can return automatically.",
                bundle: SwitchyardStrings.bundle
            )
        case let .failed(message):
            message
        }
    }
}
