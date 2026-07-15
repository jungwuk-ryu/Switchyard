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
            "Finding the Windows application waiting for the \(scheme): callback…"
        case let .choosing(scheme, _):
            "Choose the Windows application that requested the \(scheme): sign-in."
        case let .forwarding(scheme):
            "Forwarding the \(scheme): callback to Wine…"
        case let .succeeded(scheme):
            "Recovered the \(scheme): callback. Future sign-ins can return automatically."
        case let .failed(message):
            message
        }
    }
}
