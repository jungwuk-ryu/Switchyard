import SwiftUI

struct DetailView: View {
    let selection: SidebarSelection

    var body: some View {
        switch selection {
        case .containers:
            ContainersView()
        case .logs:
            LogsView()
        case .diagnostics:
            DiagnosticsView()
        }
    }
}
