import AppCore
import SwiftUI

struct ContainerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Container Settings")
                        .font(.title2.weight(.semibold))
                    Text("Launch behavior and advanced compatibility options for \(container.name).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Launch") {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("Name") {
                            TextField("Name", text: containerNameBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                        }

                        PathPickerRow(
                            title: "Default Executable",
                            message: "Choose the Windows executable to run by default in this container.",
                            initialDirectoryURL: URL(fileURLWithPath: container.path, isDirectory: true),
                            path: executablePathBinding
                        ) {
                            store.updateExecutablePath(for: container.id, to: executablePathBinding.wrappedValue)
                        }

                        LabeledContent("Launch Arguments") {
                            LaunchArgumentsField(containerID: container.id)
                                .frame(maxWidth: 520)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Runtime") {
                    VStack(alignment: .leading, spacing: 11) {
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
                        LabeledContent("GPTK", value: container.gptkFingerprint ?? "Not recorded")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                LoginCallbackRecoverySection(container: container)

                GroupBox("Environment Overrides") {
                    EnvironmentOverridesEditor(containerID: container.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button {
                        store.openContainerInFinder(container.id)
                    } label: {
                        Label("Show Container in Finder", systemImage: "folder")
                    }

                    Spacer()

                    Button(role: .destructive, action: onDelete) {
                        Label("Move Container to Trash", systemImage: "trash")
                    }
                    .disabled(store.isContainerBusy(container.id))
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var containerNameBinding: Binding<String> {
        Binding {
            store.containers.first(where: { $0.id == container.id })?.name ?? ""
        } set: { name in
            store.renameContainer(container.id, to: name)
        }
    }

    private var executablePathBinding: Binding<String> {
        Binding {
            store.containers.first(where: { $0.id == container.id })?.executablePath ?? ""
        } set: { path in
            store.updateExecutablePath(for: container.id, to: path)
        }
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
                            .frame(width: 170, alignment: .leading)
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
                TextField("Variable", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 170)

                TextField("Value", text: $newValue)
                    .textFieldStyle(.roundedBorder)

                Button {
                    store.addEnvironmentOverride(for: containerID, key: newKey, value: newValue)
                    newKey = ""
                    newValue = ""
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(
                    !EnvironmentOverridePolicy.isAllowedKey(
                        newKey.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    private var overrides: [(key: String, value: String)] {
        let values =
            store.containers.first(where: { $0.id == containerID })?.environmentOverrides ?? [:]
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
