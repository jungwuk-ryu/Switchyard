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
                    onBack: {
                        presentedContainerID = nil
                        store.isPresentingContainerDetail = false
                    },
                    onDelete: { deletionTarget = container }
                )
                .id(container.id)
            } else {
                ContainerLibraryView { container in
                    store.selectedContainerID = container.id
                    presentedContainerID = container.id
                    store.isPresentingContainerDetail = true
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(
            !canUseContainers || presentedContainer == nil
                ? "Containers"
                : presentedContainer?.name ?? "Container"
        )
        .onAppear {
            if presentedContainerID == nil {
                presentedContainerID = store.selectedContainerID ?? store.containers.first?.id
            }
            store.isPresentingContainerDetail = presentedContainer != nil
        }
        .onChange(of: store.selectedContainerID) { _, selectedID in
            guard let selectedID else { return }
            presentedContainerID = selectedID
            store.isPresentingContainerDetail = true
        }
        .onDisappear {
            store.isPresentingContainerDetail = false
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
                        store.isPresentingContainerDetail = false
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
    @State private var sessionStopTarget: Container?

    private let columns = [
        GridItem(
            .adaptive(minimum: 250, maximum: 360),
            spacing: 18,
            alignment: .top
        ),
    ]

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
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(store.containers) { container in
                            ContainerLibraryCard(
                                container: container,
                                onOpen: {
                                    onOpen(container)
                                },
                                onStop: {
                                    sessionStopTarget = container
                                }
                            )
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
                                    (container.executablePath?.isEmpty ?? true)
                                        || store.isContainerBusy(container.id)
                                )

                                if store.sessionSnapshot(for: container.id)
                                    .wineServerState.hasRunningProcesses {
                                    Button("Stop", role: .destructive) {
                                        sessionStopTarget = container
                                    }
                                    Divider()
                                }

                                Button("Show in Finder") {
                                    store.openContainerInFinder(container.id)
                                }

                                Button("Install or Run App…") {
                                    store.chooseExecutableAndRun(in: container.id)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(
            "Stop all Windows apps?",
            isPresented: stopConfirmationBinding,
            titleVisibility: .visible,
            presenting: sessionStopTarget
        ) { container in
            Button("Stop All Windows Apps", role: .destructive) {
                sessionStopTarget = nil
                Task {
                    await store.stopWineServer(in: container.id)
                }
            }
            Button("Cancel", role: .cancel) {
                sessionStopTarget = nil
            }
        } message: { container in
            Text("All Windows apps in \(container.name) will close. Unsaved work may be lost.")
        }
    }

    private var stopConfirmationBinding: Binding<Bool> {
        Binding {
            sessionStopTarget != nil
        } set: { isPresented in
            if !isPresented {
                sessionStopTarget = nil
            }
        }
    }
}

private struct ContainerLibraryCard: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let onOpen: () -> Void
    let onStop: () -> Void

    @StateObject private var model = ContainerLibraryCardModel()
    @State private var isHovering = false
    @FocusState private var isStopButtonFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    preview
                    information
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isHovering
                                ? Color.accentColor.opacity(0.48)
                                : Color.primary.opacity(0.10),
                            lineWidth: isHovering ? 1.25 : 1
                        )
                }
            }
            .buttonStyle(.plain)

            if canStop {
                Button(role: .destructive, action: onStop) {
                    Group {
                        if isStopping {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                        }
                    }
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .background(Color.red.opacity(0.92), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.28))
                    }
                    .shadow(color: .black.opacity(0.26), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(isStopping)
                .help("Stop")
                .padding(12)
                .opacity(isStopButtonVisible ? 1 : 0)
                .scaleEffect(isStopButtonVisible ? 1 : 0.86)
                .allowsHitTesting(isStopButtonVisible)
                .accessibilityLabel("Stop")
                .accessibilityHidden(false)
                .focused($isStopButtonFocused)
            }
        }
        .contentShape(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .scaleEffect(isHovering ? 1.006 : 1)
        .shadow(
            color: .black.opacity(isHovering ? 0.18 : 0.08),
            radius: isHovering ? 12 : 5,
            y: isHovering ? 5 : 2
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .task(id: previewTaskIdentity) {
            await model.monitor(containerID: container.id, store: store)
        }
        .task(id: sizeTaskIdentity) {
            await model.refreshStorageSize(for: container)
        }
        .accessibilityIdentifier("containers.card.\(container.id.uuidString)")
    }

    private var preview: some View {
        ZStack {
            Color.primary.opacity(0.045)

            if let previewImage = model.previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 64, height: 64)
                        .background(
                            .blue.opacity(0.12),
                            in: RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous
                            )
                        )
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .saturation(isRunning ? 1 : 0)
        .brightness(isRunning ? 0 : -0.06)
        .opacity(isRunning ? 1 : 0.72)
        .overlay(alignment: .bottomLeading) {
            statusLabel
                .padding(11)
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(container.name)
                .font(.headline)
                .lineLimit(1)

            Text(executableDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(executableDescription)

            HStack(spacing: 12) {
                Label(lastRunDescription, systemImage: "clock")
                    .lineLimit(1)

                Spacer(minLength: 6)

                if model.isMeasuringSize && model.storageByteCount == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Size")
                } else {
                    Label(sizeDescription, systemImage: "internaldrive")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var statusLabel: some View {
        Label(statusDescription, systemImage: statusSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.thickMaterial, in: Capsule())
    }

    private var snapshot: ContainerSessionSnapshot {
        store.sessionSnapshot(for: container.id)
    }

    private var isRunning: Bool {
        snapshot.wineServerState.isWineServerRunning
    }

    private var isStopping: Bool {
        store.isStoppingWineServer(in: container.id)
    }

    private var canStop: Bool {
        snapshot.wineServerState.hasRunningProcesses || isStopping
    }

    private var isStopButtonVisible: Bool {
        isHovering || isStopButtonFocused
    }

    private var statusDescription: String {
        if isStopping {
            return String(
                localized: "Stopping",
                bundle: SwitchyardStrings.bundle
            )
        }
        return switch snapshot.wineServerState {
        case .checking:
            String(localized: "Checking", bundle: SwitchyardStrings.bundle)
        case .active:
            String(localized: "Running", bundle: SwitchyardStrings.bundle)
        case .orphaned:
            String(
                localized: "Cleanup needed",
                bundle: SwitchyardStrings.bundle
            )
        case .inactive:
            String(localized: "Idle", bundle: SwitchyardStrings.bundle)
        case .unavailable:
            String(localized: "Unavailable", bundle: SwitchyardStrings.bundle)
        }
    }

    private var statusSymbol: String {
        if isStopping { return "stop.circle.fill" }
        return switch snapshot.wineServerState {
        case .checking: "clock"
        case .active: "play.circle.fill"
        case .orphaned: "exclamationmark.triangle.fill"
        case .inactive: "pause.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        if isStopping { return .orange }
        return switch snapshot.wineServerState {
        case .active: .green
        case .orphaned: .orange
        case .unavailable: .yellow
        case .checking, .inactive: .secondary
        }
    }

    private var executableDescription: String {
        container.executablePath.map {
            ContainerPathPresentation.relativePath(for: $0, in: container)
        } ?? String(
            localized: "Choose a Windows application",
            bundle: SwitchyardStrings.bundle
        )
    }

    private var lastRunDescription: String {
        guard let lastRun = container.lastRun else {
            return String(
                localized: "Never run",
                bundle: SwitchyardStrings.bundle
            )
        }
        if Calendar.current.isDateInToday(lastRun) {
            return switchyardDateFormatter.string(from: lastRun)
        }
        return lastRun.formatted(date: .abbreviated, time: .omitted)
    }

    private var sizeDescription: String {
        guard let storageByteCount = model.storageByteCount else {
            return String(localized: "Unknown", bundle: SwitchyardStrings.bundle)
        }
        return ByteCountFormatter.string(
            fromByteCount: storageByteCount,
            countStyle: .file
        )
    }

    private var previewTaskIdentity: String {
        [
            container.id.uuidString,
            container.path,
        ].joined(separator: "\u{0}")
    }

    private var sizeTaskIdentity: String {
        container.path
    }
}
