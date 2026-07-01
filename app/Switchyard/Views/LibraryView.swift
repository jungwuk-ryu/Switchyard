import AppCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                RuntimeStatusStrip()
                    .padding()

                Divider()

                Table(store.launchers) {
                    TableColumn("Name") { launcher in
                        Button {
                            store.selectedLauncherID = launcher.id
                        } label: {
                            Text(launcher.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }

                    TableColumn("Type") { launcher in
                        Text(launcher.kind.displayName)
                    }

                    TableColumn("Bottle") { launcher in
                        Text(store.bottles.first(where: { $0.id == launcher.bottleID })?.name ?? "Missing")
                    }

                    TableColumn("Last Run") { launcher in
                        if let lastRun = launcher.lastRun {
                            Text(switchyardDateFormatter.string(from: lastRun))
                        } else {
                            Text("Never")
                                .foregroundStyle(.secondary)
                        }
                    }

                    TableColumn("Status") { launcher in
                        StatusBadge(status: launcher.status.health, label: launcher.status.label)
                    }

                    TableColumn("Action") { launcher in
                        Button("Run") {
                            store.selectedLauncherID = launcher.id
                            store.runSelectedLauncher()
                        }
                    }
                }
                .padding()
            }
            .frame(minWidth: 680)

            if store.showInspector {
                InspectorView()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .navigationTitle("Games & Launchers")
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

private struct InspectorView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let launcher = store.selectedLauncher, let bottle = store.selectedBottle {
                Text(launcher.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                LabeledContent("Type", value: launcher.kind.displayName)
                LabeledContent("Bottle", value: bottle.path)
                LabeledContent("Wine Build", value: bottle.wineBuildID)
                LabeledContent("Patchset", value: bottle.patchsetID)

                Divider()

                DisclosureGroup("Launch Arguments") {
                    Text(launcher.executablePath ?? "Executable has not been configured.")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }

                DisclosureGroup("Environment") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("WINEPREFIX=\(bottle.path)")
                        Text("SWITCHYARD_GPTK_PATH=\(store.gptkPath.isEmpty ? "not set" : store.gptkPath)")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                Spacer()

                Button("Repair Bottle") {
                    store.refreshRuntimeStatus()
                }
            } else {
                Text("Select a launcher to inspect its runtime settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Inspector")
    }
}
