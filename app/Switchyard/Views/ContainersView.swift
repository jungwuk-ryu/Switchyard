import AppCore
import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var store: AppStore
    @State private var presentedContainerID: UUID?
    @State private var deletionTarget: Container?

    var body: some View {
        Group {
            if !canUseContainers {
                ContainerLibraryView { _ in }
            } else if let container = presentedContainer {
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
            !canUseContainers || presentedContainer == nil
                ? "Containers"
                : presentedContainer?.name ?? "Container"
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
                deletionTarget = nil
                Task {
                    if await store.deleteContainer(container.id) {
                        presentedContainerID = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deletionTarget = nil
            }
        } message: { container in
            Text(
                "Any remaining Windows processes for \(container.name) will be stopped before its folder is moved to Trash.")
        }
    }

    private var presentedContainer: Container? {
        guard let presentedContainerID else { return nil }
        return store.containers.first(where: { $0.id == presentedContainerID })
    }

    private var canUseContainers: Bool {
        store.hasCompletedSetup && store.runtimeStatus.canLaunch
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
            if !store.hasCompletedSetup || !store.runtimeStatus.canLaunch {
                ContentUnavailableView {
                    Label("Finish Setting Up Switchyard", systemImage: "wand.and.stars")
                } actions: {
                    Button("Continue Setup") {
                        store.requestSetupAssistant()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("containers.continueSetup")
                }
                .padding()
            } else if store.containers.isEmpty {
                VStack {
                    ContentUnavailableView {
                        Label("Install Your First Windows App", systemImage: "gamecontroller")
                    } actions: {
                        if store.steamInstallationState.isWorking || store.isDownloadingSteamInstaller {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(
                                    store.isDownloadingSteamInstaller
                                        ? "Downloading securely from Valve…"
                                        : (store.steamInstallationState.isInstallerOpen
                                            ? "Finish installing Steam…"
                                            : "Opening the Steam installer…")
                                )
                            }
                            if store.isDownloadingSteamInstaller {
                                Button("Cancel Download") {
                                    store.cancelSteamDownloadWait()
                                }
                            }
                        } else if store.downloadedSteamInstallerPath != nil {
                            Button("Install Steam") {
                                store.installSteam()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("steam.install")
                        } else {
                            Button("Download Steam") {
                                store.downloadSteamInstaller()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("steam.download")
                        }

                        Button("Add Container") {
                            store.cancelSteamDownloadWait()
                            store.addContainer()
                        }
                    }

                    if let message = store.steamInstallationState.errorMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                    } else if let message = store.steamSetupMessage {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.containers) { container in
                            Button {
                                onOpen(container)
                            } label: {
                                ContainerLibraryRow(
                                    container: container,
                                    isWineServerRunning: store.sessionSnapshot(for: container.id)
                                        .wineServerState.isWineServerRunning
                                )
                            }
                            .buttonStyle(.plain)
                            .task(id: container.id) {
                                await store.monitorContainerSession(for: container.id)
                            }
                            .windowsApplicationDropTarget(
                                containerName: container.name,
                                isEnabled: !store.isContainerTransitioning(container.id)
                            ) { url in
                                store.runWindowsApplication(at: url, in: container.id)
                            }
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

                                Button("Install or Run App…") {
                                    store.chooseExecutableAndRun(in: container.id)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ContainerLibraryRow: View {
    let container: Container
    let isWineServerRunning: Bool

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
                    } ?? String(
                        localized: "Choose a Windows application",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 4) {
                if isWineServerRunning {
                    Label(
                        String(
                            localized: "Running",
                            bundle: SwitchyardStrings.bundle
                        ),
                        systemImage: "play.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)
                }

                Text(
                    container.lastRun.map { switchyardDateFormatter.string(from: $0) }
                        ?? String(localized: "Never run", bundle: SwitchyardStrings.bundle)
                )
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
