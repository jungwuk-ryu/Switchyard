import AppCore
import SwiftUI

private enum ContainerDashboardSection: Equatable {
    case stage
    case applications
    case files
    case activity
    case settings

    var title: String {
        switch self {
        case .stage:
            "Session"
        case .applications:
            String(localized: "Applications", bundle: SwitchyardStrings.bundle)
        case .files:
            String(localized: "Files", bundle: SwitchyardStrings.bundle)
        case .activity:
            String(localized: "Activity", bundle: SwitchyardStrings.bundle)
        case .settings:
            String(localized: "Settings", bundle: SwitchyardStrings.bundle)
        }
    }
}

struct ContainerDashboardView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var selectedSection: ContainerDashboardSection = .stage
    @State private var selectedProgramID: String?

    var body: some View {
        ZStack {
            if selectedSection == .stage {
                ContainerSessionStageView(
                    container: container,
                    onBack: onBack,
                    onOpenDestination: openDestination,
                    onDelete: onDelete
                )
                .transition(.opacity)
            } else {
                legacySection
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.27), value: selectedSection)
        .task(id: container.id) {
            store.refreshInstalledPrograms(for: container.id)
            store.refreshStartMenuEntries(for: container.id)
            await store.monitorContainerSession(for: container.id)
        }
        .onChange(of: programs) { _, _ in
            selectInitialProgram()
        }
        .windowsApplicationDropTarget(
            containerName: container.name,
            isEnabled: !store.isContainerTransitioning(container.id)
        ) { url in
            store.runWindowsApplication(at: url, in: container.id)
        }
        .navigationTitle("")
    }

    private var legacySection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    selectedSection = .stage
                } label: {
                    Label("Session", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(selectedSection.title)
                    .font(.title2.weight(.semibold))

                Spacer()

                Button {
                    store.chooseExecutableAndRun(in: container.id)
                } label: {
                    Label("Install or Run App…", systemImage: "plus.app.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isContainerTransitioning(container.id))

                Menu {
                    Button("Show Container in Finder") {
                        store.openContainerInFinder(container.id)
                    }
                    Divider()
                    Button("Applications") {
                        selectedSection = .applications
                    }
                    Button("Files") {
                        selectedSection = .files
                    }
                    Button("Activity") {
                        selectedSection = .activity
                    }
                    Button("Settings") {
                        selectedSection = .settings
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .frame(height: 64)

            Divider()

            legacySectionContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var legacySectionContent: some View {
        switch selectedSection {
        case .stage:
            EmptyView()
        case .applications:
            ContainerApplicationsView(
                container: container,
                selectedProgramID: $selectedProgramID
            )
        case .files:
            ContainerFileBrowserView(
                container: container,
                initialDirectoryURL: nil,
                compact: false
            )
            .padding(18)
        case .activity:
            ContainerActivityView(container: container)
        case .settings:
            ContainerSettingsView(container: container, onDelete: onDelete)
        }
    }

    private var programs: [InstalledProgram] {
        store.installedPrograms(for: container.id)
    }

    private func openDestination(_ destination: ContainerDetailDestination) {
        switch destination {
        case .applications:
            selectedSection = .applications
        case .files:
            selectedSection = .files
        case .activity:
            selectedSection = .activity
        case .settings:
            selectedSection = .settings
        }
    }

    private func selectInitialProgram() {
        guard selectedProgramID == nil
                || !programs.contains(where: { $0.id == selectedProgramID }) else {
            return
        }
        selectedProgramID =
            programs.first(where: { $0.executablePath == container.executablePath })?.id
            ?? programs.first?.id
    }
}

extension View {
    func dashboardPanel(emphasized: Bool = false) -> some View {
        background(
            emphasized ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    emphasized ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                    lineWidth: emphasized ? 1.5 : 1
                )
        }
    }
}
