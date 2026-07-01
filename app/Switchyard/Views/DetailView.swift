import SwiftUI

struct DetailView: View {
    let selection: SidebarSelection

    var body: some View {
        switch selection {
        case .gamesLaunchers:
            LibraryView()
        case .bottles:
            BottlesView()
        case .running:
            OperationsView(filter: .running)
        case .installQueue:
            OperationsView(filter: nil)
        case .logs:
            LogsView()
        case .diagnostics:
            DiagnosticsView()
        }
    }
}
