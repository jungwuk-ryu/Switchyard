import AppCore
import Foundation
import SwiftUI

struct LauncherInstallerSection: View {
    let container: Container

    private let columns = [
        GridItem(.flexible(minimum: 250), spacing: 14),
        GridItem(.flexible(minimum: 250), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(
                    String(
                        localized: "Game Launchers",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                    .font(.headline)
                Text(
                    String(
                        localized: "Choose a launcher and Switchyard will securely download its official Windows installer, open it here, and detect when setup finishes.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(StarterApplicationCatalog.all) { application in
                    LauncherInstallerCard(
                        container: container,
                        application: application
                    )
                }
            }

            Label(
                String(
                    localized: "Installers come directly from each publisher, are verified before use, and stay in Switchyard's private cache. Publisher terms appear in the Windows installer.",
                    bundle: SwitchyardStrings.bundle
                ),
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardPanel()
    }
}

private struct LauncherInstallerCard: View {
    @EnvironmentObject private var store: AppStore

    let container: Container
    let application: StarterApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: application.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(application.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(application.publisherName) · \(application.installerFileExtension.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                LauncherStatusBadge(state: state)
            }

            stateDetail
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)

            if case .downloading(let receivedByteCount, let expectedByteCount) = state {
                if let expectedByteCount, expectedByteCount > 0 {
                    ProgressView(
                        value: Double(receivedByteCount),
                        total: Double(expectedByteCount)
                    )
                    .accessibilityValue(downloadProgressDescription)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                primaryAction

                Link(destination: application.officialDownloadPageURL) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help(
                    String(
                        localized: "Open the publisher's official download page",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                .accessibilityLabel(
                    String(
                        localized: "Official download page",
                        bundle: SwitchyardStrings.bundle
                    )
                )

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }

    private var state: LauncherInstallationState {
        store.launcherInstallationState(
            for: application.id,
            in: container.id
        )
    }

    private var installedProgram: InstalledProgram? {
        store.installedLauncherProgram(
            for: application.id,
            in: container.id
        )
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch state {
        case .idle:
            Text(
                String(
                    localized: "Not installed in this container.",
                    bundle: SwitchyardStrings.bundle
                )
            )
                .foregroundStyle(.secondary)
        case .downloading:
            Text(downloadProgressDescription)
                .foregroundStyle(.secondary)
        case .openingInstaller:
            Text(
                String(
                    localized: "The verified download is ready. Opening the Windows installer…",
                    bundle: SwitchyardStrings.bundle
                )
            )
                .foregroundStyle(.secondary)
        case .installerOpen:
            Text(
                String(
                    localized: "Finish the normal Windows setup. Switchyard is checking this container automatically.",
                    bundle: SwitchyardStrings.bundle
                )
            )
                .foregroundStyle(.secondary)
        case .installed:
            if let installedProgram {
                Text(
                    ContainerPathPresentation.windowsPath(
                        for: installedProgram.executablePath,
                        in: container
                    )
                )
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(
                    String(
                        localized: "Installed and ready to launch.",
                        bundle: SwitchyardStrings.bundle
                    )
                )
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .installed:
            Button {
                if let installedProgram {
                    store.runInstalledProgram(installedProgram, in: container.id)
                } else {
                    store.refreshInstalledPrograms(for: container.id)
                }
            } label: {
                if let installedProgram,
                   store.isLaunchingProgram(installedProgram, in: container.id) {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            String(
                                localized: "Starting…",
                                bundle: SwitchyardStrings.bundle
                            )
                        )
                    }
                } else {
                    Label(
                        String(localized: "Launch", bundle: SwitchyardStrings.bundle),
                        systemImage: "play.fill"
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                store.isContainerTransitioning(container.id)
                    || store.isLauncherInstallationInProgress(in: container.id)
            )
            .accessibilityIdentifier("launcher.\(application.id).launch")

        case .downloading:
            Button {
                store.cancelLauncherDownload(application.id, in: container.id)
            } label: {
                Label(
                    String(
                        localized: "Cancel Download",
                        bundle: SwitchyardStrings.bundle
                    ),
                    systemImage: "xmark"
                )
            }
            .accessibilityIdentifier("launcher.\(application.id).cancel")

        case .openingInstaller:
            Button {} label: {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        String(
                            localized: "Opening…",
                            bundle: SwitchyardStrings.bundle
                        )
                    )
                }
            }
            .disabled(true)

        case .installerOpen:
            Button {} label: {
                Label(
                    String(
                        localized: "Finish in Installer",
                        bundle: SwitchyardStrings.bundle
                    ),
                    systemImage: "hourglass"
                )
            }
            .disabled(true)

        case .idle, .failed:
            Button {
                store.installLauncher(application.id, in: container.id)
            } label: {
                Label(
                    String(
                        localized: "Download & Install",
                        bundle: SwitchyardStrings.bundle
                    ),
                    systemImage: "arrow.down.circle.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                store.isContainerTransitioning(container.id)
                    || store.isLauncherInstallationInProgress(in: container.id)
                    || store.isLauncherInstallationInProgress(for: application.id)
            )
            .accessibilityIdentifier("launcher.\(application.id).install")
        }
    }

    private var downloadProgressDescription: String {
        guard case .downloading(let receivedByteCount, let expectedByteCount) = state else {
            return ""
        }
        let received = ByteCountFormatter.string(
            fromByteCount: receivedByteCount,
            countStyle: .file
        )
        guard let expectedByteCount, expectedByteCount > 0 else {
            return String(
                localized: "Downloading \(application.displayName)… \(received)",
                bundle: SwitchyardStrings.bundle
            )
        }
        let expected = ByteCountFormatter.string(
            fromByteCount: expectedByteCount,
            countStyle: .file
        )
        return String(
            localized: "Downloading \(application.displayName)… \(received) of \(expected)",
            bundle: SwitchyardStrings.bundle
        )
    }
}

private struct LauncherStatusBadge: View {
    let state: LauncherInstallationState

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: Capsule())
            .accessibilityLabel(title)
    }

    private var title: String {
        switch state {
        case .idle:
            String(localized: "Not Installed", bundle: SwitchyardStrings.bundle)
        case .downloading:
            String(localized: "Downloading", bundle: SwitchyardStrings.bundle)
        case .openingInstaller:
            String(localized: "Opening", bundle: SwitchyardStrings.bundle)
        case .installerOpen:
            String(localized: "Installing", bundle: SwitchyardStrings.bundle)
        case .installed:
            String(localized: "Installed", bundle: SwitchyardStrings.bundle)
        case .failed:
            String(localized: "Needs Attention", bundle: SwitchyardStrings.bundle)
        }
    }

    private var systemImage: String {
        switch state {
        case .idle:
            "circle"
        case .downloading:
            "arrow.down.circle.fill"
        case .openingInstaller:
            "play.circle.fill"
        case .installerOpen:
            "hourglass.circle.fill"
        case .installed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .idle:
            .secondary
        case .downloading, .openingInstaller:
            .blue
        case .installerOpen:
            .orange
        case .installed:
            .green
        case .failed:
            .red
        }
    }
}
