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
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Applications")
                            .font(.title2.weight(.semibold))
                        Text("\(programs.count) Windows applications found in this container")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        store.refreshInstalledPrograms(for: container.id)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Button {
                        store.chooseExecutableAndRun(in: container.id)
                    } label: {
                        Label("Run EXE…", systemImage: "play.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isContainerBusy(container.id))
                }

                if programs.isEmpty {
                    ContentUnavailableView {
                        Label("No Programs Found", systemImage: "app.dashed")
                    } description: {
                        Text("Install a Windows application or choose an EXE to run it here.")
                    } actions: {
                        Button("Run EXE…") {
                            store.chooseExecutableAndRun(in: container.id)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .dashboardPanel()
                } else {
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
                    Label("Launch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isContainerBusy(container.id))

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
