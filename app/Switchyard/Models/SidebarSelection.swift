import Foundation

enum SidebarSelection: String, CaseIterable, Identifiable {
    case containers
    case logs
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .logs: "Logs"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .containers: "shippingbox"
        case .logs: "doc.text.magnifyingglass"
        case .diagnostics: "stethoscope"
        }
    }
}
