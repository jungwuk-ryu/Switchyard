import AppCore
import AppKit
import ImageIO
import SwiftUI

struct ContainerSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let container: Container
    let onDelete: () -> Void

    @State private var selectedSection = ContainerSettingsSection.appearance
    @State private var appearanceDraft: ContainerSessionAppearance
    @State private var isEditingAppearance = false
    @State private var isChangingBackground = false
    @State private var advancedCapabilities = D3DMetalAdvancedSettingCapabilities(
        majorVersion: nil
    )

    init(container: Container, onDelete: @escaping () -> Void) {
        self.container = container
        self.onDelete = onDelete
        _appearanceDraft = State(initialValue: container.sessionAppearance)
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 920 {
                HStack(spacing: 0) {
                    settingsSidebar
                        .frame(width: 220)

                    Divider()

                    sectionScrollView
                }
            } else {
                VStack(spacing: 0) {
                    compactNavigation
                    Divider()
                    sectionScrollView
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
        .disabled(store.isChangingContainerStorage(container.id))
        .onAppear {
            appearanceDraft = storedAppearance
        }
        .onChange(of: container.id) { _, _ in
            selectedSection = .appearance
            appearanceDraft = storedAppearance
        }
        .onChange(of: storedAppearance) { _, appearance in
            guard !isEditingAppearance else { return }
            appearanceDraft = appearance
        }
        .task(id: store.gptkPath) {
            let gptkRootPath = store.gptkPath
            let capabilities = await Task.detached(priority: .utility) {
                D3DMetalAdvancedSettingCapabilities.inspect(
                    gptkRootPath: gptkRootPath
                )
            }.value
            guard !Task.isCancelled, store.gptkPath == gptkRootPath else {
                return
            }
            advancedCapabilities = capabilities
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                Text(localizedSettings("Container Settings"))
                    .font(.title3.weight(.semibold))
                Text(liveContainer.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)

            ForEach(ContainerSettingsSection.allCases) { section in
                Button {
                    select(section)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 21)

                        Text(section.title)
                            .font(.callout.weight(.medium))

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(
                        selectedSection == section ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background {
                        if selectedSection == section {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.25))
                                }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }

            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var compactNavigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizedSettings("Container Settings"))
                .font(.title3.weight(.semibold))

            Picker(
                localizedSettings("Settings Section"),
                selection: $selectedSection
            ) {
                ForEach(ContainerSettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var sectionScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader

                switch selectedSection {
                case .appearance:
                    appearanceSection
                case .general:
                    generalSection
                case .advanced:
                    advancedSection
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(selectedSection.title, systemImage: selectedSection.systemImage)
                .font(.title2.weight(.semibold))

            Text(selectedSection.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var appearanceSection: some View {
        SettingsCard(
            title: localizedSettings("Session Background"),
            subtitle: localizedSettings(
                "Personalize the workspace while keeping every window easy to read."
            ),
            systemImage: "photo.on.rectangle.angled"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 22) {
                    appearancePreview
                        .frame(width: 400)
                    appearanceControls
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 20) {
                    appearancePreview
                    appearanceControls
                }
            }
        }
    }

    private var appearancePreview: some View {
        SessionAppearancePreview(
            containerName: liveContainer.name,
            imageURL: appearanceBackgroundURL,
            appearance: appearanceDraft
        )
        .id(liveContainer.lastModified)
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .accessibilityLabel(localizedSettings("Session background preview"))
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(localizedSettings("Background"))
                    .font(.headline)

                Text(
                    appearanceDraft.backgroundImageRelativePath == nil
                        ? localizedSettings("Switchyard gradient")
                        : localizedSettings("Custom image")
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        chooseBackground()
                    } label: {
                        Label(
                            localizedSettings("Choose Image…"),
                            systemImage: "photo.badge.plus"
                        )
                    }
                    .disabled(isChangingBackground)

                    if appearanceDraft.backgroundImageRelativePath != nil {
                        Button(role: .destructive) {
                            removeBackground()
                        } label: {
                            Text(localizedSettings("Remove"))
                        }
                        .disabled(isChangingBackground)
                    }

                    if isChangingBackground {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(localizedSettings("Updating background"))
                    }
                }
            }

            Divider()

            AppearanceSliderRow(
                title: localizedSettings("Dim"),
                valueLabel: appearanceDimLabel,
                systemImage: "circle.lefthalf.filled",
                value: $appearanceDraft.dimOpacity,
                range: ContainerSessionAppearance.dimOpacityRange,
                step: 0.01,
                onEditingChanged: appearanceEditingChanged
            )

            AppearanceSliderRow(
                title: localizedSettings("Blur"),
                valueLabel: appearanceBlurLabel,
                systemImage: "aqi.medium",
                value: $appearanceDraft.blurRadius,
                range: ContainerSessionAppearance.blurRadiusRange,
                step: 1,
                onEditingChanged: appearanceEditingChanged
            )

            Text(localizedSettings("Changes apply to this container’s session workspace."))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        SettingsCard(
            title: localizedSettings("Launch"),
            subtitle: localizedSettings("Choose what this container opens by default."),
            systemImage: "play.square.stack"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent(localizedSettings("Name")) {
                    ContainerNameField(containerID: container.id)
                        .frame(maxWidth: 360)
                }

                Divider()

                PathPickerRow(
                    title: localizedSettings("Default Executable"),
                    message: localizedSettings(
                        "Choose the Windows executable to run by default in this container."
                    ),
                    initialDirectoryURL: URL(
                        fileURLWithPath: liveContainer.path,
                        isDirectory: true
                    ),
                    path: executablePathBinding
                ) {
                    store.updateExecutablePath(
                        for: container.id,
                        to: executablePathBinding.wrappedValue
                    )
                }

                Divider()

                LabeledContent(localizedSettings("Launch Arguments")) {
                    LaunchArgumentsField(containerID: container.id)
                        .frame(maxWidth: 520)
                }
            }
        }

        SettingsCard(
            title: localizedSettings("Display"),
            subtitle: localizedSettings("Tune Wine scaling for this container."),
            systemImage: "display"
        ) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(localizedSettings("Retina Mode"))
                        .font(.headline)
                    Text(
                        localizedSettings(
                            "192 DPI keeps text and controls at their usual size. Applies on the next launch."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Picker(localizedSettings("Retina Mode"), selection: displayModeBinding) {
                    if currentDisplayMode == nil {
                        Text(localizedSettings("Keep Existing Wine Settings"))
                            .tag(nil as ContainerDisplayMode?)
                    }
                    Text(localizedSettings("Off"))
                        .tag(ContainerDisplayMode?.some(.standard))
                    Text(localizedSettings("Retina"))
                        .tag(ContainerDisplayMode?.some(.retina))
                    Text(localizedSettings("Retina + 192 DPI"))
                        .tag(ContainerDisplayMode?.some(.retinaWithLargerInterface))
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .disabled(store.isContainerBusy(container.id))
            }
        }

        SettingsCard(
            title: localizedSettings("Login Callback"),
            subtitle: localizedSettings("Recover browser sign-in links when an app cannot receive them."),
            systemImage: "link"
        ) {
            LoginCallbackSettingsContent(container: liveContainer)
        }

        SettingsCard(
            title: localizedSettings("Storage"),
            subtitle: localizedSettings("The container folder holds its Windows drive and settings."),
            systemImage: "externaldrive"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(liveContainer.path)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button {
                    store.openContainerInFinder(container.id)
                } label: {
                    Label(
                        localizedSettings("Show in Finder"),
                        systemImage: "folder"
                    )
                }
            }
        }

        HStack {
            Text(localizedSettings("Deleting a container moves its managed folder to the Trash."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Label(
                    localizedSettings("Move Container to Trash"),
                    systemImage: "trash"
                )
            }
            .disabled(store.isContainerTransitioning(container.id))
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var advancedSection: some View {
        SettingsCard(
            title: localizedSettings("Graphics & Performance"),
            subtitle: localizedSettings(
                "Tune D3DMetal and Rosetta for compatible games."
            ),
            systemImage: "gamecontroller.fill"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                AdvancedToggleRow(
                    title: localizedSettings("D3DMetal statistics HUD"),
                    description: localizedSettings(
                        "Shows on-screen D3DMetal statistics on the next launch. Compatible GPTK and D3DMetal apps only."
                    ),
                    systemImage: "chart.xyaxis.line",
                    badge: d3dMetalAvailabilityBadge,
                    isEnabled: advancedCapabilities.supportsD3DMetalSettings,
                    isOn: d3dMetalStatisticsBinding
                )

                Divider()
                    .padding(.leading, 48)

                AdvancedToggleRow(
                    title: localizedSettings("Force DirectX Raytracing"),
                    description: localizedSettings(
                        "Exposes D3DMetal's DXR support to DirectX 12 games. GPTK already enables it by default on M3 and newer Macs."
                    ),
                    systemImage: "rays",
                    badge: d3dMetalAvailabilityBadge,
                    isEnabled: advancedCapabilities.supportsD3DMetalSettings,
                    isOn: forceDirectXRaytracingBinding
                )

                Divider()
                    .padding(.leading, 48)

                AdvancedToggleRow(
                    title: localizedSettings("Rosetta AVX compatibility"),
                    description: localizedSettings(
                        "Lets games detect instruction extensions that Rosetta can already translate. It does not add unsupported instructions. Requires macOS 15 or later."
                    ),
                    systemImage: "cpu",
                    badge: rosettaAVXAvailabilityBadge,
                    isEnabled: supportsRosettaAVXAdvertising,
                    isOn: advertiseRosettaAVXBinding
                )

                Divider()
                    .padding(.leading, 48)

                AdvancedFrameRateRow(
                    title: localizedSettings("Frame rate limit"),
                    description: localizedSettings(
                        "Caps compatible D3DMetal apps at the selected frame rate. Requires GPTK 4."
                    ),
                    badge: frameRateAvailabilityBadge,
                    isEnabled: advancedCapabilities.supportsFrameRateLimit,
                    values: frameRateLimitValues,
                    selection: frameRateLimitBinding,
                    label: frameRateLimitLabel
                )
            }
        }

        SettingsCard(
            title: localizedSettings("Compatibility & Diagnostics"),
            subtitle: localizedSettings(
                "Use these only when an app needs a compatibility workaround or extra logs."
            ),
            systemImage: "stethoscope"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                AdvancedToggleRow(
                    title: localizedSettings("Legacy 2 GB memory limit"),
                    description: localizedSettings(
                        "Limits 32-bit apps to 2 GB on the next launch. Use only when an older app fails with the default 4 GB address space."
                    ),
                    systemImage: "memorychip",
                    badge: localizedSettings("Next launch"),
                    isEnabled: true,
                    isOn: legacyAddressSpaceBinding
                )

                Divider()
                    .padding(.leading, 48)

                AdvancedToggleRow(
                    title: localizedSettings("Wine error and warning logs"),
                    description: localizedSettings(
                        "Records standard Wine errors and warnings on the next launch. Log files may grow faster."
                    ),
                    systemImage: "doc.text.magnifyingglass",
                    badge: localizedSettings("Next launch"),
                    isEnabled: true,
                    isOn: wineLoggingBinding
                )
            }
        }

        SettingsCard(
            title: localizedSettings("Environment Overrides"),
            subtitle: localizedSettings(
                "For advanced troubleshooting. Invalid or reserved variables are rejected."
            ),
            systemImage: "terminal"
        ) {
            DisclosureGroup {
                EnvironmentOverridesEditor(containerID: container.id)
                    .padding(.top, 14)
            } label: {
                Label(
                    localizedSettings("Edit Variables"),
                    systemImage: "slider.horizontal.3"
                )
                .font(.headline)
            }
        }
    }

    private var liveContainer: Container {
        store.containers.first(where: { $0.id == container.id }) ?? container
    }

    private var storedAppearance: ContainerSessionAppearance {
        liveContainer.sessionAppearance
    }

    private var appearanceBackgroundURL: URL? {
        guard let relativePath = appearanceDraft.backgroundImageRelativePath else {
            return nil
        }
        return URL(fileURLWithPath: liveContainer.path, isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    private var appearanceDimLabel: String {
        "\(Int((appearanceDraft.dimOpacity * 100).rounded()))%"
    }

    private var appearanceBlurLabel: String {
        "\(Int(appearanceDraft.blurRadius.rounded())) pt"
    }

    private var executablePathBinding: Binding<String> {
        Binding {
            liveContainer.executablePath ?? ""
        } set: { path in
            store.updateExecutablePath(for: container.id, to: path)
        }
    }

    private var currentDisplayMode: ContainerDisplayMode? {
        liveContainer.displayMode
    }

    private var displayModeBinding: Binding<ContainerDisplayMode?> {
        Binding {
            currentDisplayMode
        } set: { displayMode in
            guard let displayMode else { return }
            store.updateDisplayMode(for: container.id, to: displayMode)
        }
    }

    private var d3dMetalStatisticsBinding: Binding<Bool> {
        environmentToggleBinding(.d3dMetalStatistics)
    }

    private var forceDirectXRaytracingBinding: Binding<Bool> {
        environmentToggleBinding(.forceDirectXRaytracing)
    }

    private var advertiseRosettaAVXBinding: Binding<Bool> {
        Binding {
            RosettaAVXHostPolicy.current.isEnabled(
                in: liveContainer.environmentOverrides
            )
        } set: { enabled in
            store.updateEnvironmentOverride(
                for: container.id,
                key: RosettaAVXAdvertisingPolicy.environmentKey,
                value: enabled ? "1" : "0"
            )
        }
    }

    private var wineLoggingBinding: Binding<Bool> {
        environmentToggleBinding(.wineDiagnostics)
    }

    private var legacyAddressSpaceBinding: Binding<Bool> {
        environmentToggleBinding(.legacyAddressSpace)
    }

    private var supportsRosettaAVXAdvertising: Bool {
        RosettaAVXHostPolicy.current.isSupported
    }

    private var d3dMetalAvailabilityBadge: String {
        advancedCapabilities.supportsD3DMetalSettings
            ? localizedSettings("Next launch")
            : "GPTK"
    }

    private var rosettaAVXAvailabilityBadge: String {
        supportsRosettaAVXAdvertising
            ? localizedSettings("Next launch")
            : "macOS 15+"
    }

    private var frameRateAvailabilityBadge: String {
        advancedCapabilities.supportsFrameRateLimit
            ? localizedSettings("Next launch")
            : "GPTK 4"
    }

    private var frameRateLimitValues: [String] {
        var values = [""] + D3DMetalFrameRateLimitPolicy.presetValues
        if let current = liveContainer.environmentOverrides[
            D3DMetalFrameRateLimitPolicy.environmentKey
        ],
           !current.isEmpty,
           !values.contains(current) {
            values.append(current)
        }
        return values
    }

    private var frameRateLimitBinding: Binding<String> {
        Binding {
            liveContainer.environmentOverrides[
                D3DMetalFrameRateLimitPolicy.environmentKey
            ] ?? ""
        } set: { value in
            if value.isEmpty {
                store.removeEnvironmentOverride(
                    for: container.id,
                    key: D3DMetalFrameRateLimitPolicy.environmentKey
                )
            } else if D3DMetalFrameRateLimitPolicy.isValidPreset(value) {
                store.updateEnvironmentOverride(
                    for: container.id,
                    key: D3DMetalFrameRateLimitPolicy.environmentKey,
                    value: value
                )
            }
        }
    }

    private func frameRateLimitLabel(_ value: String) -> String {
        if value.isEmpty {
            return localizedSettings("Unlimited")
        }
        if Int(value) != nil {
            return "\(value) FPS"
        }
        return value
    }

    private func environmentToggleBinding(
        _ option: ContainerAdvancedEnvironmentOption
    ) -> Binding<Bool> {
        Binding {
            option.isEnabled(in: liveContainer.environmentOverrides)
        } set: { enabled in
            if enabled {
                store.updateEnvironmentOverride(
                    for: container.id,
                    key: option.environmentKey,
                    value: option.enabledValue
                )
            } else if option.isEnabled(in: liveContainer.environmentOverrides) {
                store.removeEnvironmentOverride(
                    for: container.id,
                    key: option.environmentKey
                )
            }
        }
    }

    private func select(_ section: ContainerSettingsSection) {
        guard selectedSection != section else { return }
        if reduceMotion {
            selectedSection = section
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                selectedSection = section
            }
        }
    }

    private func appearanceEditingChanged(_ isEditing: Bool) {
        isEditingAppearance = isEditing
        if !isEditing {
            store.updateSessionAppearance(for: container.id, to: appearanceDraft)
        }
    }

    private func chooseBackground() {
        guard !isChangingBackground else { return }
        isChangingBackground = true
        Task {
            await store.chooseSessionBackgroundImage(for: container.id)
            appearanceDraft = storedAppearance
            isChangingBackground = false
        }
    }

    private func removeBackground() {
        guard !isChangingBackground else { return }
        isChangingBackground = true
        Task {
            await store.removeSessionBackgroundImage(for: container.id)
            appearanceDraft = storedAppearance
            isChangingBackground = false
        }
    }
}

private enum ContainerSettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case general
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance:
            localizedSettings("Appearance")
        case .general:
            localizedSettings("General")
        case .advanced:
            localizedSettings("Advanced")
        }
    }

    var subtitle: String {
        switch self {
        case .appearance:
            localizedSettings("Shape the session workspace around this container.")
        case .general:
            localizedSettings("Manage launch, display, sign-in, and storage.")
        case .advanced:
            localizedSettings("Adjust compatibility and diagnostic options.")
        }
    }

    var systemImage: String {
        switch self {
        case .appearance:
            "paintbrush.pointed"
        case .general:
            "switch.2"
        case .advanced:
            "waveform.path.ecg.rectangle"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardPanel()
    }
}

private struct SessionAppearancePreview: View {
    let containerName: String
    let imageURL: URL?
    let appearance: ContainerSessionAppearance

    @State private var image: SettingsPreviewImage?
    @State private var imageLoader = LatestAsyncValueLoader<URL?>()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: appearance.blurRadius)
                    .scaleEffect(appearance.blurRadius > 0 ? 1.08 : 1)

                Color.black.opacity(appearance.dimOpacity)

                previewChrome
                    .padding(max(12, proxy.size.width * 0.035))
            }
            .clipped()
            .background(Color.black.opacity(0.65))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
        }
        .task(id: imageURL) {
            let requestedURL = imageURL
            await imageLoader.load(
                request: requestedURL,
                operation: { url in
                    await SettingsPreviewImageLoader.load(from: url)
                },
                isCurrent: { url in
                    url == imageURL
                },
                publish: { loadedImage in
                    image = loadedImage
                }
            )
        }
    }

    @ViewBuilder
    private var background: some View {
        if let image {
            Image(decorative: image.image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.015, green: 0.035, blue: 0.075),
                        Color(red: 0.015, green: 0.12, blue: 0.24),
                        Color(red: 0.025, green: 0.045, blue: 0.11)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.blue.opacity(0.42))
                    .frame(width: 220, height: 220)
                    .blur(radius: 55)
                    .offset(x: 120, y: 70)

                Circle()
                    .fill(Color.indigo.opacity(0.32))
                    .frame(width: 170, height: 170)
                    .blur(radius: 48)
                    .offset(x: -140, y: -65)
            }
        }
    }

    private var previewChrome: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text(containerName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    PreviewWindow(isSelected: true)
                    PreviewWindow(isSelected: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PreviewInspector()
                    .frame(width: 64)
            }

            HStack(spacing: 8) {
                PreviewDockIcon(systemImage: "square.grid.3x3.fill", isRunning: true)
                PreviewDockIcon(systemImage: "gamecontroller.fill", isRunning: true)
                PreviewDockIcon(systemImage: "plus", isRunning: false)
                Spacer()
                Circle()
                    .fill(.green.opacity(0.8))
                    .frame(width: 5, height: 5)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(0.1))
            }
        }
    }

}

private struct PreviewWindow: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.black.opacity(0.52))
            .overlay(alignment: .top) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.48))
                        .frame(width: 8, height: 8)
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .frame(width: 34, height: 3)
                    Spacer()
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 5, height: 5)
                }
                .padding(7)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.blue : Color.white.opacity(0.1),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .shadow(color: isSelected ? Color.blue.opacity(0.38) : .clear, radius: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1.42, contentMode: .fit)
    }
}

private struct PreviewInspector: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Circle()
                    .fill(.green)
                    .frame(width: 4, height: 4)
                Capsule()
                    .fill(.white.opacity(0.48))
                    .frame(width: 24, height: 3)
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 4
            ) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == 0 ? Color.blue.opacity(0.34) : .white.opacity(0.08))
                        .frame(height: 17)
                }
            }

            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(.white.opacity(0.09))
                        .frame(height: 8)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(7)
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.1))
        }
        .accessibilityHidden(true)
    }
}

private struct SettingsPreviewImage: @unchecked Sendable {
    let image: CGImage
}

private enum SettingsPreviewImageLoader {
    static func load(from url: URL?) async -> SettingsPreviewImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            return SettingsPreviewImage(image: image)
        }.value
    }
}

private struct PreviewDockIcon: View {
    let systemImage: String
    let isRunning: Bool

    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white.opacity(0.13))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }

            Capsule()
                .fill(isRunning ? Color.blue : Color.clear)
                .frame(width: 8, height: 2)
        }
    }
}

private struct AppearanceSliderRow: View {
    let title: String
    let valueLabel: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(valueLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: $value,
                in: range,
                step: step,
                onEditingChanged: onEditingChanged
            )
            .accessibilityValue(valueLabel)
        }
    }
}

private struct AdvancedToggleRow: View {
    let title: String
    let description: String
    let systemImage: String
    let badge: String
    let isEnabled: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))

                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isEnabled ? Color.blue : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (isEnabled ? Color.blue : Color.secondary)
                                .opacity(0.12),
                            in: Capsule()
                        )
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .accessibilityLabel(title)
                .disabled(!isEnabled)
        }
        .padding(.vertical, 13)
        .opacity(isEnabled ? 1 : 0.62)
    }
}

private struct AdvancedFrameRateRow: View {
    let title: String
    let description: String
    let badge: String
    let isEnabled: Bool
    let values: [String]
    @Binding var selection: String
    let label: (String) -> String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "speedometer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))

                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isEnabled ? Color.blue : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (isEnabled ? Color.blue : Color.secondary)
                                .opacity(0.12),
                            in: Capsule()
                        )
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker(title, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text(label(value))
                        .tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .disabled(!isEnabled)
            .accessibilityLabel(title)
        }
        .padding(.vertical, 13)
        .opacity(isEnabled ? 1 : 0.62)
    }
}

private struct ContainerNameField: View {
    @EnvironmentObject private var store: AppStore
    let containerID: UUID

    @FocusState private var isFocused: Bool
    @State private var draft = ""
    @State private var isCommitting = false

    var body: some View {
        TextField(localizedSettings("Name"), text: $draft)
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
            .help(
                localizedSettings(
                    "Press Return or leave the field to rename the container and its folder"
                )
            )
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

private struct LaunchArgumentsField: View {
    @EnvironmentObject private var store: AppStore
    let containerID: UUID

    @FocusState private var isFocused: Bool
    @State private var draft = ""

    var body: some View {
        TextField(localizedSettings("Optional launch arguments"), text: draftBinding)
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
            store.updateExecutableArguments(
                for: containerID,
                to: LaunchArgumentParser.parse(commandLine)
            )
        }
    }

    private var storedArguments: [String] {
        store.containers.first(where: { $0.id == containerID })?.executableArguments ?? []
    }

    private var formattedStoredArguments: String {
        LaunchArgumentParser.format(storedArguments)
    }
}

private struct LoginCallbackSettingsContent: View {
    @EnvironmentObject private var store: AppStore
    let container: Container

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                store.recoverCopiedLoginCallback(in: container.id)
            } label: {
                Label(
                    localizedSettings("Recover Copied Callback"),
                    systemImage: "link.badge.plus"
                )
            }
            .disabled(store.isRecoveringLoginCallback(in: container.id))
            .help(
                localizedSettings(
                    "If Safari says the address is invalid after signing in, press Command-L and Command-C in Safari, then recover the copied callback here."
                )
            )

            if let state = store.loginCallbackRecoveryState(for: container.id) {
                Label(state.message, systemImage: statusImage(for: state))
                    .font(.callout)
                    .foregroundStyle(statusStyle(for: state))
                    .fixedSize(horizontal: false, vertical: true)

                if case let .choosing(_, candidates) = state {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(candidates, id: \.self) { candidate in
                            Button {
                                store.chooseLoginCallbackTarget(candidate, in: container.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(executableName(candidate))
                                    Text(candidate)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(localizedSettings("Cancel")) {
                            store.cancelLoginCallbackTargetSelection(in: container.id)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func statusImage(for state: LoginCallbackRecoveryState) -> String {
        switch state {
        case .inspecting, .choosing, .forwarding:
            "arrow.triangle.2.circlepath"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private func statusStyle(for state: LoginCallbackRecoveryState) -> AnyShapeStyle {
        switch state {
        case .inspecting, .choosing, .forwarding:
            AnyShapeStyle(.secondary)
        case .succeeded:
            AnyShapeStyle(.green)
        case .failed:
            AnyShapeStyle(.red)
        }
    }

    private func executableName(_ windowsPath: String) -> String {
        windowsPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? windowsPath
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
                Text(localizedSettings("No environment overrides."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(overrides, id: \.key) { override in
                    HStack {
                        Text(override.key)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 170, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        TextField(
                            localizedSettings("Value"),
                            text: valueBinding(for: override.key)
                        )
                        .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            store.removeEnvironmentOverride(for: containerID, key: override.key)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(localizedSettings("Remove Variable"))
                    }
                }
            }

            Divider()

            HStack {
                TextField(localizedSettings("Variable"), text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 170)

                TextField(localizedSettings("Value"), text: $newValue)
                    .textFieldStyle(.roundedBorder)

                Button {
                    store.addEnvironmentOverride(
                        for: containerID,
                        key: newKey,
                        value: newValue
                    )
                    newKey = ""
                    newValue = ""
                } label: {
                    Label(localizedSettings("Add"), systemImage: "plus")
                }
                .disabled(
                    !EnvironmentOverridePolicy.isAllowedKey(
                        newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
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

private func localizedSettings(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: SwitchyardStrings.bundle)
}
