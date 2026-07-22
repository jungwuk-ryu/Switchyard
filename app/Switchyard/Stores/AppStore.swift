import AppCore
import AppKit
import Foundation
import JobEngine
import Persistence
import RuntimeCatalog
import SwiftUI
import UniformTypeIdentifiers

private struct RuntimeRefreshResult {
    var resolvedWinePath: String
    var status: RuntimeStatus
    var diagnostics: [DiagnosticCheck]
}

private enum LoginCallbackRecoveryError: LocalizedError {
    case noRunningApplication
    case containerStorageChanging

    var errorDescription: String? {
        switch self {
        case .noRunningApplication:
            "Keep the Windows game open while recovering its copied login callback."
        case .containerStorageChanging:
            "Wait for the container folder operation to finish before recovering a login callback."
        }
    }
}

private struct PendingLoginCallbackRecovery {
    var rawURL: String
    var winePath: String
    var candidates: [String]
}

private let debugRunLogRetentionInterval: TimeInterval = 14 * 24 * 60 * 60
private let maximumRetainedDebugRunLogs = 50
private let maximumLiveLogLines = 5_000
private let recentProgramLaunchesDefaultsKey = "recentProgramLaunches.v1"
private let maximumRecentProgramLaunches = 8
private let onlineReleaseCacheInterval: TimeInterval = 15 * 60

private struct SwitchyardWineSourcePolicy {
    var revision: String
    var revisionTimestamp: UInt64?
    var releaseManifestURL: URL?
    var developerTeamID: String
    var archiveSha256: String
    var archiveSize: UInt64?
    var notarizationID: String

    var publishedRuntimePolicy: PublishedRuntimePolicy? {
        guard !revision.isEmpty,
              let releaseManifestURL,
              !developerTeamID.isEmpty,
              !archiveSha256.isEmpty,
              let archiveSize,
              !notarizationID.isEmpty else {
            return nil
        }
        return PublishedRuntimePolicy(
            sourceRevision: revision,
            releaseManifestURL: releaseManifestURL,
            developerTeamID: developerTeamID,
            archiveSha256: archiveSha256,
            archiveSize: archiveSize,
            notarizationID: notarizationID
        )
    }

    var revisionDate: Date? {
        revisionTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static func load(fileManager: FileManager = .default) -> SwitchyardWineSourcePolicy {
        let bundledURL = Bundle.main.url(forResource: "switchyard-wine", withExtension: "env")
        let developmentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("config/switchyard-wine.env")
        let sourceURL = bundledURL ?? developmentURL
        let contents = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        let values = Dictionary(
            uniqueKeysWithValues: contents
                .split(whereSeparator: { $0.isNewline })
                .compactMap { line -> (String, String)? in
                    guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { return nil }
                    return (String(line[..<separator]), String(line[line.index(after: separator)...]))
                }
        )
        let unresolvedRevision = values["SWITCHYARD_WINE_REVISION"] ?? ""
        let unresolvedRevisionTimestamp = values["SWITCHYARD_WINE_REVISION_TIMESTAMP"] ?? ""
        let unresolvedManifestURL = values["SWITCHYARD_WINE_RELEASE_MANIFEST_URL"] ?? ""
        let unresolvedTeamID = values["SWITCHYARD_WINE_DEVELOPER_TEAM_ID"] ?? ""
        let unresolvedArchiveSha256 = values["SWITCHYARD_WINE_RELEASE_ARCHIVE_SHA256"] ?? ""
        let unresolvedArchiveSize = values["SWITCHYARD_WINE_RELEASE_ARCHIVE_SIZE"] ?? ""
        let unresolvedNotarizationID = values["SWITCHYARD_WINE_RELEASE_NOTARIZATION_ID"] ?? ""
        return SwitchyardWineSourcePolicy(
            revision: unresolvedRevision.hasPrefix("__") ? "" : unresolvedRevision,
            revisionTimestamp: UInt64(unresolvedRevisionTimestamp),
            releaseManifestURL: unresolvedManifestURL.hasPrefix("__")
                ? nil
                : URL(string: unresolvedManifestURL),
            developerTeamID: unresolvedTeamID.hasPrefix("__") ? "" : unresolvedTeamID,
            archiveSha256: unresolvedArchiveSha256.hasPrefix("__") ? "" : unresolvedArchiveSha256,
            archiveSize: UInt64(unresolvedArchiveSize),
            notarizationID: unresolvedNotarizationID.hasPrefix("__") ? "" : unresolvedNotarizationID
        )
    }
}

enum RuntimeInstallationState: Equatable {
    case idle
    case working
    case ready(String)
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle: nil
        case .working: "Downloading, validating, and installing the signed runtime…"
        case .ready(let message), .failed(let message): message
        }
    }
}

enum RosettaInstallationState: Equatable {
    case idle
    case working
    case ready
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

enum FontPackPreparationState: Equatable {
    case idle
    case working
    case ready
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

enum StarterApplicationInstallationState: Equatable {
    case idle
    case preparing
    case launching
    case installerStarted(UUID)
    case installed(UUID)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .preparing, .launching, .installerStarted:
            true
        case .idle, .installed, .failed:
            false
        }
    }

    var isInstallerOpen: Bool {
        if case .installerStarted = self { return true }
        return false
    }

    var containerID: UUID? {
        switch self {
        case .installerStarted(let id), .installed(let id): id
        case .idle, .preparing, .launching, .failed: nil
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedSection: SidebarSelection = .containers
    @Published var selectedSettingsTab: SettingsTab = .general
    @Published var selectedContainerID: UUID?
    @Published var hasCompletedSetup: Bool
    @Published var isSetupAssistantPresented = false
    @Published var libraryPath: String
    @Published var gptkPath: String
    @Published var winePath: String
    @Published private(set) var runtimeStatus = RuntimeStatus()
    @Published private(set) var diagnostics: [DiagnosticCheck] = []
    @Published private(set) var isRefreshingDiagnostics = false
    @Published private(set) var lastDiagnosticsRefreshDate: Date?
    @Published private(set) var onlineReleaseSnapshot: SwitchyardReleaseSnapshot?
    @Published private(set) var isCheckingOnlineReleases = false
    @Published private(set) var lastOnlineReleaseCheckDate: Date?
    @Published private(set) var onlineReleaseError: String?
    @Published private(set) var runtimeInstallationState: RuntimeInstallationState = .idle
    @Published private(set) var rosettaInstallationState: RosettaInstallationState = .idle
    @Published private(set) var fontPackPreparationState: FontPackPreparationState = .idle
    @Published private(set) var gptkSetupMessage: String?
    @Published private(set) var isImportingGPTK = false
    @Published private(set) var downloadedGPTKDiskImagePath: String?
    @Published private(set) var downloadedSteamInstallerPath: String?
    @Published private(set) var steamSetupMessage: String?
    @Published private(set) var isDownloadingSteamInstaller = false
    @Published private(set) var steamInstallationState: StarterApplicationInstallationState = .idle
    @Published private(set) var launchingContainerIDs: Set<UUID> = []
    @Published private(set) var startingPrefixContainerIDs: Set<UUID> = []
    @Published private(set) var launchingExecutablePathByContainerID: [UUID: String] = [:]
    @Published private(set) var installedProgramsByContainerID: [UUID: [InstalledProgram]] = [:]
    @Published private(set) var recentProgramLaunchesByContainerID: [UUID: [RecentProgramLaunch]] = [:]
    @Published private(set) var sessionSnapshotsByContainerID: [UUID: ContainerSessionSnapshot] = [:]
    @Published private(set) var stoppingWineServerContainerIDs: Set<UUID> = []
    @Published private(set) var containerStorageOperationIDs: Set<UUID> = []
    @Published private(set) var loginCallbackRecoveryStates: [UUID: LoginCallbackRecoveryState] = [:]
    @Published var containers: [Container]
    @Published private(set) var logLines: [LogLine] = []
    @AppStorage("developerLogging") private var developerLogging = false
    @AppStorage("verboseWineLogging") private var verboseWineLogging = false

    private let jobEngine = JobEngine()
    private let runnerClient = SwitchyardRunnerClient()
    private let protocolBridge = WineProtocolBridge()
    private let desktopShortcutBridge = WineDesktopShortcutBridge()
    private let defaults = UserDefaults.standard
    private let wineSourcePolicy = SwitchyardWineSourcePolicy.load()
    private let debugLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
    private var diagnosticsTask: Task<Void, Never>?
    private var diagnosticsRefreshID: UUID?
    private var onlineReleaseTask: Task<Void, Never>?
    private var onlineReleaseRefreshID: UUID?
    private var gptkImportTask: Task<Void, Never>?
    private var steamDownloadTask: Task<Void, Never>?
    private var installedProgramTasks: [UUID: Task<Void, Never>] = [:]
    private var starterApplicationDetectionTask: Task<Void, Never>?
    private var activeRunSessionIDsByContainerID: [UUID: Set<UUID>] = [:]
    private var userStoppedRunSessionIDs: Set<UUID> = []
    private var prefixStartupTasks: [UUID: Task<Void, Never>] = [:]
    private var prefixStartupsAwaitingInactiveTransition: Set<UUID> = []
    private var sessionRefreshTokens: [UUID: UUID] = [:]
    private var callbackRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingLoginCallbackRecoveries: [UUID: PendingLoginCallbackRecovery] = [:]
    private var protocolBridgeTask: Task<Void, Never>?
    private var lastProtocolBridgeError: String?
    private var lastDesktopShortcutBridgeError: String?

    init() {
        let defaultLibrary = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .path ?? ""

        let initialLibraryPath = defaults.string(forKey: "libraryPath") ?? defaultLibrary
        libraryPath = initialLibraryPath
        let runtimeLocator = RuntimeLocator()
        gptkPath = defaults.string(forKey: "gptkPath") ?? ""
        if let storedWinePath = defaults.string(forKey: "winePath"), !storedWinePath.isEmpty {
            let defaultWinePath = runtimeLocator.defaultWineRuntimePath()
            let preferredWinePath = runtimeLocator.preferredWineExecutablePath(
                for: storedWinePath,
                expectedSourceRevision: wineSourcePolicy.revision
            )
            winePath = storedWinePath == defaultWinePath && preferredWinePath == nil ? "" : (preferredWinePath ?? storedWinePath)
        } else {
            winePath = runtimeLocator.preferredWineExecutablePath(
                for: nil,
                expectedSourceRevision: wineSourcePolicy.revision
            ) ?? ""
        }
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")

        let snapshot = Self.initialLibrarySnapshot(libraryPath: initialLibraryPath)
        containers = snapshot.containers
        selectedContainerID = containers.first?.id
        recentProgramLaunchesByContainerID = Self.initialRecentProgramLaunches(
            defaults: defaults,
            containers: containers
        )
        downloadedSteamInstallerPath = StarterApplicationDownloader()
            .trustedCachedInstaller(for: StarterApplicationCatalog.steam)?.path

        persistLibrary()
        persistRecentProgramLaunches()
        pruneDebugRunLogs(in: debugRunLogRoot)
        startProtocolBridgeMonitoring()

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--show-setup-assistant") {
            isSetupAssistantPresented = true
        }
#endif
    }

    var selectedContainer: Container? {
        guard let selectedContainerID else { return containers.first }
        return containers.first(where: { $0.id == selectedContainerID }) ?? containers.first
    }

    private var guidedSteamContainerID: UUID? {
        containers.first(where: {
            $0.starterApplicationID == StarterApplicationCatalog.steam.id
        })?.id
    }

    var currentRuntime: RuntimeBuild {
        let locator = RuntimeLocator()
        let resolvedWinePath = locator.preferredWineExecutablePath(
            for: winePath,
            expectedSourceRevision: wineSourcePolicy.revision
        )
            ?? locator.resolveWineExecutablePath(for: winePath)
            ?? winePath
        return locator.runtimeBuild(
            for: resolvedWinePath,
            versionSourceRevision: wineSourcePolicy.revision,
            versionDate: wineSourcePolicy.revisionDate
        )
    }

    var canInstallCompatibleWineRuntime: Bool {
        wineSourcePolicy.publishedRuntimePolicy != nil
    }

    func supportsOnlineRuntimeRelease(_ release: PublishedRuntimeRelease) -> Bool {
        guard let policy = wineSourcePolicy.publishedRuntimePolicy else { return false }
        return (try? PublishedRuntimeInstaller.validate(release: release, against: policy)) != nil
    }

    private var libraryStore: LibraryManifestStore {
        LibraryManifestStore(rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true))
    }

    private var gptkImportRoot: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Runtimes", isDirectory: true)
            .appendingPathComponent("GPTK", isDirectory: true)
            .path ?? ""
    }

    private var fontCacheRoot: String {
        OpenFontPackCatalog.defaultCacheRoot().path
    }

    func persistPreferences() {
        defaults.set(libraryPath, forKey: "libraryPath")
        defaults.set(gptkPath, forKey: "gptkPath")
        defaults.set(winePath, forKey: "winePath")
        defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup")
    }

    @discardableResult
    func completeSetup() -> Bool {
        guard GuidedSetupPolicy.canComplete(with: runtimeStatus) else {
            logLines.insert(
                LogLine(
                    level: "warning",
                    source: "setup",
                    message: "Finish the remaining setup step before completing setup."
                ),
                at: 0
            )
            refreshRuntimeStatus()
            return false
        }
        hasCompletedSetup = true
        isSetupAssistantPresented = false
        persistPreferences()
        refreshRuntimeStatus()
        return true
    }

    func requestSetupAssistant() {
        isSetupAssistantPresented = true
        refreshRuntimeStatus()
    }

    func beginGuidedSetup() {
        refreshRuntimeStatus()
        ensureOpenFontPack()
    }

    func installRosetta(licenseNoticeAccepted: Bool = false) {
        guard !rosettaInstallationState.isWorking else { return }
        guard runtimeStatus.architecture == .ok else {
            rosettaInstallationState = .failed("Rosetta 2 can only be installed on an Apple Silicon Mac.")
            return
        }
        guard licenseNoticeAccepted || confirmRosettaLicenseNotice() else { return }

        rosettaInstallationState = .working
        Task {
            do {
                try await RosettaInstaller().install()
                rosettaInstallationState = .ready
                refreshRuntimeStatus()
            } catch {
                let message = Self.errorDescription(error)
                rosettaInstallationState = .failed(message)
                logLines.insert(
                    LogLine(level: "warning", source: "setup", message: message),
                    at: 0
                )
            }
        }
    }

    private func confirmRosettaLicenseNotice() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install Rosetta 2?"
        alert.informativeText = "Switchyard will open Apple's Rosetta installer. Continuing accepts Apple's Rosetta software license; macOS handles any approval that is required."
        alert.addButton(withTitle: "Accept and Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func installCompatibleWineRuntimeIfNeeded() {
        guard runtimeStatus.wine != .ok || runtimeStatus.patchset != .ok else { return }
        guard !runtimeInstallationState.isWorking else { return }
        installCompatibleWineRuntime()
    }

    func installCompatibleWineRuntime() {
        guard !runtimeInstallationState.isWorking else { return }
        guard !hasRunningContainers else {
            runtimeInstallationState = .failed("Stop all running containers before changing the selected runtime.")
            return
        }
        guard let policy = wineSourcePolicy.publishedRuntimePolicy else {
            runtimeInstallationState = .failed("This app build does not contain a published runtime channel.")
            return
        }

        runtimeInstallationState = .working
        Task {
            do {
                let result = try await PublishedRuntimeInstaller().install(policy: policy)
                winePath = result.winePath
                persistPreferences()
                let installedRuntime = RuntimeLocator().runtimeBuild(
                    for: result.winePath,
                    versionSourceRevision: wineSourcePolicy.revision,
                    versionDate: wineSourcePolicy.revisionDate
                )
                let runtimeName = installedRuntime.buildNumber.map { "Build \($0)" }
                    ?? result.runtimeID
                let message = "Installed compatible runtime \(runtimeName)."
                runtimeInstallationState = .ready(message)
                logLines.insert(
                    LogLine(
                        level: "info",
                        source: "runtime",
                        message: "\(message) Source \(result.sourceRevision.prefix(12))."
                    ),
                    at: 0
                )
                refreshRuntimeStatus()
            } catch {
                let message = "Could not install the compatible runtime: \(error.localizedDescription)"
                runtimeInstallationState = .failed(message)
                logLines.insert(LogLine(level: "warning", source: "runtime", message: message), at: 0)
            }
        }
    }

    func openGPTKDownloadPage() {
        guard let url = URL(string: "https://developer.apple.com/download/all/?q=game+porting+toolkit") else { return }
        if NSWorkspace.shared.open(url) {
            gptkSetupMessage = "Download the newest Game Porting Toolkit disk image, then return to Switchyard."
        } else {
            gptkSetupMessage = "Could not open the Apple Developer download page."
        }
    }

    func importLatestDownloadedGPTK() {
        guard !isImportingGPTK else { return }
        refreshDownloadedInstallers()
        guard let downloadedPath = downloadedGPTKDiskImagePath else {
            gptkSetupMessage = "No Game Porting Toolkit disk image was found in Downloads."
            return
        }
        importGPTKDiskImage(at: downloadedPath)
    }

    func chooseGPTKDiskImageAndImport() {
        guard !isImportingGPTK else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Game Porting Toolkit"
        panel.message = "Choose the Game Porting Toolkit .dmg file you downloaded from Apple."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        if let diskImageType = UTType(filenameExtension: "dmg") {
            panel.allowedContentTypes = [diskImageType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        gptkPath = url.path
        persistPreferences()
        importGPTKDiskImage(at: url.path)
    }

    func importSelectedGPTKDiskImage() {
        guard !isImportingGPTK else { return }
        let selectedPath = gptkPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: selectedPath).pathExtension.lowercased() == "dmg" else {
            gptkSetupMessage = "Choose a GPTK disk image before importing."
            return
        }
        importGPTKDiskImage(at: selectedPath)
    }

    private func importGPTKDiskImage(at downloadedPath: String) {
        guard !hasRunningContainers else {
            gptkSetupMessage = "Stop all running containers before importing a toolkit."
            return
        }
        isImportingGPTK = true
        gptkSetupMessage = "Found \(URL(fileURLWithPath: downloadedPath).lastPathComponent); importing it into the local cache…"
        let importRoot = gptkImportRoot
        gptkImportTask = Task {
            let result: (path: String?, error: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    let path = try RuntimeLocator().importGPTKDiskImage(at: downloadedPath, to: importRoot)
                    return (path, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value

            isImportingGPTK = false
            if let importedPath = result.path {
                gptkPath = importedPath
                persistPreferences()
                gptkSetupMessage = "Imported Apple-signed GPTK code into Switchyard's local cache."
                logLines.insert(LogLine(level: "info", source: "runtime", message: gptkSetupMessage ?? "GPTK import completed."), at: 0)
                refreshRuntimeStatus()
            } else {
                let message = "Could not import GPTK disk image: \(result.error ?? "Unknown error")"
                gptkSetupMessage = message
                logLines.insert(LogLine(level: "warning", source: "runtime", message: message), at: 0)
            }
            gptkImportTask = nil
        }
    }

    func refreshDownloadedInstallers() {
        let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        downloadedGPTKDiskImagePath = RuntimeLocator().latestDownloadedGPTKDiskImage(
            in: downloadsDirectory
        )
    }

    func downloadSteamInstaller() {
        guard !isDownloadingSteamInstaller else { return }
        let starter = StarterApplicationCatalog.steam
        steamDownloadTask?.cancel()
        downloadedSteamInstallerPath = nil
        isDownloadingSteamInstaller = true
        steamSetupMessage = "Downloading the Windows installer securely from Valve…"

        steamDownloadTask = Task {
            do {
                let installerURL = try await StarterApplicationDownloader().download(starter)
                guard !Task.isCancelled else { return }
                downloadedSteamInstallerPath = installerURL.path
                isDownloadingSteamInstaller = false
                if case .failed = steamInstallationState {
                    steamInstallationState = .idle
                }
                steamSetupMessage = "The verified Valve download is ready to install."
            } catch {
                guard !Task.isCancelled else { return }
                isDownloadingSteamInstaller = false
                let message = Self.errorDescription(error)
                steamInstallationState = .failed(message)
                steamSetupMessage = message
            }
            steamDownloadTask = nil
        }
    }

    func cancelSteamDownloadWait() {
        steamDownloadTask?.cancel()
        steamDownloadTask = nil
        isDownloadingSteamInstaller = false
        if downloadedSteamInstallerPath == nil {
            steamSetupMessage = "Steam setup is paused. You can resume it whenever you are ready."
        }
    }

    func continueSteamSetup() {
        if downloadedSteamInstallerPath == nil {
            downloadedSteamInstallerPath = StarterApplicationDownloader()
                .trustedCachedInstaller(for: StarterApplicationCatalog.steam)?.path
        }
        if downloadedSteamInstallerPath == nil {
            downloadSteamInstaller()
        } else {
            installSteam()
        }
    }

    func installSteam() {
        guard !steamInstallationState.isWorking else { return }
        guard runtimeStatus.canLaunch else {
            steamInstallationState = .failed("Finish Switchyard setup before installing Steam.")
            requestSetupAssistant()
            return
        }

        if downloadedSteamInstallerPath == nil
            || !FileManager.default.fileExists(atPath: downloadedSteamInstallerPath ?? "") {
            downloadedSteamInstallerPath = StarterApplicationDownloader()
                .trustedCachedInstaller(for: StarterApplicationCatalog.steam)?.path
        }
        guard let installerPath = downloadedSteamInstallerPath else {
            downloadSteamInstaller()
            return
        }

        let installerURL = URL(fileURLWithPath: installerPath)
        guard StarterApplicationDownloader()
            .trustedCachedInstaller(for: StarterApplicationCatalog.steam)?
            .standardizedFileURL == installerURL.standardizedFileURL else {
            downloadedSteamInstallerPath = nil
            steamInstallationState = .failed("The cached Steam installer changed or could not be verified. Download it again from Valve.")
            return
        }

        if let guidedSteamContainerID, isContainerBusy(guidedSteamContainerID) {
            steamInstallationState = .failed("Wait for the current Steam setup to finish, or stop it before trying again.")
            return
        }

        steamInstallationState = .preparing
        isDownloadingSteamInstaller = false
        let containerID: UUID
        if let guidedSteamContainerID,
           containers.contains(where: { $0.id == guidedSteamContainerID }) {
            containerID = guidedSteamContainerID
        } else {
            containerID = addContainer(
                named: StarterApplicationCatalog.steam.displayName,
                starterApplicationID: StarterApplicationCatalog.steam.id
            )
        }
        selectedContainerID = containerID
        selectedSection = .containers
        steamInstallationState = .launching

        Task {
            await runContainer(
                containerID: containerID,
                executablePath: installerURL.path,
                executableArguments: []
            )
            if containers.first(where: { $0.id == containerID })?.status == .running {
                steamInstallationState = .installerStarted(containerID)
                steamSetupMessage = "The Steam installer is open. Follow its steps to finish installation."
                monitorSteamInstallation(in: containerID)
            } else {
                steamInstallationState = .failed("The Steam installer could not be opened. Check Logs for details, then try again.")
            }
        }
    }

    func cancelSteamInstallation() {
        guard case .installerStarted(let containerID) = steamInstallationState else { return }
        starterApplicationDetectionTask?.cancel()
        starterApplicationDetectionTask = nil
        Task {
            await stopWineServer(in: containerID)
            steamInstallationState = .failed(
                "Steam setup was paused. Continue whenever you are ready; Switchyard will reuse this container."
            )
            steamSetupMessage = "Steam setup is paused and can be continued safely."
        }
    }

    func refreshRuntimeStatus() {
        persistPreferences()
        diagnosticsTask?.cancel()

        let refreshID = UUID()
        diagnosticsRefreshID = refreshID
        isRefreshingDiagnostics = true

        let gptkPath = gptkPath
        let winePath = winePath
        let expectedWineSourceRevision = wineSourcePolicy.revision
        let fontCacheRoot = fontCacheRoot
        diagnosticsTask = Task { [gptkPath, winePath, expectedWineSourceRevision, fontCacheRoot] in
            let result = await Task.detached(priority: .userInitiated) {
                let locator = RuntimeLocator()
                let resolvedWinePath = locator.preferredWineExecutablePath(
                    for: winePath,
                    expectedSourceRevision: expectedWineSourceRevision
                )
                    ?? locator.resolveWineExecutablePath(for: winePath)
                    ?? winePath

                let diagnosed = locator.diagnose(
                    gptkPath: gptkPath,
                    winePath: resolvedWinePath,
                    expectedSourceRevision: expectedWineSourceRevision,
                    fontCachePath: fontCacheRoot
                )
                return RuntimeRefreshResult(
                    resolvedWinePath: resolvedWinePath,
                    status: diagnosed.0,
                    diagnostics: diagnosed.1
                )
            }.value

            guard !Task.isCancelled, self.diagnosticsRefreshID == refreshID else { return }
            if !result.resolvedWinePath.isEmpty,
               result.resolvedWinePath != winePath,
               self.winePath == winePath {
                self.winePath = result.resolvedWinePath
                persistPreferences()
                logLines.insert(LogLine(level: "info", source: "runtime", message: "Resolved Wine selection to executable: \(result.resolvedWinePath)"), at: 0)
            }
            runtimeStatus = result.status
            diagnostics = result.diagnostics
            lastDiagnosticsRefreshDate = Date()
            isRefreshingDiagnostics = false
            diagnosticsRefreshID = nil
            diagnosticsTask = nil
        }
    }

    func refreshDiagnosticsAndUpdates() {
        refreshRuntimeStatus()
        refreshOnlineReleaseStatus(force: true)
    }

    func refreshOnlineReleaseStatus(force: Bool = false) {
        guard !isCheckingOnlineReleases else { return }
        if !force,
           let lastOnlineReleaseCheckDate,
           Date().timeIntervalSince(lastOnlineReleaseCheckDate) < onlineReleaseCacheInterval {
            return
        }

        onlineReleaseTask?.cancel()
        let refreshID = UUID()
        onlineReleaseRefreshID = refreshID
        isCheckingOnlineReleases = true
        onlineReleaseError = nil

        let catalog = OnlineReleaseCatalog()
        onlineReleaseTask = Task {
            do {
                let snapshot = try await catalog.latestReleases()
                guard !Task.isCancelled, onlineReleaseRefreshID == refreshID else { return }
                onlineReleaseSnapshot = snapshot
                lastOnlineReleaseCheckDate = Date()
                isCheckingOnlineReleases = false
                onlineReleaseRefreshID = nil
                onlineReleaseTask = nil
            } catch {
                guard !Task.isCancelled, onlineReleaseRefreshID == refreshID else { return }
                onlineReleaseError = Self.errorDescription(error)
                lastOnlineReleaseCheckDate = Date()
                isCheckingOnlineReleases = false
                onlineReleaseRefreshID = nil
                onlineReleaseTask = nil
            }
        }
    }

    func ensureOpenFontPack() {
        guard !fontPackPreparationState.isWorking else { return }
        fontPackPreparationState = .working
        let fontCacheRoot = fontCacheRoot
        Task {
            let result: (message: String?, error: String?) = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try await OpenFontPackDownloader().ensureFontPack(
                        in: URL(fileURLWithPath: fontCacheRoot, isDirectory: true)
                    )
                    return ("\(result.summary) Notices: \(result.noticePath)", nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value

            if let message = result.message {
                fontPackPreparationState = .ready
                logLines.insert(LogLine(level: "info", source: "fonts", message: message), at: 0)
            } else {
                let message = "Could not prepare Open Font Pack: \(result.error ?? "Unknown error")"
                fontPackPreparationState = .failed(message)
                logLines.insert(LogLine(level: "warning", source: "fonts", message: message), at: 0)
            }
            refreshRuntimeStatus()
        }
    }

    func addContainer() {
        _ = addContainer(named: "New Container")
    }

    @discardableResult
    func addContainer(
        named requestedName: String,
        starterApplicationID: String? = nil
    ) -> UUID {
        let name = nextContainerName(baseName: requestedName)
        let libraryURL = URL(fileURLWithPath: libraryPath, isDirectory: true)
        let pathComponent = ContainerPathPolicy.uniqueDirectoryName(
            for: name,
            existingDirectoryNames: occupiedContainerDirectoryNames(in: libraryURL)
        )
        let container = Container(
            name: name,
            path: libraryURL.appendingPathComponent(pathComponent, isDirectory: true).path,
            wineBuildID: currentRuntime.id,
            patchsetID: currentRuntime.patchsetID,
            gptkFingerprint: runtimeStatus.gptkFingerprint,
            starterApplicationID: starterApplicationID
        )
        containers.append(container)
        selectedContainerID = container.id
        selectedSection = .containers
        persistLibrary()
        return container.id
    }

    func runSelectedContainer() {
        guard let containerID = selectedContainer?.id else { return }

        Task {
            await runSelectedContainer(containerID: containerID)
        }
    }

    func runContainer(_ containerID: UUID) {
        selectedContainerID = containerID
        runSelectedContainer()
    }

    func recoverCopiedLoginCallbackForSelectedContainer() {
        guard let containerID = selectedContainer?.id else { return }
        recoverCopiedLoginCallback(in: containerID)
    }

    func recoverCopiedLoginCallback(in containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerTransitioning(containerID) else {
            recordLoginCallbackRecoveryFailure(
                LoginCallbackRecoveryError.containerStorageChanging,
                containerID: containerID
            )
            return
        }
        if isRecoveringLoginCallback(in: containerID) { return }

        guard let rawURL = NSPasteboard.general.string(forType: .string),
              !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = "Copy the invalid callback address from Safari before recovering it."
            loginCallbackRecoveryStates[containerID] = .failed(message: message)
            logLines.insert(LogLine(level: "warning", source: "protocols", message: message), at: 0)
            return
        }

        guard let scheme = WineProtocolAssociationFormat.scheme(
            inRawURL: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            let message = WineProtocolBridgeError.invalidCallbackURL.localizedDescription
            loginCallbackRecoveryStates[containerID] = .failed(message: message)
            logLines.insert(LogLine(level: "warning", source: "protocols", message: message), at: 0)
            return
        }

        let winePath = currentRuntime.winePath
        if protocolBridge.hasRegisteredScheme(scheme, in: container) {
            do {
                try deliverLoginCallback(
                    rawURL: rawURL,
                    containerID: containerID,
                    winePath: winePath,
                    handlerExecutablePath: nil
                )
            } catch {
                recordLoginCallbackRecoveryFailure(error, containerID: containerID)
            }
            return
        }

        let prefixPath = container.path
        let runnerClient = runnerClient
        loginCallbackRecoveryStates[containerID] = .inspecting(scheme: scheme)
        callbackRecoveryTasks[containerID]?.cancel()
        callbackRecoveryTasks[containerID] = Task { [weak self] in
            defer { self?.callbackRecoveryTasks.removeValue(forKey: containerID) }
            do {
                let runningExecutables = try await Task.detached(priority: .userInitiated) {
                    try runnerClient.runningWindowsExecutablePaths(
                        winePath: winePath,
                        prefixPath: prefixPath
                    )
                }.value
                try Task.checkCancellation()
                guard let self,
                      self.containers.contains(where: { $0.id == containerID }) else {
                    return
                }

                let callbackTargets = WineProtocolAssociationFormat.callbackTargetCandidates(
                    from: runningExecutables
                )
                guard let handlerExecutablePath = callbackTargets.first else {
                    throw LoginCallbackRecoveryError.noRunningApplication
                }
                if callbackTargets.count > 1 {
                    self.pendingLoginCallbackRecoveries[containerID] = PendingLoginCallbackRecovery(
                        rawURL: rawURL,
                        winePath: winePath,
                        candidates: callbackTargets
                    )
                    self.loginCallbackRecoveryStates[containerID] = .choosing(
                        scheme: scheme,
                        candidates: callbackTargets
                    )
                    return
                }
                try self.deliverLoginCallback(
                    rawURL: rawURL,
                    containerID: containerID,
                    winePath: winePath,
                    handlerExecutablePath: handlerExecutablePath
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.recordLoginCallbackRecoveryFailure(error, containerID: containerID)
            }
        }
    }

    func chooseLoginCallbackTarget(_ executablePath: String, in containerID: UUID) {
        guard let pending = pendingLoginCallbackRecoveries[containerID],
              pending.candidates.contains(executablePath) else {
            return
        }
        do {
            try deliverLoginCallback(
                rawURL: pending.rawURL,
                containerID: containerID,
                winePath: pending.winePath,
                handlerExecutablePath: executablePath
            )
        } catch {
            recordLoginCallbackRecoveryFailure(error, containerID: containerID)
        }
    }

    func cancelLoginCallbackTargetSelection(in containerID: UUID) {
        pendingLoginCallbackRecoveries.removeValue(forKey: containerID)
        loginCallbackRecoveryStates[containerID] = .failed(message: "Login callback recovery was cancelled.")
    }

    func loginCallbackRecoveryState(for containerID: UUID) -> LoginCallbackRecoveryState? {
        loginCallbackRecoveryStates[containerID]
    }

    func learnedLoginCallbackSchemes(for containerID: UUID) -> [String] {
        protocolBridge.learnedSchemes(for: containerID)
    }

    func isRecoveringLoginCallback(in containerID: UUID) -> Bool {
        switch loginCallbackRecoveryStates[containerID] {
        case .inspecting, .choosing, .forwarding:
            true
        case .succeeded, .failed, nil:
            false
        }
    }

    private func deliverLoginCallback(
        rawURL: String,
        containerID: UUID,
        winePath: String,
        handlerExecutablePath: String?
    ) throws {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerTransitioning(containerID) else {
            throw LoginCallbackRecoveryError.containerStorageChanging
        }
        let runnerPath = try runnerClient.runnerURL().path
        let request = try protocolBridge.makeCallbackRecoveryRequest(
            rawURL: rawURL,
            containerID: containerID,
            containers: containers,
            winePath: winePath,
            runnerPath: runnerPath,
            handlerExecutablePath: handlerExecutablePath
        )
        pendingLoginCallbackRecoveries.removeValue(forKey: containerID)
        loginCallbackRecoveryStates[containerID] = .forwarding(scheme: request.scheme)

        try runnerClient.deliverURLCallback(request) { [weak self] exitCode in
            Task { @MainActor in
                guard let self,
                      self.containers.contains(where: { $0.id == containerID }) else {
                    return
                }
                guard exitCode == 0 else {
                    let message = "Wine could not accept the copied \(request.scheme): callback."
                    self.loginCallbackRecoveryStates[containerID] = .failed(message: message)
                    self.logLines.insert(
                        LogLine(level: "warning", source: "protocols", message: message),
                        at: 0
                    )
                    return
                }

                do {
                    try self.protocolBridge.commitCallbackRecovery(
                        request,
                        containerID: containerID,
                        containers: self.containers,
                        runnerPath: runnerPath
                    )
                    self.loginCallbackRecoveryStates[containerID] = .succeeded(scheme: request.scheme)
                    self.logLines.insert(
                        LogLine(
                            level: "info",
                            source: "protocols",
                            message: "Recovered the \(request.scheme): callback for \(container.name)."
                        ),
                        at: 0
                    )
                } catch {
                    let message = "The callback reached Wine, but automatic recovery could not be saved: \(Self.errorDescription(error))"
                    self.loginCallbackRecoveryStates[containerID] = .failed(message: message)
                    self.logLines.insert(
                        LogLine(level: "warning", source: "protocols", message: message),
                        at: 0
                    )
                }
            }
        }
    }

    private func recordLoginCallbackRecoveryFailure(_ error: Error, containerID: UUID) {
        pendingLoginCallbackRecoveries.removeValue(forKey: containerID)
        let message = Self.errorDescription(error)
        loginCallbackRecoveryStates[containerID] = .failed(message: message)
        logLines.insert(
            LogLine(level: "warning", source: "protocols", message: message),
            at: 0
        )
    }

    private func cancelLoginCallbackRecoveryForStorageOperation(in containerID: UUID) async {
        let recoveryTask = callbackRecoveryTasks.removeValue(forKey: containerID)
        recoveryTask?.cancel()
        await recoveryTask?.value
        pendingLoginCallbackRecoveries.removeValue(forKey: containerID)
        if isRecoveringLoginCallback(in: containerID) {
            loginCallbackRecoveryStates[containerID] = .failed(
                message: "Login callback recovery was cancelled because the container folder is changing."
            )
        }
    }

    func chooseExecutableAndRun(in containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerTransitioning(containerID) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Wait for \(container.name) to finish its current session action before starting another executable."), at: 0)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Install or Run a Windows App"
        panel.message = "Choose a Windows app or installer (.exe or .msi) to open in \(container.name)."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = WindowsApplicationFileKind.allCases.compactMap {
            UTType(filenameExtension: $0.rawValue)
        }

        let installersURL = URL(fileURLWithPath: libraryPath, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("Installers", isDirectory: true)
        if FileManager.default.fileExists(atPath: installersURL.path) {
            panel.directoryURL = installersURL
        } else {
            panel.directoryURL = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first
        }

        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }
        runWindowsApplication(at: applicationURL, in: containerID)
    }

    @discardableResult
    func runWindowsApplication(at applicationURL: URL, in containerID: UUID) -> Bool {
        guard let container = containers.first(where: { $0.id == containerID }) else {
            return false
        }

        let standardizedURL = applicationURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard WindowsApplicationFileKind.supports(standardizedURL),
              FileManager.default.fileExists(
                atPath: standardizedURL.path,
                isDirectory: &isDirectory
              ),
              !isDirectory.boolValue else {
            logLines.insert(
                LogLine(
                    level: "warning",
                    source: container.name,
                    message: "Choose an existing Windows .exe or .msi file."
                ),
                at: 0
            )
            return false
        }

        runExecutable(standardizedURL.path, in: containerID)
        return true
    }

    func runExecutable(_ executablePath: String, arguments: [String] = [], in containerID: UUID) {
        selectedContainerID = containerID

        Task {
            await runContainer(containerID: containerID, executablePath: executablePath, executableArguments: arguments)
        }
    }

    func runInstalledProgram(_ program: InstalledProgram, in containerID: UUID) {
        runExecutable(program.executablePath, in: containerID)
    }

    func installedPrograms(for containerID: UUID) -> [InstalledProgram] {
        installedProgramsByContainerID[containerID] ?? []
    }

    func recentInstalledPrograms(for containerID: UUID) -> [RecentInstalledProgram] {
        var installedProgramsByPath: [String: InstalledProgram] = [:]
        for program in installedPrograms(for: containerID) {
            installedProgramsByPath[
                URL(fileURLWithPath: program.executablePath).standardizedFileURL.path
            ] = program
        }

        return (recentProgramLaunchesByContainerID[containerID] ?? []).compactMap { launch in
            let executableURL = URL(fileURLWithPath: launch.executablePath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: executableURL.path) else { return nil }
            let program = installedProgramsByPath[executableURL.path]
                ?? InstalledProgram(
                    name: executableURL.deletingPathExtension().lastPathComponent,
                    executablePath: executableURL.path,
                    installDirectory: executableURL.deletingLastPathComponent().path,
                    source: .defaultExecutable
                )
            return RecentInstalledProgram(program: program, launchedAt: launch.launchedAt)
        }
    }

    func isContainerLaunching(_ containerID: UUID) -> Bool {
        launchingContainerIDs.contains(containerID)
            || startingPrefixContainerIDs.contains(containerID)
    }

    func isLaunchingProgram(_ program: InstalledProgram, in containerID: UUID) -> Bool {
        guard let launchingPath = launchingExecutablePathByContainerID[containerID] else {
            return false
        }
        return URL(fileURLWithPath: launchingPath).standardizedFileURL
            == URL(fileURLWithPath: program.executablePath).standardizedFileURL
    }

    func sessionSnapshot(for containerID: UUID) -> ContainerSessionSnapshot {
        sessionSnapshotsByContainerID[containerID] ?? .checking
    }

    func isStoppingWineServer(in containerID: UUID) -> Bool {
        stoppingWineServerContainerIDs.contains(containerID)
    }

    func isChangingContainerStorage(_ containerID: UUID) -> Bool {
        containerStorageOperationIDs.contains(containerID)
    }

    func isContainerTransitioning(_ containerID: UUID) -> Bool {
        isContainerLaunching(containerID)
            || isStoppingWineServer(in: containerID)
            || containerStorageOperationIDs.contains(containerID)
    }

    func stopWineServer(in containerID: UUID) async {
        guard !stoppingWineServerContainerIDs.contains(containerID),
              !isContainerLaunching(containerID),
              let container = containers.first(where: { $0.id == containerID }) else { return }

        stoppingWineServerContainerIDs.insert(containerID)
        defer { stoppingWineServerContainerIDs.remove(containerID) }

        let winePath = currentRuntime.winePath
        let prefixPath = container.path
        let runnerClient = runnerClient
        let targetedRunSessionIDs = activeRunSessionIDsByContainerID[containerID] ?? []
        userStoppedRunSessionIDs.formUnion(targetedRunSessionIDs)

        do {
            try await Task.detached(priority: .userInitiated) {
                try runnerClient.stopWineServer(winePath: winePath, prefixPath: prefixPath)
            }.value
            finishPrefixStartup(for: containerID)
            await refreshContainerSession(for: containerID)
            mark(containerID, as: .ready)
            logLines.insert(
                LogLine(
                    containerID: containerID,
                    level: "info",
                    source: container.name,
                    message: "Wine processes stopped for this container."
                ),
                at: 0
            )
        } catch {
            await refreshContainerSession(for: containerID)
            if sessionSnapshot(for: containerID).wineServerState.hasRunningProcesses {
                userStoppedRunSessionIDs.subtract(targetedRunSessionIDs)
            }
            logLines.insert(
                LogLine(
                    containerID: containerID,
                    level: "error",
                    source: container.name,
                    message: "Could not stop Wine processes: \(Self.errorDescription(error))"
                ),
                at: 0
            )
        }
    }

    func monitorContainerSession(for containerID: UUID) async {
        while !Task.isCancelled,
              containers.contains(where: { $0.id == containerID }) {
            await refreshContainerSession(for: containerID)
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    func refreshContainerSession(for containerID: UUID) async {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        let refreshToken = UUID()
        sessionRefreshTokens[containerID] = refreshToken
        if sessionSnapshotsByContainerID[containerID] == nil {
            sessionSnapshotsByContainerID[containerID] = .checking
        }

        let winePath = currentRuntime.winePath
        let prefixPath = container.path
        let runnerClient = runnerClient
        let snapshot = await Task.detached(priority: .utility) {
            switch runnerClient.prefixSessionState(winePath: winePath, prefixPath: prefixPath) {
            case .active:
                do {
                    let paths = try runnerClient.runningWindowsExecutablePaths(
                        winePath: winePath,
                        prefixPath: prefixPath
                    )
                    let processes = paths
                        .map { WindowsProcessSnapshot(executablePath: $0) }
                        .sorted { lhs, rhs in
                            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                        }
                    return ContainerSessionSnapshot(
                        wineServerState: .active,
                        processes: processes,
                        refreshedAt: Date(),
                        message: nil
                    )
                } catch {
                    return ContainerSessionSnapshot(
                        wineServerState: .active,
                        processes: [],
                        refreshedAt: Date(),
                        message: "Process details are temporarily unavailable."
                    )
                }
            case .orphaned:
                return ContainerSessionSnapshot(
                    wineServerState: .orphaned,
                    processes: [],
                    refreshedAt: Date(),
                    message: "Wine processes remain after wineserver exited. Stop this session before changing its folder."
                )
            case .inactive:
                return ContainerSessionSnapshot(
                    wineServerState: .inactive,
                    processes: [],
                    refreshedAt: Date(),
                    message: nil
                )
            case .unavailable:
                return ContainerSessionSnapshot(
                    wineServerState: .unavailable,
                    processes: [],
                    refreshedAt: Date(),
                    message: "Switchyard could not inspect this Wine session."
                )
            }
        }.value

        guard !Task.isCancelled,
              sessionRefreshTokens[containerID] == refreshToken,
              containers.contains(where: { $0.id == containerID }) else { return }
        sessionSnapshotsByContainerID[containerID] = snapshot
        if snapshot.wineServerState == .inactive {
            prefixStartupsAwaitingInactiveTransition.remove(containerID)
            if activeRunSessionIDsByContainerID[containerID]?.isEmpty != false,
               !isContainerTransitioning(containerID),
               containers.first(where: { $0.id == containerID })?.status == .running {
                let recoveredStatus: ContainerStatus = (container.executablePath?.isEmpty ?? true)
                    ? .needsSetup
                    : .ready
                updateContainer(containerID) { $0.status = recoveredStatus }
            }
        } else if snapshot.wineServerState == .active,
                  !prefixStartupsAwaitingInactiveTransition.contains(containerID) {
            finishPrefixStartup(for: containerID)
        }
    }

    private func beginPrefixStartupMonitoring(
        for containerID: UUID,
        winePath: String,
        prefixPath: String,
        requiresInactiveTransition: Bool
    ) {
        prefixStartupTasks[containerID]?.cancel()
        startingPrefixContainerIDs.insert(containerID)
        if requiresInactiveTransition {
            prefixStartupsAwaitingInactiveTransition.insert(containerID)
        } else {
            prefixStartupsAwaitingInactiveTransition.remove(containerID)
        }
        let runnerClient = runnerClient
        prefixStartupTasks[containerID] = Task { [weak self] in
            while !Task.isCancelled {
                let state = await Task.detached(priority: .utility) {
                    runnerClient.prefixSessionState(
                        winePath: winePath,
                        prefixPath: prefixPath
                    )
                }.value
                guard !Task.isCancelled, let self else { return }

                if case .inactive = state {
                    self.prefixStartupsAwaitingInactiveTransition.remove(containerID)
                } else if case .active = state,
                          !self.prefixStartupsAwaitingInactiveTransition.contains(containerID) {
                    await self.refreshContainerSession(for: containerID)
                    self.finishPrefixStartup(for: containerID)
                    return
                }

                if self.activeRunSessionIDsByContainerID[containerID]?.isEmpty != false {
                    await self.refreshContainerSession(for: containerID)
                    self.finishPrefixStartup(for: containerID)
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    private func finishPrefixStartup(for containerID: UUID) {
        guard startingPrefixContainerIDs.contains(containerID) else { return }
        prefixStartupTasks[containerID]?.cancel()
        prefixStartupTasks.removeValue(forKey: containerID)
        startingPrefixContainerIDs.remove(containerID)
        prefixStartupsAwaitingInactiveTransition.remove(containerID)
        launchingExecutablePathByContainerID.removeValue(forKey: containerID)
    }

    func refreshInstalledPrograms(for containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        installedProgramTasks[containerID]?.cancel()

        installedProgramTasks[containerID] = Task {
            let programs = await Task.detached(priority: .userInitiated) {
                InstalledProgramCatalog().installedPrograms(in: container)
            }.value
            guard !Task.isCancelled else { return }
            guard self.containers.contains(where: { $0.id == containerID }) else { return }
            self.installedProgramsByContainerID[containerID] = programs
            self.selectStarterApplicationAsDefaultIfNeeded(
                programs,
                containerID: containerID
            )
            self.installedProgramTasks.removeValue(forKey: containerID)
        }
    }

    private func selectStarterApplicationAsDefaultIfNeeded(
        _ programs: [InstalledProgram],
        containerID: UUID
    ) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        let belongsToGuidedSetup = container.starterApplicationID
            == StarterApplicationCatalog.steam.id
            || steamInstallationState.containerID == containerID
        guard belongsToGuidedSetup,
              (container.executablePath?.isEmpty ?? true),
              let steam = programs.first(where: {
                  URL(fileURLWithPath: $0.executablePath)
                      .lastPathComponent
                      .caseInsensitiveCompare("steam.exe") == .orderedSame
              }) else {
            return
        }

        updateDefaultExecutable(for: containerID, to: steam.executablePath, arguments: [])
        steamInstallationState = .installed(containerID)
        steamSetupMessage = "Steam is installed and ready to launch."
    }

    private func monitorSteamInstallation(in containerID: UUID) {
        starterApplicationDetectionTask?.cancel()
        starterApplicationDetectionTask = Task {
            defer { starterApplicationDetectionTask = nil }

            for _ in 0..<60 {
                guard !Task.isCancelled,
                      let container = containers.first(where: { $0.id == containerID }) else {
                    return
                }
                let programs = await Task.detached(priority: .utility) {
                    InstalledProgramCatalog().installedPrograms(in: container)
                }.value
                guard !Task.isCancelled else { return }
                installedProgramsByContainerID[containerID] = programs
                selectStarterApplicationAsDefaultIfNeeded(
                    programs,
                    containerID: containerID
                )
                if case .installed(let installedID) = steamInstallationState,
                   installedID == containerID {
                    return
                }

                if !isContainerRunning(containerID)
                    && !isContainerTransitioning(containerID) {
                    steamInstallationState = .failed(
                        "Steam was not found after the installer closed. You can continue setup in the same container without losing anything."
                    )
                    steamSetupMessage = "Steam installation did not finish. Choose Continue Steam Setup to try again."
                    return
                }

                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
            }

            if case .installerStarted(let activeID) = steamInstallationState,
               activeID == containerID {
                steamInstallationState = .failed(
                    "Steam setup took longer than expected. If the installer is still open, finish it; otherwise try again in the same container."
                )
                steamSetupMessage = "Steam was not detected yet. You can safely continue setup in this container."
            }
        }
    }

    func useInstalledProgramAsDefault(_ program: InstalledProgram, for containerID: UUID) {
        updateDefaultExecutable(
            for: containerID,
            to: program.executablePath,
            arguments: []
        )
    }

    @discardableResult
    func renameContainer(_ containerID: UUID, to name: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = containers.firstIndex(where: { $0.id == containerID }) else {
            return false
        }
        guard containers[index].name != trimmedName else { return true }
        guard !isContainerBusy(containerID) else {
            logLines.insert(
                LogLine(
                    level: "warning",
                    source: "containers",
                    message: "Stop or wait for \(containers[index].name) before renaming its folder."
                ),
                at: 0
            )
            return false
        }

        let originalContainer = containers[index]
        containerStorageOperationIDs.insert(containerID)
        defer { containerStorageOperationIDs.remove(containerID) }
        await cancelLoginCallbackRecoveryForStorageOperation(in: containerID)

        let prefixLock: WinePrefixFileLock
        do {
            prefixLock = try await Task.detached(priority: .userInitiated) {
                try WinePrefixFileLock(
                    prefixPath: originalContainer.path,
                    mode: .exclusive
                )
            }.value
        } catch {
            logLines.insert(
                LogLine(
                    level: "error",
                    source: "containers",
                    message: "Could not lock \(originalContainer.name) for a safe folder rename: \(Self.errorDescription(error))"
                ),
                at: 0
            )
            return false
        }
        defer { prefixLock.unlock() }

        let winePath = currentRuntime.winePath
        let runnerClient = runnerClient
        let inspectedPrefixState = await Task.detached(priority: .userInitiated) {
            runnerClient.prefixSessionState(
                winePath: winePath,
                prefixPath: originalContainer.path
            )
        }.value
        switch inspectedPrefixState {
        case .active, .orphaned:
            logLines.insert(
                LogLine(
                    level: "warning",
                    source: "containers",
                    message: "Stop \(originalContainer.name) before renaming its folder. A Wine process is still using this container."
                ),
                at: 0
            )
            return false
        case .unavailable:
            logLines.insert(
                LogLine(
                    level: "error",
                    source: "containers",
                    message: "Could not verify that \(originalContainer.name) is idle, so its folder was not renamed."
                ),
                at: 0
            )
            return false
        case .inactive:
            break
        }

        guard let currentIndex = containers.firstIndex(where: { $0.id == containerID }),
              containers[currentIndex].path == originalContainer.path else {
            return false
        }

        do {
            let occupiedDirectoryNames = ContainerPathPolicy.occupiedDirectoryNames(
                containers: containers.filter { $0.id != containerID },
                existingDirectoryNames: []
            )
            let renamedContainer = try ContainerDirectoryRenamer(
                rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true)
            ).rename(
                originalContainer,
                to: trimmedName,
                occupiedDirectoryNames: occupiedDirectoryNames
            ) { proposedContainer in
                var proposedContainers = containers
                proposedContainers[currentIndex] = proposedContainer
                try libraryStore.save(
                    SwitchyardContainerSnapshot(containers: proposedContainers)
                )
            }

            installedProgramTasks[containerID]?.cancel()
            installedProgramTasks.removeValue(forKey: containerID)
            installedProgramsByContainerID.removeValue(forKey: containerID)
            containers[currentIndex] = renamedContainer

            if var recentLaunches = recentProgramLaunchesByContainerID[containerID] {
                for launchIndex in recentLaunches.indices {
                    recentLaunches[launchIndex].executablePath = ContainerPathPolicy.relocatingPath(
                        recentLaunches[launchIndex].executablePath,
                        from: originalContainer.path,
                        to: renamedContainer.path
                    )
                }
                recentProgramLaunchesByContainerID[containerID] = recentLaunches
            }

            sessionRefreshTokens[containerID] = UUID()
            sessionSnapshotsByContainerID[containerID] = .checking
            persistRecentProgramLaunches()
            refreshInstalledPrograms(for: containerID)
            refreshProtocolAssociations()
            logLines.insert(
                LogLine(
                    level: "info",
                    source: "containers",
                    message: "Renamed \(originalContainer.name) and its folder to \(renamedContainer.name)."
                ),
                at: 0
            )
            return true
        } catch {
            logLines.insert(
                LogLine(
                    level: "error",
                    source: "containers",
                    message: "Could not rename \(originalContainer.name): \(Self.errorDescription(error))"
                ),
                at: 0
            )
            return false
        }
    }

    func updateExecutablePath(for containerID: UUID, to path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        updateContainer(containerID) { container in
            container.executablePath = trimmedPath.isEmpty ? nil : trimmedPath
            if container.status != .running {
                container.status = trimmedPath.isEmpty ? .needsSetup : .ready
            }
        }
    }

    func updateExecutableArguments(for containerID: UUID, to arguments: [String]) {
        updateContainer(containerID) { container in
            container.executableArguments = arguments
        }
    }

    private func updateDefaultExecutable(for containerID: UUID, to path: String, arguments: [String]) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        updateContainer(containerID) { container in
            container.executablePath = trimmedPath.isEmpty ? nil : trimmedPath
            container.executableArguments = trimmedPath.isEmpty ? [] : arguments
            if container.status != .running {
                container.status = trimmedPath.isEmpty ? .needsSetup : .ready
            }
        }
    }

    func addEnvironmentOverride(for containerID: UUID, key: String, value: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EnvironmentOverridePolicy.isAllowedKey(trimmedKey) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Environment variable name is invalid or reserved: \(trimmedKey.isEmpty ? "empty" : trimmedKey)."), at: 0)
            return
        }
        updateContainer(containerID) { container in
            container.environmentOverrides[trimmedKey] = value
        }
    }

    func updateEnvironmentOverride(for containerID: UUID, key: String, value: String) {
        guard EnvironmentOverridePolicy.isAllowedKey(key) else {
            removeEnvironmentOverride(for: containerID, key: key)
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Removed reserved environment variable: \(key)."), at: 0)
            return
        }
        updateContainer(containerID) { container in
            container.environmentOverrides[key] = value
        }
    }

    func removeEnvironmentOverride(for containerID: UUID, key: String) {
        updateContainer(containerID) { container in
            container.environmentOverrides.removeValue(forKey: key)
        }
    }

    func isContainerRunning(_ containerID: UUID) -> Bool {
        if activeRunSessionIDsByContainerID[containerID]?.isEmpty == false {
            return true
        }
        if sessionSnapshotsByContainerID[containerID]?.wineServerState.hasRunningProcesses == true {
            return true
        }
        return containers.contains { $0.id == containerID && $0.status == .running }
    }

    func isContainerBusy(_ containerID: UUID) -> Bool {
        isContainerTransitioning(containerID) || isContainerRunning(containerID)
    }

    func openContainerInFinder(_ containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: container.path, isDirectory: true)])
    }

    func openInFinder(_ url: URL, in containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }),
              ContainerDirectoryCatalog().contains(url, in: container) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    func deleteContainer(_ containerID: UUID) async -> Bool {
        guard let container = containers.first(where: { $0.id == containerID }) else { return false }
        guard !isContainerTransitioning(containerID) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Wait for \(container.name) to finish its current action before deleting its container."), at: 0)
            return false
        }

        let containerURL = URL(fileURLWithPath: container.path, isDirectory: true)
        if FileManager.default.fileExists(atPath: containerURL.path) {
            guard isSafeTrashTarget(containerURL) else {
                logLines.insert(LogLine(level: "error", source: "containers", message: "Refusing to move \(container.name) to Trash because its path is outside Switchyard storage or has no Switchyard manifest."), at: 0)
                return false
            }

            containerStorageOperationIDs.insert(containerID)
            defer { containerStorageOperationIDs.remove(containerID) }
            await cancelLoginCallbackRecoveryForStorageOperation(in: containerID)

            let winePath = currentRuntime.winePath
            let prefixPath = container.path
            let runnerClient = runnerClient
            let targetedRunSessionIDs = activeRunSessionIDsByContainerID[containerID] ?? []
            userStoppedRunSessionIDs.formUnion(targetedRunSessionIDs)
            do {
                try await Task.detached(priority: .userInitiated) {
                    let prefixLock = try WinePrefixFileLock(
                        prefixPath: prefixPath,
                        mode: .exclusive
                    )
                    defer { prefixLock.unlock() }
                    try runnerClient.stopWineServer(
                        winePath: winePath,
                        prefixPath: prefixPath
                    )
                    var trashedURL: NSURL?
                    try FileManager.default.trashItem(
                        at: containerURL,
                        resultingItemURL: &trashedURL
                    )
                }.value
                logLines.insert(LogLine(level: "info", source: "containers", message: "Moved \(container.name) to Trash."), at: 0)
            } catch {
                userStoppedRunSessionIDs.subtract(targetedRunSessionIDs)
                logLines.insert(LogLine(level: "error", source: "containers", message: "Could not stop \(container.name) safely and move it to Trash: \(Self.errorDescription(error))"), at: 0)
                return false
            }
        } else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "\(container.name) was removed from Switchyard, but its folder was already missing."), at: 0)
        }

        containers.removeAll { $0.id == containerID }
        callbackRecoveryTasks[containerID]?.cancel()
        callbackRecoveryTasks.removeValue(forKey: containerID)
        pendingLoginCallbackRecoveries.removeValue(forKey: containerID)
        loginCallbackRecoveryStates.removeValue(forKey: containerID)
        installedProgramTasks[containerID]?.cancel()
        installedProgramTasks.removeValue(forKey: containerID)
        installedProgramsByContainerID.removeValue(forKey: containerID)
        if steamInstallationState.containerID == containerID {
            starterApplicationDetectionTask?.cancel()
            starterApplicationDetectionTask = nil
            steamInstallationState = .idle
        }
        if let activeRunSessionIDs = activeRunSessionIDsByContainerID.removeValue(
            forKey: containerID
        ) {
            userStoppedRunSessionIDs.subtract(activeRunSessionIDs)
        }
        prefixStartupTasks[containerID]?.cancel()
        prefixStartupTasks.removeValue(forKey: containerID)
        startingPrefixContainerIDs.remove(containerID)
        prefixStartupsAwaitingInactiveTransition.remove(containerID)
        launchingExecutablePathByContainerID.removeValue(forKey: containerID)
        recentProgramLaunchesByContainerID.removeValue(forKey: containerID)
        sessionRefreshTokens.removeValue(forKey: containerID)
        sessionSnapshotsByContainerID.removeValue(forKey: containerID)
        stoppingWineServerContainerIDs.remove(containerID)
        selectedContainerID = containers.first?.id
        persistLibrary()
        persistRecentProgramLaunches()
        return true
    }

    private func runSelectedContainer(containerID: UUID) async {
        await runContainer(containerID: containerID, executablePath: nil, executableArguments: [])
    }

    private func runContainer(containerID: UUID, executablePath: String?, executableArguments: [String]) async {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerTransitioning(containerID) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Wait for \(container.name) to finish its current session action before starting another executable."), at: 0)
            return
        }

        guard runtimeStatus.canLaunch else {
            appendFailedRun(for: container, message: runtimeStatus.summary)
            return
        }

        let launchedExecutable = executablePath ?? container.executablePath ?? ""
        launchingContainerIDs.insert(containerID)
        if !launchedExecutable.isEmpty {
            launchingExecutablePathByContainerID[containerID] = launchedExecutable
        }
        var preserveLaunchingExecutable = false
        defer {
            launchingContainerIDs.remove(containerID)
            if !preserveLaunchingExecutable {
                launchingExecutablePathByContainerID.removeValue(forKey: containerID)
            }
        }

        let winePath = currentRuntime.winePath
        let prefixPath = container.path
        let runnerClient = runnerClient
        let inspectedPrefixState = await Task.detached(priority: .userInitiated) {
            runnerClient.prefixSessionState(winePath: winePath, prefixPath: prefixPath)
        }.value
        let prefixWasOrphaned = sessionSnapshotsByContainerID[containerID]?.wineServerState == .orphaned
            || {
                if case .orphaned = inspectedPrefixState { return true }
                return false
            }()
        let prefixWasActive: Bool = {
            if sessionSnapshotsByContainerID[containerID]?.wineServerState.hasRunningProcesses == true
                || activeRunSessionIDsByContainerID[containerID]?.isEmpty == false
            {
                return true
            }
            if case .active = inspectedPrefixState {
                return true
            }
            if case .orphaned = inspectedPrefixState {
                return true
            }
            return false
        }()

        var terminateExistingPrefixSession = executablePath != nil && prefixWasOrphaned
        if executablePath == nil {
            if prefixWasActive {
                guard confirmRestartOfExistingPrefixSession(for: container) else { return }
                terminateExistingPrefixSession = true
            } else if case .unavailable = inspectedPrefixState {
                logLines.insert(
                    LogLine(
                        level: "warning",
                        source: container.name,
                        message: "Could not inspect this Wine runtime for an existing prefix session; launching without stopping it."
                    ),
                    at: 0
                )
            }
        }

        var prefixSessionIsActiveForFonts = prefixWasActive
        if !prefixWasActive {
            prefixSessionIsActiveForFonts = await initializePrefixForFirstLaunchIfNeeded(
                container,
                winePath: winePath
            )
        }
        let fontPreparationLog = await prepareOpenFontsForLaunch(
            for: container,
            prefixSessionIsActive: prefixSessionIsActiveForFonts
        )
        logLines.insert(fontPreparationLog, at: 0)

        do {
            let debugEnvironmentOverrides = debugRunEnvironmentOverrides(for: container)
            let debugLogPath = debugRunLogPath(for: container, executablePath: launchedExecutable)

            let plan = try jobEngine.runPlan(
                container: container,
                executablePath: executablePath,
                executableArguments: executableArguments,
                runtime: currentRuntime,
                gptkPath: gptkPath,
                environmentOverrides: debugEnvironmentOverrides,
                debugLogPath: debugLogPath,
                terminateExistingPrefixSession: terminateExistingPrefixSession
            )
            let runSession = try runnerClient.launch(
                plan,
                containerID: container.id,
                containerName: container.name,
                onLogs: { [weak self] lines in
                    Task { @MainActor in
                        self?.recordIncomingLogs(lines)
                    }
                },
                onExit: { [weak self] completedSession in
                    Task { @MainActor in
                        self?.completeRunSession(completedSession)
                    }
                }
            )
            activeRunSessionIDsByContainerID[container.id, default: []].insert(runSession.id)
            if !prefixWasActive || terminateExistingPrefixSession {
                preserveLaunchingExecutable = true
                beginPrefixStartupMonitoring(
                    for: container.id,
                    winePath: winePath,
                    prefixPath: prefixPath,
                    requiresInactiveTransition: terminateExistingPrefixSession
                )
            }
            if !launchedExecutable.isEmpty,
               WindowsApplicationFileKind(path: launchedExecutable) != .installerPackage {
                recordRecentProgramLaunch(
                    executablePath: launchedExecutable,
                    containerID: container.id
                )
            }
            protocolBridge.recordLaunch(containerID: container.id)
            refreshProtocolAssociations()
            mark(container.id, as: .running)
            let executableName = launchedExecutable
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .last
                .map(String.init) ?? "configured executable"
            logLines.insert(
                LogLine(
                    containerID: container.id,
                    level: "info",
                    source: container.name,
                    message: "Launch command started through switchyard-runner: executable=\(executableName) argumentCount=\(plan.arguments.count)"
                ),
                at: 0
            )
            if let debugLogPath {
                logLines.insert(
                    LogLine(
                        level: "info",
                        source: container.name,
                        message: "Debug run logging enabled (profile=\(verboseWineLogging ? "verbose" : "standard"), WINEDEBUG=\(debugEnvironmentOverrides["WINEDEBUG"] ?? "container override or inherited"), file: \(debugLogPath)). The live view is batched and retains its latest \(maximumLiveLogLines) entries; this file retains the complete run output."
                    ),
                    at: 0
                )
            }
        } catch {
            appendFailedRun(for: container, message: "Could not prepare container: \(Self.errorDescription(error))")
        }
    }

    private func confirmRestartOfExistingPrefixSession(for container: Container) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(container.name) is already running"
        alert.informativeText = "Restarting will close every Windows process in this container, including games or installers. Restart it to guarantee a fresh launch?"
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func startProtocolBridgeMonitoring() {
        protocolBridgeTask?.cancel()
        protocolBridgeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshProtocolAssociations()
                self?.refreshDesktopShortcuts()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshProtocolAssociations() {
        do {
            let runnerPath = try runnerClient.runnerURL().path
            let result = try protocolBridge.refresh(
                containers: containers,
                winePath: currentRuntime.winePath,
                runnerPath: runnerPath
            )
            lastProtocolBridgeError = nil
            for scheme in result.newlyRegisteredSchemes {
                logLines.insert(
                    LogLine(
                        level: "info",
                        source: "protocols",
                        message: "Registered a macOS callback bridge for a Wine URL scheme: \(scheme)"
                    ),
                    at: 0
                )
            }
        } catch {
            let description = Self.errorDescription(error)
            guard description != lastProtocolBridgeError else { return }
            lastProtocolBridgeError = description
            logLines.insert(
                LogLine(level: "warning", source: "protocols", message: description),
                at: 0
            )
        }
    }

    private func refreshDesktopShortcuts() {
        do {
            let runnerPath = try runnerClient.runnerURL().path
            let result = try desktopShortcutBridge.refresh(
                containers: containers,
                winePath: currentRuntime.winePath,
                runnerPath: runnerPath
            )
            lastDesktopShortcutBridgeError = nil
            for name in result.createdShortcutNames {
                logLines.insert(
                    LogLine(
                        level: "info",
                        source: "shortcuts",
                        message: "Created a native macOS desktop shortcut for \(name)."
                    ),
                    at: 0
                )
            }
            for name in result.removedShortcutNames {
                logLines.insert(
                    LogLine(
                        level: "info",
                        source: "shortcuts",
                        message: "Removed a stale macOS desktop shortcut for \(name)."
                    ),
                    at: 0
                )
            }
        } catch {
            let description = Self.errorDescription(error)
            guard description != lastDesktopShortcutBridgeError else { return }
            lastDesktopShortcutBridgeError = description
            logLines.insert(
                LogLine(level: "warning", source: "shortcuts", message: description),
                at: 0
            )
        }
    }

    private func debugRunEnvironmentOverrides(for container: Container) -> [String: String] {
        guard developerLogging else { return [:] }
        guard container.environmentOverrides["WINEDEBUG"] == nil else { return [:] }
        let profile: WineDebugLoggingProfile = verboseWineLogging ? .verbose : .standard
        return [
            "WINEDEBUG": profile.environmentValue
        ]
    }

    private func debugRunLogPath(for container: Container, executablePath: String) -> String? {
        guard developerLogging else { return nil }
        let logsRoot = debugRunLogRoot
        let stamp = debugLogFormatter.string(from: Date())
        let runID = String(UUID().uuidString.prefix(8)).lowercased()
        let executableName = URL(fileURLWithPath: executablePath).deletingPathExtension().lastPathComponent
        let fileName = "\(stamp)-\(runID)-\(sanitizeFilename(container.name))-\(sanitizeFilename(executableName)).log"
        let fileURL = logsRoot.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logsRoot.path
            )
            pruneDebugRunLogs(in: logsRoot)
            return fileURL.path
        } catch {
            logLines.insert(
                LogLine(level: "warning", source: "containers", message: "Could not create debug log directory \(logsRoot.path): \(Self.errorDescription(error))"),
                at: 0
            )
            return nil
        }
    }

    private var debugRunLogRoot: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DebugRuns", isDirectory: true)
    }

    private func pruneDebugRunLogs(in root: URL, now: Date = Date()) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-debugRunLogRetentionInterval)
        var retained: [(url: URL, modifiedAt: Date)] = []
        for url in urls where url.pathExtension.lowercased() == "log" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if modifiedAt < cutoff {
                try? FileManager.default.removeItem(at: url)
            } else {
                retained.append((url, modifiedAt))
            }
        }

        for entry in retained
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .dropFirst(maximumRetainedDebugRunLogs - 1) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    private func sanitizeFilename(_ value: String) -> String {
        let legal = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        return value
            .unicodeScalars
            .map { scalar in legal.contains(scalar) ? String(scalar) : "_" }
            .joined()
    }

    private func prepareOpenFontsForLaunch(
        for container: Container,
        prefixSessionIsActive: Bool
    ) async -> LogLine {
        if prefixSessionIsActive {
            return LogLine(
                level: "info",
                source: "fonts",
                message: "Open Font Pack registration was skipped while this Windows session is active."
            )
        }

        let fontCacheRoot = fontCacheRoot
        return await Task.detached(priority: .userInitiated) {
            do {
                let cacheRoot = URL(fileURLWithPath: fontCacheRoot, isDirectory: true)
                _ = try await OpenFontPackDownloader().ensureFontPack(in: cacheRoot)
                let result = try ContainerFontInstaller().installOpenFontPack(into: container, from: cacheRoot)
                let level = result.skippedReason == nil ? "info" : "warning"
                return LogLine(level: level, source: "fonts", message: result.summary)
            } catch {
                return LogLine(
                    level: "warning",
                    source: "fonts",
                    message: "Open Font Pack could not be prepared; continuing launch without additional font fallback: \(Self.errorDescription(error))"
                )
            }
        }.value
    }

    private func initializePrefixForFirstLaunchIfNeeded(
        _ container: Container,
        winePath: String
    ) async -> Bool {
        guard !prefixHasInitializedRegistry(container) else { return false }

        logLines.insert(
            LogLine(
                containerID: container.id,
                level: "info",
                source: container.name,
                message: "Initializing this Windows container before its first app opens."
            ),
            at: 0
        )

        do {
            let plan = try jobEngine.runPlan(
                container: container,
                executablePath: "wineboot.exe",
                executableArguments: ["-u"],
                runtime: currentRuntime,
                gptkPath: gptkPath
            )
            let session = try await runnerClient.launchAndWait(
                plan,
                containerID: container.id,
                containerName: "\(container.name) Setup",
                onLogs: { [weak self] lines in
                    Task { @MainActor in
                        self?.recordIncomingLogs(lines)
                    }
                }
            )
            guard session.outcome == .succeeded else {
                throw NSError(
                    domain: "Switchyard.PrefixSetup",
                    code: Int(session.exitCode ?? -1),
                    userInfo: [NSLocalizedDescriptionKey: "Wine initialization exited before finishing."]
                )
            }

            let runnerClient = runnerClient
            let prefixPath = container.path
            try await Task.detached(priority: .userInitiated) {
                try runnerClient.stopWineServer(winePath: winePath, prefixPath: prefixPath)
            }.value
            return false
        } catch {
            logLines.insert(
                LogLine(
                    containerID: container.id,
                    level: "warning",
                    source: container.name,
                    message: "The first-run container preparation did not finish; the app will still open and Wine can retry automatically: \(Self.errorDescription(error))"
                ),
                at: 0
            )
            return true
        }
    }

    private func prefixHasInitializedRegistry(_ container: Container) -> Bool {
        ["system.reg", "user.reg"].allSatisfy { fileName in
            let url = URL(fileURLWithPath: container.path, isDirectory: true)
                .appendingPathComponent(fileName)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("#arch=") })
        }
    }

    var hasRunningContainers: Bool {
        containers.contains { isContainerRunning($0.id) }
    }

    func clearLogs(for containerID: UUID? = nil) {
        logLines = LogClearPolicy.clearing(logLines, for: containerID)
    }

    private func recordIncomingLogs(_ logs: [LogLine]) {
        logLines = LiveLogPolicy.merging(
            chronological: logs,
            before: logLines,
            limit: maximumLiveLogLines
        )
    }

    func stopAllRuns() {
        let runningContainers = containers.filter { isContainerRunning($0.id) }
        runnerClient.stopAll()

        for container in runningContainers {
            mark(container.id, as: .failed)
            logLines.insert(
                LogLine(
                    containerID: container.id,
                    level: "warning",
                    source: container.name,
                    message: "Stop requested for this container."
                ),
                at: 0
            )
        }
    }

    func stopAllWindowsAppsForSetup() async -> Bool {
        let targetIDs = containers.filter { isContainerRunning($0.id) }.map(\.id)
        stopAllRuns()

        for _ in 0..<40 {
            for containerID in targetIDs where !isContainerTransitioning(containerID) {
                let snapshotIsActive = sessionSnapshotsByContainerID[containerID]?.wineServerState.hasRunningProcesses == true
                let statusIsRunning = containers.first(where: { $0.id == containerID })?.status == .running
                if snapshotIsActive || statusIsRunning {
                    await stopWineServer(in: containerID)
                }
            }
            if !hasRunningContainers {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return false
            }
        }

        return !hasRunningContainers
    }

    func diagnosticBundle() -> DiagnosticBundle {
        DiagnosticBundle(runtimeStatus: runtimeStatus, checks: diagnostics, recentLogs: Array(logLines.prefix(50)))
    }

    private func appendFailedRun(for container: Container, message: String) {
        mark(container.id, as: .failed)
        selectedSection = .logs
        logLines.insert(
            LogLine(
                containerID: container.id,
                level: "error",
                source: container.name,
                message: message
            ),
            at: 0
        )
    }

    nonisolated private static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func completeRunSession(_ session: RunSession) {
        let wasStoppedByUser = userStoppedRunSessionIDs.remove(session.id) != nil
        let normalizedOutcome = RunCompletionPolicy.normalizedOutcome(
            session.outcome,
            stoppedByUser: wasStoppedByUser
        )
        activeRunSessionIDsByContainerID[session.containerID]?.remove(session.id)
        let hasRemainingRuns = activeRunSessionIDsByContainerID[session.containerID]?.isEmpty == false
        if !hasRemainingRuns {
            activeRunSessionIDsByContainerID.removeValue(forKey: session.containerID)
            mark(
                session.containerID,
                as: RunCompletionPolicy.containerStatus(for: normalizedOutcome)
            )
        }
        refreshInstalledPrograms(for: session.containerID)
        Task {
            await refreshContainerSession(for: session.containerID)
        }
        logLines.insert(
            LogLine(
                containerID: session.containerID,
                level: normalizedOutcome == .failed ? "error" : "info",
                source: session.containerName,
                message: wasStoppedByUser
                    ? "Runner stopped at the user's request."
                    : "Runner exited with code \(session.exitCode.map(String.init) ?? "unknown")."
            ),
            at: 0
        )
    }

    private func mark(_ containerID: UUID, as status: ContainerStatus) {
        guard let index = containers.firstIndex(where: { $0.id == containerID }) else { return }
        containers[index].status = status
        containers[index].lastRun = Date()
        containers[index].lastModified = Date()
        persistLibrary()
    }

    private func updateContainer(_ containerID: UUID, mutation: (inout Container) -> Void) {
        guard !containerStorageOperationIDs.contains(containerID),
              let index = containers.firstIndex(where: { $0.id == containerID }) else { return }
        mutation(&containers[index])
        containers[index].lastModified = Date()
        persistLibrary()
    }

    private func nextContainerName(baseName: String = "New Container") -> String {
        guard containers.contains(where: { $0.name == baseName }) else {
            return baseName
        }

        var suffix = 2
        while containers.contains(where: { $0.name == "\(baseName) \(suffix)" }) {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func occupiedContainerDirectoryNames(in libraryURL: URL) -> Set<String> {
        var existingDirectoryNames: Set<String> = []

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ContainerPathPolicy.occupiedDirectoryNames(
                containers: containers,
                existingDirectoryNames: existingDirectoryNames
            )
        }

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                existingDirectoryNames.insert(entry.lastPathComponent)
            }
        }

        return ContainerPathPolicy.occupiedDirectoryNames(
            containers: containers,
            existingDirectoryNames: existingDirectoryNames
        )
    }

    private func removeDuplicateContainerPathsIfNeeded() {
        let result = ContainerPathPolicy.removingDuplicatePaths(from: containers)
        containers = result.containers

        guard !result.removedNames.isEmpty else { return }

        if let selectedContainerID, !containers.contains(where: { $0.id == selectedContainerID }) {
            self.selectedContainerID = containers.first?.id
        }

        logLines.insert(
            LogLine(
                level: "warning",
                source: "containers",
                message: "Removed duplicate container entries that pointed to an already-used folder: \(result.removedNames.joined(separator: ", "))."
            ),
            at: 0
        )
    }

    private func isSafeTrashTarget(_ url: URL) -> Bool {
        let targetURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let storageURL = URL(fileURLWithPath: libraryPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let storagePath = storageURL.path
        let targetPath = targetURL.path
        guard targetPath != storagePath,
              targetPath.hasPrefix(storagePath + "/") else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let hasContainerManifest = FileManager.default.fileExists(
            atPath: targetURL.appendingPathComponent("switchyard-container.json").path
        )
        let hasLegacyManifest = FileManager.default.fileExists(
            atPath: targetURL.appendingPathComponent("switchyard-bottle.json").path
        )
        return hasContainerManifest || hasLegacyManifest
    }

    private func persistLibrary() {
        removeDuplicateContainerPathsIfNeeded()
        do {
            try libraryStore.save(SwitchyardContainerSnapshot(containers: containers))
        } catch {
            logLines.insert(LogLine(level: "error", source: "persistence", message: "Could not save container manifest: \(error)"), at: 0)
        }
    }

    private func recordRecentProgramLaunch(executablePath: String, containerID: UUID) {
        recentProgramLaunchesByContainerID[containerID] = RecentProgramLaunchPolicy.recording(
            executablePath: executablePath,
            in: recentProgramLaunchesByContainerID[containerID] ?? [],
            limit: maximumRecentProgramLaunches
        )
        persistRecentProgramLaunches()
    }

    private func persistRecentProgramLaunches() {
        guard let data = try? JSONEncoder().encode(recentProgramLaunchesByContainerID) else {
            return
        }
        defaults.set(data, forKey: recentProgramLaunchesDefaultsKey)
    }

    private static func initialRecentProgramLaunches(
        defaults: UserDefaults,
        containers: [Container]
    ) -> [UUID: [RecentProgramLaunch]] {
        let decodedLaunches: [UUID: [RecentProgramLaunch]]
        if let data = defaults.data(forKey: recentProgramLaunchesDefaultsKey),
           let storedLaunches = try? JSONDecoder().decode(
               [UUID: [RecentProgramLaunch]].self,
               from: data
           ) {
            decodedLaunches = storedLaunches
        } else {
            decodedLaunches = [:]
        }

        let containerIDs = Set(containers.map(\.id))
        var launches = decodedLaunches.filter { containerIDs.contains($0.key) }
        for container in containers where launches[container.id]?.isEmpty != false {
            guard let executablePath = container.executablePath,
                  let lastRun = container.lastRun else { continue }
            launches[container.id] = RecentProgramLaunchPolicy.recording(
                executablePath: executablePath,
                at: lastRun,
                in: [],
                limit: maximumRecentProgramLaunches
            )
        }
        return launches
    }

    private static func initialLibrarySnapshot(libraryPath: String) -> SwitchyardContainerSnapshot {
        let store = LibraryManifestStore(rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true))
        if let loaded = try? store.loadSnapshot(), !loaded.containers.isEmpty {
            return loaded
        }

        return SwitchyardContainerSnapshot(containers: [])
    }
}
