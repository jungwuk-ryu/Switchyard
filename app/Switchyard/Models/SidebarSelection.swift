import Foundation

enum SidebarSelection: String, CaseIterable, Identifiable {
    case containers
    case logs
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers:
            String(localized: "Containers", bundle: SwitchyardStrings.bundle)
        case .logs:
            String(localized: "Logs", bundle: SwitchyardStrings.bundle)
        case .diagnostics:
            String(localized: "Diagnostics", bundle: SwitchyardStrings.bundle)
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
