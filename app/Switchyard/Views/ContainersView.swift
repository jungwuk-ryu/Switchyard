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
                    description: Text("Add a container to configure and run a Windows game launcher.")
                )
                .padding()
            } else {
                Table(store.containers, selection: $store.selectedContainerID) {
                    TableColumn("Name") { container in
                        Text(container.name)
                    }

                    TableColumn("Launcher") { container in
                        Text(store.launcher(for: container)?.kind.displayName ?? "Missing")
                    }

                    TableColumn("Status") { container in
                        if let launcher = store.launcher(for: container) {
                            StatusBadge(status: launcher.status.health, label: launcher.status.label)
                        } else {
                            StatusBadge(status: .missing, label: "Missing")
                        }
                    }

                    TableColumn("Last Run") { container in
                        if let lastRun = store.launcher(for: container)?.lastRun {
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
                        Button {
                            store.runContainer(container.id)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Run Container")
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var containerDetail: some View {
        if let container = store.selectedContainer, let launcher = store.launcher(for: container) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(container.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .lineLimit(1)

                        StatusBadge(status: launcher.status.health, label: launcher.status.label)
                    }

                    Divider()

                    GroupBox("Settings") {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Name") {
                                TextField("Name", text: containerNameBinding(for: container.id))
                                    .textFieldStyle(.roundedBorder)
                            }

                            LabeledContent("Launcher") {
                                Picker("Launcher", selection: launcherKindBinding(for: container.id)) {
                                    ForEach(LauncherKind.allCases) { kind in
                                        Text(kind.displayName).tag(kind)
                                    }
                                }
                                .labelsHidden()
                            }

                            PathPickerRow(
                                title: "Executable",
                                message: "Choose the installed Windows launcher executable to run in this container.",
                                initialDirectoryURL: URL(fileURLWithPath: container.path, isDirectory: true),
                                path: executablePathBinding(for: container.id)
                            ) {
                                store.updateExecutablePath(for: container.id, to: executablePathBinding(for: container.id).wrappedValue)
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
                            LabeledContent("Patchset", value: container.patchsetID)
                            LabeledContent("GPTK Fingerprint", value: container.gptkFingerprint ?? "Not recorded")
                            LabeledContent("Schema", value: "v\(container.schemaVersion)")
                        }
                    }

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

    private func launcherKindBinding(for containerID: UUID) -> Binding<LauncherKind> {
        Binding {
            store.launchers.first(where: { $0.containerID == containerID })?.kind ?? .steam
        } set: { kind in
            store.updateLauncherKind(for: containerID, to: kind)
        }
    }

    private func executablePathBinding(for containerID: UUID) -> Binding<String> {
        Binding {
            store.launchers.first(where: { $0.containerID == containerID })?.executablePath ?? ""
        } set: { path in
            store.updateExecutablePath(for: containerID, to: path)
        }
    }
}

private struct RuntimeStatusStrip: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(status: store.runtimeStatus.wine, label: "Wine")
            StatusBadge(status: store.runtimeStatus.gptk, label: "GPTK")
            StatusBadge(status: store.runtimeStatus.patchset, label: "Patchset")

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
