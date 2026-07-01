import AppCore
import SwiftUI

struct OperationsView: View {
    @EnvironmentObject private var store: AppStore
    let filter: OperationState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(filter == .running ? "Running" : "Install Queue")
                .font(.largeTitle)
                .fontWeight(.semibold)

            if visibleOperations.isEmpty {
                ContentUnavailableView(
                    filter == .running ? "No Running Operations" : "Install Queue Empty",
                    systemImage: filter == .running ? "play.circle" : "tray",
                    description: Text("Launch and install jobs will appear here with progress and cancellation controls.")
                )
            } else {
                List(visibleOperations) { operation in
                    OperationProgressRow(operation: operation)
                }
            }
        }
        .padding()
        .navigationTitle(filter == .running ? "Running" : "Install Queue")
    }

    private var visibleOperations: [InstallJob] {
        guard let filter else { return store.operations }
        return store.operations.filter { $0.state == filter }
    }
}

private struct OperationProgressRow: View {
    let operation: InstallJob

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(status: operation.state.health, label: operation.state.label)
            VStack(alignment: .leading) {
                Text(operation.title)
                    .font(.headline)
                ProgressView(value: operation.progress)
                Text(operation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}
