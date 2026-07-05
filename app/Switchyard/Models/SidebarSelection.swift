import Foundation

enum SidebarSelection: String, CaseIterable, Identifiable {
    case containers
    case running
    case installQueue
    case logs
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .running: "Running"
        case .installQueue: "Install Queue"
        case .logs: "Logs"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .containers: "shippingbox"
        case .running: "play.circle"
        case .installQueue: "tray.and.arrow.down"
        case .logs: "doc.text.magnifyingglass"
        case .diagnostics: "stethoscope"
        }
    }
}
