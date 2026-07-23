import AppCore
import SwiftUI

struct ContainerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    let container: Container
    let onDelete: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsHeader

                    if proxy.size.width >= 1_400 {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) {
                                launchSection
                                runtimeSection
                            }
                            .frame(maxWidth: .infinity, alignment: .top)

                            VStack(spacing: 16) {
                                LoginCallbackRecoverySection(container: container)
                                environmentSection
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    } else {
                        launchSection
                        runtimeSection
                        LoginCallbackRecoverySection(container: container)
                        environmentSection
                    }

                    footerActions
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .disabled(store.isChangingContainerStorage(container.id))
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Container Settings")
                .font(.title2.weight(.semibold))
            Text("Launch behavior and advanced compatibility options for \(container.name).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var launchSection: some View {
        GroupBox("Launch") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Name") {
                    ContainerNameField(containerID: container.id)
                        .frame(maxWidth: 360)
                }

                PathPickerRow(
                    title: String(
                        localized: "Default Executable",
                        bundle: SwitchyardStrings.bundle
                    ),
                    message: String(
                        localized: "Choose the Windows executable to run by default in this container.",
                        bundle: SwitchyardStrings.bundle
                    ),
                    initialDirectoryURL: URL(fileURLWithPath: container.path, isDirectory: true),
                    path: executablePathBinding
                ) {
                    store.updateExecutablePath(
                        for: container.id,
                        to: executablePathBinding.wrappedValue
                    )
                }

                LabeledContent("Launch Arguments") {
                    LaunchArgumentsField(containerID: container.id)
                        .frame(maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runtimeSection: some View {
        let runtime = store.currentRuntime

        return GroupBox("Runtime") {
            VStack(alignment: .leading, spacing: 11) {
                RuntimeBuildSummaryView(runtime: runtime)

                LabeledContent("Runtime Scope") {
                    Label("Used by every container", systemImage: "square.stack.3d.up.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Switchyard always uses the active app-wide runtime shown above. Containers do not select or pin runtime versions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Last Runtime Use") {
                    if let lastRuntime = container.lastRuntime {
                        let identityComparison = runtime.comparison(
                            toLastRuntime: lastRuntime
                        )
                        Label(
                            identityComparison.label,
                            systemImage: identityComparison.symbolName
                        )
                        .font(.caption)
                        .foregroundStyle(identityComparison.color)
                    } else {
                        Label("Not used yet", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(lastRuntimeUseDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                DisclosureGroup("Technical Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        RuntimeBuildTechnicalDetailsView(runtime: runtime)
                        if let lastRuntime = container.lastRuntime {
                            Divider()
                            runtimeHistoryValue(
                                String(
                                    localized: "Last-used Runtime ID",
                                    bundle: SwitchyardStrings.bundle
                                ),
                                lastRuntime.runtimeID
                            )
                            runtimeHistoryValue(
                                String(
                                    localized: "Last-used Patch Set",
                                    bundle: SwitchyardStrings.bundle
                                ),
                                lastRuntime.patchsetID
                            )
                            runtimeHistoryValue(
                                String(
                                    localized: "Last-used Source",
                                    bundle: SwitchyardStrings.bundle
                                ),
                                lastRuntime.sourceRevision
                                    ?? String(
                                        localized: "Not recorded",
                                        bundle: SwitchyardStrings.bundle
                                    )
                            )
                            runtimeHistoryValue(
                                String(
                                    localized: "Last-used GPTK",
                                    bundle: SwitchyardStrings.bundle
                                ),
                                lastRuntime.gptkFingerprint
                                    ?? String(
                                        localized: "Not recorded",
                                        bundle: SwitchyardStrings.bundle
                                    )
                            )
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lastRuntimeUseDetail: String {
        guard let lastRuntime = container.lastRuntime else {
            return String(
                localized: "Runtime provenance will be recorded after this container first uses Wine.",
                bundle: SwitchyardStrings.bundle
            )
        }
        guard let usedAt = lastRuntime.usedAt else {
            return String(
                localized: "Imported from a legacy manifest; the exact usage time was not recorded.",
                bundle: SwitchyardStrings.bundle
            )
        }
        return String(
            localized: "Recorded \(usedAt.formatted(date: .abbreviated, time: .shortened)).",
            bundle: SwitchyardStrings.bundle
        )
    }

    private var environmentSection: some View {
        GroupBox("Environment Overrides") {
            EnvironmentOverridesEditor(containerID: container.id)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerActions: some View {
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
            .disabled(store.isContainerTransitioning(container.id))
        }
    }

    private var executablePathBinding: Binding<String> {
        Binding {
            store.containers.first(where: { $0.id == container.id })?.executablePath ?? ""
        } set: { path in
            store.updateExecutablePath(for: container.id, to: path)
        }
    }

    private func runtimeHistoryValue(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }
}

private struct ContainerNameField: View {
    @EnvironmentObject private var store: AppStore
    let containerID: UUID

    @FocusState private var isFocused: Bool
    @State private var draft = ""
    @State private var isCommitting = false

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .disabled(store.isContainerBusy(containerID) || isCommitting)
            .onAppear {
                draft = storedName
            }
            .onChange(of: containerID) { _, _ in
                draft = storedName
            }
            .onChange(of: storedName) { _, name in
                guard !isFocused else { return }
                draft = name
            }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commitRename()
                }
            }
            .onSubmit {
                commitRename()
                isFocused = false
            }
            .help("Press Return or leave the field to rename the container and its folder")
    }

    private var storedName: String {
        store.containers.first(where: { $0.id == containerID })?.name ?? ""
    }

    private func commitRename() {
        guard !isCommitting else { return }
        let requestedName = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            draft = storedName
            return
        }
        guard requestedName != storedName else {
            draft = storedName
            return
        }

        isCommitting = true
        Task {
            _ = await store.renameContainer(containerID, to: requestedName)
            draft = storedName
            isCommitting = false
        }
    }
}

private extension RuntimeIdentityComparison {
    var label: String {
        switch self {
        case .matches:
            String(localized: "Last used with active build", bundle: SwitchyardStrings.bundle)
        case .differs:
            String(localized: "Last used with another build", bundle: SwitchyardStrings.bundle)
        case .unavailable:
            String(localized: "Comparison unavailable", bundle: SwitchyardStrings.bundle)
        }
    }

    var symbolName: String {
        switch self {
        case .matches: "checkmark.circle.fill"
        case .differs: "clock.arrow.circlepath"
        case .unavailable: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .matches: .green
        case .differs: .blue
        case .unavailable: .gray
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
