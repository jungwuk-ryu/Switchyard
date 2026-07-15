import AppCore
import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var store: AppStore
    @State private var presentedContainerID: UUID?
    @State private var deletionTarget: Container?

    var body: some View {
        Group {
            if let container = presentedContainer {
                ContainerDashboardView(
                    container: container,
                    onBack: { presentedContainerID = nil },
                    onDelete: { deletionTarget = container }
                )
                .id(container.id)
            } else {
                ContainerLibraryView { container in
                    store.selectedContainerID = container.id
                    presentedContainerID = container.id
                }
            }
        }
        .navigationTitle(
            presentedContainer == nil ? "Containers" : presentedContainer?.name ?? "Container"
        )
        .onAppear {
            if presentedContainerID == nil {
                presentedContainerID = store.selectedContainerID ?? store.containers.first?.id
            }
        }
        .onChange(of: store.selectedContainerID) { _, selectedID in
            guard let selectedID else { return }
            presentedContainerID = selectedID
        }
        .confirmationDialog(
            "Move Container to Trash?",
            isPresented: deletionConfirmationBinding,
            titleVisibility: .visible,
            presenting: deletionTarget
        ) { container in
            Button("Move to Trash", role: .destructive) {
                presentedContainerID = nil
                store.deleteContainer(container.id)
                deletionTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deletionTarget = nil
            }
        } message: { container in
            Text(
                "\(container.name) will be removed from Switchyard and its folder will be moved to Trash.")
        }
    }

    private var presentedContainer: Container? {
        guard let presentedContainerID else { return nil }
        return store.containers.first(where: { $0.id == presentedContainerID })
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding {
            deletionTarget != nil
        } set: { isPresented in
            if !isPresented {
                deletionTarget = nil
            }
        }
    }
}

private struct ContainerLibraryView: View {
    @EnvironmentObject private var store: AppStore
    let onOpen: (Container) -> Void

    var body: some View {
        VStack(spacing: 0) {
            RuntimeStatusStrip()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            if store.containers.isEmpty {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "shippingbox")
                } description: {
                    Text("Create a container to install and run Windows applications.")
                } actions: {
                    Button("Create Container") {
                        store.addContainer()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.containers) { container in
                            Button {
                                onOpen(container)
                            } label: {
                                ContainerLibraryRow(container: container)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Run") {
                                    store.runContainer(container.id)
                                }
                                .disabled(
                                    (container.executablePath?.isEmpty ?? true) || store.isContainerBusy(container.id)
                                )

                                Button("Show in Finder") {
                                    store.openContainerInFinder(container.id)
                                }
                            }

                            if container.id != store.containers.last?.id {
                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct ContainerLibraryRow: View {
    let container: Container

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(container.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(
                    container.executablePath.map {
                        ContainerPathPresentation.relativePath(for: $0, in: container)
                    } ?? "Choose a Windows application"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 4) {
                Label(container.status.label, systemImage: container.status.health.symbolName)
                    .font(.callout)
                    .foregroundStyle(container.status.health.tint)

                Text(container.lastRun.map { switchyardDateFormatter.string(from: $0) } ?? "Never run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 13)
    }
}

private struct RuntimeStatusStrip: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(status: store.runtimeStatus.wine, label: "Wine")
            StatusBadge(status: store.runtimeStatus.gptk, label: "GPTK")
            StatusBadge(status: store.runtimeStatus.patchset, label: "Runtime Source")

            Divider()
                .frame(height: 20)

            Text(store.runtimeStatus.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Re-run Diagnostics") {
                store.refreshRuntimeStatus()
            }
        }
    }
}
