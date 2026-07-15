import AppCore
import SwiftUI

struct ContainersView: View {
    @EnvironmentObject private var store: AppStore
    @State private var deletionTarget: Container?

    var body: some View {
        HSplitView {
            containerList
                .frame(minWidth: 720)

            containerDetail
                .frame(minWidth: 340, idealWidth: 390, maxWidth: 460)
        }
        .navigationTitle("Containers")
        .confirmationDialog(
            "Move Container to Trash?",
            isPresented: deletionConfirmationBinding,
            titleVisibility: .visible,
            presenting: deletionTarget
        ) { container in
            Button("Move to Trash", role: .destructive) {
                store.deleteContainer(container.id)
                deletionTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deletionTarget = nil
            }
        } message: { container in
            Text("\(container.name) will be removed from Switchyard and its folder will be moved to Trash.")
        }
    }

    private var containerList: some View {
        VStack(spacing: 0) {
            RuntimeStatusStrip()
                .padding()

            Divider()

            if store.containers.isEmpty {
                ContentUnavailableView(
                    "No Containers",
                    systemImage: "shippingbox",
                    description: Text("Add a container to configure a Wine prefix and run a Windows executable.")
                )
                .padding()
            } else {
                Table(store.containers, selection: $store.selectedContainerID) {
                    TableColumn("Name") { container in
                        Text(container.name)
                    }

                    TableColumn("Status") { container in
                        StatusBadge(status: container.status.health, label: container.status.label)
                    }

                    TableColumn("Last Run") { container in
                        if let lastRun = container.lastRun {
                            Text(switchyardDateFormatter.string(from: lastRun))
                        } else {
                            Text("Never")
                                .foregroundStyle(.secondary)
                        }
                    }

                    TableColumn("Path") { container in
                        Text(container.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    TableColumn("Action") { container in
                        HStack(spacing: 6) {
                            Button {
                                store.runContainer(container.id)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Run Container")
                            .disabled((container.executablePath?.isEmpty ?? true) || store.isContainerBusy(container.id))

                            Button {
                                store.chooseExecutableAndRun(in: container.id)
                            } label: {
                                Image(systemName: "play.square")
                            }
                            .buttonStyle(.borderless)
                            .help("Run EXE...")
                            .disabled(store.isContainerBusy(container.id))
                        }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var containerDetail: some View {
        if let container = store.selectedContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(container.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .lineLimit(1)

                        StatusBadge(status: container.status.health, label: container.status.label)
                    }

                    Divider()

                    InstalledProgramsSection(container: container)
                        .environmentObject(store)

                    GroupBox("Settings") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Name") {
                                TextField("Name", text: containerNameBinding(for: container.id))
                                    .textFieldStyle(.roundedBorder)
                            }

                            PathPickerRow(
                                title: "Executable",
                                message: "Choose the Windows executable to run inside this container.",
                                initialDirectoryURL: URL(fileURLWithPath: container.path, isDirectory: true),
                                path: executablePathBinding(for: container.id)
                            ) {
                                store.updateExecutablePath(for: container.id, to: executablePathBinding(for: container.id).wrappedValue)
                            }

                            LabeledContent("Arguments") {
                                LaunchArgumentsField(containerID: container.id)
                                    .environmentObject(store)
                            }
                        }
                    }

                    GroupBox("Runtime") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Container Path") {
                                HStack {
                                    Text(container.path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    Button {
                                        store.openContainerInFinder(container.id)
                                    } label: {
                                        Image(systemName: "folder")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Show in Finder")
                                }
                            }
                            LabeledContent("Wine Build", value: container.wineBuildID)
                            LabeledContent("Runtime Source", value: container.patchsetID)
                            LabeledContent("GPTK Fingerprint", value: container.gptkFingerprint ?? "Not recorded")
                            LabeledContent("Schema", value: "v\(container.schemaVersion)")
                        }
                    }

                    LoginCallbackRecoverySection(container: container)
                        .environmentObject(store)

                    GroupBox("Environment") {
                        EnvironmentOverridesEditor(containerID: container.id)
                            .environmentObject(store)
                    }

                    HStack {
                        Button {
                            store.runContainer(container.id)
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                        .disabled((container.executablePath?.isEmpty ?? true) || store.isContainerBusy(container.id))

                        Button {
                            store.chooseExecutableAndRun(in: container.id)
                        } label: {
                            Label("Run EXE...", systemImage: "play.square")
                        }
                        .disabled(store.isContainerBusy(container.id))

                        Button {
                            store.openContainerInFinder(container.id)
                        } label: {
                            Label("Finder", systemImage: "folder")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            deletionTarget = container
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .padding()
            }
            .task(id: container.id) {
                store.refreshInstalledPrograms(for: container.id)
            }
        } else {
            ContentUnavailableView(
                "Select a Container",
                systemImage: "shippingbox",
                description: Text("Container settings and launch controls appear here.")
            )
            .padding()
        }
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

    private func containerNameBinding(for containerID: UUID) -> Binding<String> {
        Binding {
            store.containers.first(where: { $0.id == containerID })?.name ?? ""
        } set: { name in
            store.renameContainer(containerID, to: name)
        }
    }

    private func executablePathBinding(for containerID: UUID) -> Binding<String> {
        Binding {
            store.containers.first(where: { $0.id == containerID })?.executablePath ?? ""
        } set: { path in
            store.updateExecutablePath(for: containerID, to: path)
        }
    }

}

private struct InstalledProgramsSection: View {
    @EnvironmentObject private var store: AppStore
    let container: Container

    var body: some View {
        GroupBox("Installed Programs") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        store.refreshInstalledPrograms(for: container.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh Programs")
                }
                .padding(.bottom, programs.isEmpty ? 0 : 4)

                if programs.isEmpty {
                    ContentUnavailableView(
                        "No Programs Found",
                        systemImage: "app.dashed",
                        description: Text("Installed Windows apps will appear here after setup.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(Array(programs.enumerated()), id: \.element.id) { index, program in
                        InstalledProgramRow(
                            container: container,
                            program: program,
                            isDefault: isDefaultProgram(program, for: container)
                        )
                        .environmentObject(store)

                        if index < programs.count - 1 {
                            Divider()
                                .padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }

    private var programs: [InstalledProgram] {
        store.installedPrograms(for: container.id)
    }

    private func isDefaultProgram(_ program: InstalledProgram, for container: Container) -> Bool {
        container.executablePath == program.executablePath
    }
}

private struct LaunchArgumentsField: View {
    @EnvironmentObject private var store: AppStore
    let containerID: UUID
    @FocusState private var isFocused: Bool
    @State private var draft = ""

    var body: some View {
        TextField("Optional launch arguments", text: draftBinding)
            .focused($isFocused)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onAppear {
                draft = formattedStoredArguments
            }
            .onChange(of: containerID) { _, _ in
                draft = formattedStoredArguments
            }
            .onChange(of: storedArguments) { _, arguments in
                guard !isFocused else { return }
                draft = LaunchArgumentParser.format(arguments)
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    draft = formattedStoredArguments
                }
            }
    }

    private var draftBinding: Binding<String> {
        Binding {
            draft
        } set: { commandLine in
            draft = commandLine
            store.updateExecutableArguments(for: containerID, to: LaunchArgumentParser.parse(commandLine))
        }
    }

    private var storedArguments: [String] {
        store.containers.first(where: { $0.id == containerID })?.executableArguments ?? []
    }

    private var formattedStoredArguments: String {
        LaunchArgumentParser.format(storedArguments)
    }
}

private struct InstalledProgramRow: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let program: InstalledProgram
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(program.name)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Default Executable")
                    }
                }

                Text(relativeExecutablePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                store.runInstalledProgram(program, in: container.id)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help(runHelp)
            .disabled(store.isContainerBusy(container.id))

            Button {
                store.useInstalledProgramAsDefault(program, for: container.id)
            } label: {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Use as Default Executable")
            .disabled(isDefault)
        }
        .padding(.vertical, 8)
    }

    private var relativeExecutablePath: String {
        let containerPath = URL(fileURLWithPath: container.path, isDirectory: true)
            .standardizedFileURL
            .path
        let executablePath = URL(fileURLWithPath: program.executablePath)
            .standardizedFileURL
            .path

        guard executablePath.hasPrefix(containerPath + "/") else {
            return program.executablePath
        }

        return String(executablePath.dropFirst(containerPath.count + 1))
    }

    private var runHelp: String {
        "Run Program"
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

            Spacer()

            Button("Re-run Diagnostics") {
                store.refreshRuntimeStatus()
            }
        }
    }
}

private struct EnvironmentOverridesEditor: View {
    @EnvironmentObject private var store: AppStore
    let containerID: UUID
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if overrides.isEmpty {
                Text("No environment overrides.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(overrides, id: \.key) { override in
                    HStack {
                        Text(override.key)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        TextField("Value", text: valueBinding(for: override.key))
                            .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            store.removeEnvironmentOverride(for: containerID, key: override.key)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove Variable")
                    }
                }
            }

            Divider()

            HStack {
                TextField("Name", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 130)

                TextField("Value", text: $newValue)
                    .textFieldStyle(.roundedBorder)

                Button {
                    store.addEnvironmentOverride(for: containerID, key: newKey, value: newValue)
                    newKey = ""
                    newValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Add Variable")
                .disabled(!EnvironmentOverridePolicy.isAllowedKey(newKey.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    private var overrides: [(key: String, value: String)] {
        let values = store.containers.first(where: { $0.id == containerID })?.environmentOverrides ?? [:]
        return values.map { ($0.key, $0.value) }.sorted { $0.key < $1.key }
    }

    private func valueBinding(for key: String) -> Binding<String> {
        Binding {
            store.containers.first(where: { $0.id == containerID })?.environmentOverrides[key] ?? ""
        } set: { value in
            store.updateEnvironmentOverride(for: containerID, key: key, value: value)
        }
    }
}
