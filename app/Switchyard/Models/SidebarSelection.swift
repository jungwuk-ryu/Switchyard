import Foundation

enum SidebarSelection: String, CaseIterable, Identifiable {
    case gamesLaunchers
    case bottles
    case running
    case installQueue
    case logs
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gamesLaunchers: "Games & Launchers"
        case .bottles: "Bottles"
        case .running: "Running"
        case .installQueue: "Install Queue"
        case .logs: "Logs"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .gamesLaunchers: "gamecontroller"
        case .bottles: "shippingbox"
        case .running: "play.circle"
        case .installQueue: "tray.and.arrow.down"
        case .logs: "doc.text.magnifyingglass"
        case .diagnostics: "stethoscope"
        }
    }
}
