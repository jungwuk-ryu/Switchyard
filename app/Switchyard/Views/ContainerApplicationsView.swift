import AppCore
import SwiftUI

struct ContainerApplicationsView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    @Binding var selectedProgramID: String?

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    if store.sessionSnapshot(for: container.id).wineServerState == .orphaned {
                        Label("Cleanup needed", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Button {
                        store.refreshInstalledPrograms(for: container.id)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button {
                        if isSteamStarterContainer {
                            store.continueSteamSetup()
                        } else {
                            store.chooseExecutableAndRun(in: container.id)
                        }
                    } label: {
                        if isSteamStarterContainer && starterSetupIsBusy {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Continuing Steam Setup…")
                            }
                        } else if store.isStoppingWineServer(in: container.id) {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Stopping…")
                            }
                        } else if store.isContainerLaunching(container.id) {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Starting…")
                            }
                        } else {
                            Label(
                                isSteamStarterContainer ? "Continue Steam Setup" : "Install or Run App…",
                                systemImage: isSteamStarterContainer ? "arrow.clockwise.circle" : "play.square"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isContainerTransitioning(container.id) || starterSetupIsBusy)
                }

                if !recentPrograms.isEmpty {
                    RecentlyLaunchedProgramsSection(
                        container: container,
                        programs: recentPrograms,
                        selectedProgramID: $selectedProgramID
                    )
                }

                if programs.isEmpty {
                    VStack {
                        ContentUnavailableView {
                            Label("No Programs Found", systemImage: "app.dashed")
                        } actions: {
                            Button(isSteamStarterContainer ? "Continue Steam Setup" : "Choose Windows App…") {
                                if isSteamStarterContainer {
                                    store.continueSteamSetup()
                                } else {
                                    store.chooseExecutableAndRun(in: container.id)
                                }
                            }
                            .disabled(store.isContainerTransitioning(container.id) || starterSetupIsBusy)
                        }

                        if isSteamStarterContainer,
                           let message = store.steamInstallationState.errorMessage {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .dashboardPanel()
                } else {
                    Text("All Applications")
                        .font(.headline)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(programs) { program in
                            ApplicationCard(
                                container: container,
                                program: program,
                                isSelected: selectedProgramID == program.id,
                                isDefault: container.executablePath == program.executablePath,
                                onSelect: { selectedProgramID = program.id }
                            )
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var programs: [InstalledProgram] {
        store.installedPrograms(for: container.id)
    }

    private var recentPrograms: [RecentInstalledProgram] {
        store.recentInstalledPrograms(for: container.id)
    }

    private var isSteamStarterContainer: Bool {
        container.starterApplicationID == StarterApplicationCatalog.steam.id
            && programs.isEmpty
    }

    private var starterSetupIsBusy: Bool {
        isSteamStarterContainer
            && (store.isDownloadingSteamInstaller || store.steamInstallationState.isWorking)
    }
}

private struct RecentlyLaunchedProgramsSection: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let programs: [RecentInstalledProgram]
    @Binding var selectedProgramID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recently Launched")
                    .font(.headline)

                Spacer()

                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(programs.prefix(8)) { recentProgram in
                        Button {
                            selectedProgramID = recentProgram.program.id
                            store.runInstalledProgram(recentProgram.program, in: container.id)
                        } label: {
                            HStack(spacing: 12) {
                                WindowsProgramIconView(program: recentProgram.program, size: 46)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recentProgram.program.presentationName)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(recentProgram.relativeLaunchDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                if store.isLaunchingProgram(recentProgram.program, in: container.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(12)
                            .frame(width: 260, alignment: .leading)
                            .background(
                                selectedProgramID == recentProgram.program.id
                                    ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isContainerTransitioning(container.id))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .dashboardPanel()
    }
}

private struct ApplicationCard: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let program: InstalledProgram
    let isSelected: Bool
    let isDefault: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                WindowsProgramIconView(program: program, size: 62)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(program.presentationName)
                            .font(.headline)
                            .lineLimit(1)

                        if isDefault {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .help("Default Application")
                        }
                    }

                    Text(ContainerPathPresentation.windowsPath(for: program.executablePath, in: container))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            HStack {
                Button {
                    onSelect()
                    store.runInstalledProgram(program, in: container.id)
                } label: {
                    if store.isLaunchingProgram(program, in: container.id) {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting…")
                        }
                    } else {
                        Label("Launch", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isContainerTransitioning(container.id))

                Button {
                    store.openInFinder(
                        URL(fileURLWithPath: program.installDirectory, isDirectory: true),
                        in: container.id
                    )
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show Program in Finder")

                Spacer()

                if !isDefault {
                    Button("Make Default") {
                        onSelect()
                        store.useInstalledProgramAsDefault(program, for: container.id)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(15)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(perform: onSelect)
        .dashboardPanel(emphasized: isSelected)
        .contextMenu {
            Button("Launch") {
                onSelect()
                store.runInstalledProgram(program, in: container.id)
            }
            .disabled(store.isContainerTransitioning(container.id))
            Button("Make Default") {
                onSelect()
                store.useInstalledProgramAsDefault(program, for: container.id)
            }
            .disabled(isDefault)
            Button("Show in Finder") {
                store.openInFinder(
                    URL(fileURLWithPath: program.installDirectory, isDirectory: true),
                    in: container.id
                )
            }
        }
    }
}
