import AppCore
import AppKit
import Foundation
import JobEngine
import Persistence
import RuntimeCatalog
import SwiftUI
import UniformTypeIdentifiers

private struct RuntimeRefreshResult {
    var importedGPTKPath: String?
    var resolvedWinePath: String
    var status: RuntimeStatus
    var diagnostics: [DiagnosticCheck]
    var importMessage: String?
}

private enum LoginCallbackRecoveryError: LocalizedError {
    case noRunningApplication

    var errorDescription: String? {
        switch self {
        case .noRunningApplication:
            "Keep the Windows game open while recovering its copied login callback."
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
private let recentProgramLaunchesDefaultsKey = "recentProgramLaunches.v1"
private let maximumRecentProgramLaunches = 8

private struct SwitchyardWineSourcePolicy {
    var revision: String

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
        return SwitchyardWineSourcePolicy(
            revision: unresolvedRevision.hasPrefix("__") ? "" : unresolvedRevision
        )
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedSection: SidebarSelection = .containers
    @Published var selectedSettingsTab: SettingsTab = .general
    @Published var selectedContainerID: UUID?
    @Published var hasCompletedSetup: Bool
    @Published var libraryPath: String
    @Published var gptkPath: String
    @Published var winePath: String
    @Published private(set) var runtimeStatus = RuntimeStatus()
    @Published private(set) var diagnostics: [DiagnosticCheck] = []
    @Published private(set) var launchingContainerIDs: Set<UUID> = []
    @Published private(set) var startingPrefixContainerIDs: Set<UUID> = []
    @Published private(set) var launchingExecutablePathByContainerID: [UUID: String] = [:]
    @Published private(set) var installedProgramsByContainerID: [UUID: [InstalledProgram]] = [:]
    @Published private(set) var recentProgramLaunchesByContainerID: [UUID: [RecentProgramLaunch]] = [:]
    @Published private(set) var sessionSnapshotsByContainerID: [UUID: ContainerSessionSnapshot] = [:]
    @Published private(set) var loginCallbackRecoveryStates: [UUID: LoginCallbackRecoveryState] = [:]
    @Published var containers: [Container]
    @Published var logLines: [LogLine] = []
    @AppStorage("developerLogging") private var developerLogging = false

    private let jobEngine = JobEngine()
    private let runnerClient = SwitchyardRunnerClient()
    private let protocolBridge = WineProtocolBridge()
    private let defaults = UserDefaults.standard
    private let wineSourcePolicy = SwitchyardWineSourcePolicy.load()
    private let debugLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
    private var diagnosticsTask: Task<Void, Never>?
    private var installedProgramTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRunSessionIDsByContainerID: [UUID: Set<UUID>] = [:]
    private var prefixStartupTasks: [UUID: Task<Void, Never>] = [:]
    private var prefixStartupsAwaitingInactiveTransition: Set<UUID> = []
    private var sessionRefreshTokens: [UUID: UUID] = [:]
    private var callbackRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingLoginCallbackRecoveries: [UUID: PendingLoginCallbackRecovery] = [:]
    private var protocolBridgeTask: Task<Void, Never>?
    private var lastProtocolBridgeError: String?

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

        persistLibrary()
        persistRecentProgramLaunches()
        pruneDebugRunLogs(in: debugRunLogRoot)
        startProtocolBridgeMonitoring()
    }

    var selectedContainer: Container? {
        guard let selectedContainerID else { return containers.first }
        return containers.first(where: { $0.id == selectedContainerID }) ?? containers.first
    }

    var currentRuntime: RuntimeBuild {
        let locator = RuntimeLocator()
        let resolvedWinePath = locator.preferredWineExecutablePath(
            for: winePath,
            expectedSourceRevision: wineSourcePolicy.revision
        )
            ?? locator.resolveWineExecutablePath(for: winePath)
            ?? winePath
        return locator.runtimeBuild(for: resolvedWinePath)
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

    func completeSetup() {
        hasCompletedSetup = true
        persistPreferences()
        refreshRuntimeStatus()
    }

    func refreshRuntimeStatus() {
        persistPreferences()
        diagnosticsTask?.cancel()

        let gptkPath = gptkPath
        let winePath = winePath
        let expectedWineSourceRevision = wineSourcePolicy.revision
        let gptkImportRoot = gptkImportRoot
        let fontCacheRoot = fontCacheRoot
        diagnosticsTask = Task { [gptkPath, winePath, expectedWineSourceRevision, gptkImportRoot, fontCacheRoot] in
            let result = await Task.detached(priority: .userInitiated) {
                let locator = RuntimeLocator()
                let trimmedGPTKPath = gptkPath.trimmingCharacters(in: .whitespacesAndNewlines)
                var resolvedGPTKPath = gptkPath
                var importedGPTKPath: String?
                let resolvedWinePath = locator.preferredWineExecutablePath(
                    for: winePath,
                    expectedSourceRevision: expectedWineSourceRevision
                )
                    ?? locator.resolveWineExecutablePath(for: winePath)
                    ?? winePath
                var importMessage: String?

                if !trimmedGPTKPath.isEmpty,
                   URL(fileURLWithPath: trimmedGPTKPath).pathExtension.lowercased() == "dmg",
                   !gptkImportRoot.isEmpty {
                    do {
                        let importedPath = try locator.importGPTKDiskImage(at: trimmedGPTKPath, to: gptkImportRoot)
                        resolvedGPTKPath = importedPath
                        importedGPTKPath = importedPath
                        importMessage = "Imported GPTK from local disk image into Switchyard runtime cache."
                    } catch {
                        importMessage = "Could not auto-import GPTK disk image: \(error.localizedDescription)"
                    }
                }

                let diagnosed = locator.diagnose(
                    gptkPath: resolvedGPTKPath,
                    winePath: resolvedWinePath,
                    expectedSourceRevision: expectedWineSourceRevision,
                    fontCachePath: fontCacheRoot
                )
                return RuntimeRefreshResult(
                    importedGPTKPath: importedGPTKPath,
                    resolvedWinePath: resolvedWinePath,
                    status: diagnosed.0,
                    diagnostics: diagnosed.1,
                    importMessage: importMessage
                )
            }.value

            guard !Task.isCancelled else { return }
            if let importedGPTKPath = result.importedGPTKPath,
               self.gptkPath == gptkPath {
                self.gptkPath = importedGPTKPath
                persistPreferences()
            }
            if !result.resolvedWinePath.isEmpty,
               result.resolvedWinePath != winePath,
               self.winePath == winePath {
                self.winePath = result.resolvedWinePath
                persistPreferences()
                logLines.insert(LogLine(level: "info", source: "runtime", message: "Resolved Wine selection to executable: \(result.resolvedWinePath)"), at: 0)
            }
            if let importMessage = result.importMessage {
                logLines.insert(LogLine(level: result.importedGPTKPath == nil ? "warning" : "info", source: "runtime", message: importMessage), at: 0)
            }
            runtimeStatus = result.status
            diagnostics = result.diagnostics
        }
    }

    func ensureOpenFontPack() {
        let fontCacheRoot = fontCacheRoot
        Task {
            let message = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try await OpenFontPackDownloader().ensureFontPack(
                        in: URL(fileURLWithPath: fontCacheRoot, isDirectory: true)
                    )
                    return LogLine(level: "info", source: "fonts", message: "\(result.summary) Notices: \(result.noticePath)")
                } catch {
                    return LogLine(level: "warning", source: "fonts", message: "Could not prepare Open Font Pack: \(error.localizedDescription)")
                }
            }.value
            logLines.insert(message, at: 0)
            refreshRuntimeStatus()
        }
    }

    func addContainer() {
        let name = nextContainerName()
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
            gptkFingerprint: runtimeStatus.gptkFingerprint
        )
        containers.append(container)
        selectedContainerID = container.id
        selectedSection = .containers
        persistLibrary()
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

    func chooseExecutableAndRun(in containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerLaunching(containerID) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Wait for \(container.name) to finish launching before starting another executable."), at: 0)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Run EXE in \(container.name)"
        panel.message = "Choose a Windows executable or installer to run inside this container."
        panel.prompt = "Run"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let executableType = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [executableType]
        }

        let installersURL = URL(fileURLWithPath: libraryPath, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("Installers", isDirectory: true)
        if FileManager.default.fileExists(atPath: installersURL.path) {
            panel.directoryURL = installersURL
        } else {
            panel.directoryURL = URL(fileURLWithPath: container.path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let executableURL = panel.url else { return }
        runExecutable(executableURL.path, in: containerID)
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
            self.installedProgramTasks.removeValue(forKey: containerID)
        }
    }

    func useInstalledProgramAsDefault(_ program: InstalledProgram, for containerID: UUID) {
        updateDefaultExecutable(
            for: containerID,
            to: program.executablePath,
            arguments: []
        )
    }

    func renameContainer(_ containerID: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        updateContainer(containerID) { container in
            container.name = trimmedName
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
        if sessionSnapshotsByContainerID[containerID]?.wineServerState == .active {
            return true
        }
        return containers.contains { $0.id == containerID && $0.status == .running }
    }

    func isContainerBusy(_ containerID: UUID) -> Bool {
        isContainerLaunching(containerID) || isContainerRunning(containerID)
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

    func deleteContainer(_ containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerBusy(containerID) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Stop or wait for \(container.name) before deleting its container."), at: 0)
            return
        }

        let containerURL = URL(fileURLWithPath: container.path, isDirectory: true)
        if FileManager.default.fileExists(atPath: containerURL.path) {
            guard isSafeTrashTarget(containerURL) else {
                logLines.insert(LogLine(level: "error", source: "containers", message: "Refusing to move \(container.name) to Trash because its path is outside Switchyard storage or has no Switchyard manifest."), at: 0)
                return
            }

            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: containerURL, resultingItemURL: &trashedURL)
                logLines.insert(LogLine(level: "info", source: "containers", message: "Moved \(container.name) to Trash."), at: 0)
            } catch {
                logLines.insert(LogLine(level: "error", source: "containers", message: "Could not move \(container.name) to Trash: \(Self.errorDescription(error))"), at: 0)
                return
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
        activeRunSessionIDsByContainerID.removeValue(forKey: containerID)
        prefixStartupTasks[containerID]?.cancel()
        prefixStartupTasks.removeValue(forKey: containerID)
        startingPrefixContainerIDs.remove(containerID)
        prefixStartupsAwaitingInactiveTransition.remove(containerID)
        launchingExecutablePathByContainerID.removeValue(forKey: containerID)
        recentProgramLaunchesByContainerID.removeValue(forKey: containerID)
        sessionRefreshTokens.removeValue(forKey: containerID)
        sessionSnapshotsByContainerID.removeValue(forKey: containerID)
        selectedContainerID = containers.first?.id
        persistLibrary()
        persistRecentProgramLaunches()
    }

    private func runSelectedContainer(containerID: UUID) async {
        await runContainer(containerID: containerID, executablePath: nil, executableArguments: [])
    }

    private func runContainer(containerID: UUID, executablePath: String?, executableArguments: [String]) async {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerLaunching(containerID) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Wait for \(container.name) to finish launching before starting another executable."), at: 0)
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
        let prefixWasActive: Bool = {
            if sessionSnapshotsByContainerID[containerID]?.wineServerState == .active
                || activeRunSessionIDsByContainerID[containerID]?.isEmpty == false
            {
                return true
            }
            if case .active = inspectedPrefixState {
                return true
            }
            return false
        }()

        var terminateExistingPrefixSession = false
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

        let fontPreparationLog = await prepareOpenFontsForLaunch(
            for: container,
            prefixSessionIsActive: prefixWasActive
        )
        logLines.insert(fontPreparationLog, at: 0)

        do {
            let launchArguments = executablePath == nil ? container.executableArguments : executableArguments
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
                onLog: { [weak self] line in
                    Task { @MainActor in
                        self?.logLines.insert(line, at: 0)
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
            if !launchedExecutable.isEmpty {
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
                    message: "Launch command started through switchyard-runner: executable=\(executableName) argumentCount=\(launchArguments.count)"
                ),
                at: 0
            )
            if let debugLogPath {
                logLines.insert(
                    LogLine(
                        level: "info",
                        source: container.name,
                        message: "Debug run logging enabled (WINEDEBUG=\(debugEnvironmentOverrides["WINEDEBUG"] ?? "inherited"), file: \(debugLogPath))"
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

    private func debugRunEnvironmentOverrides(for container: Container) -> [String: String] {
        guard developerLogging else { return [:] }
        guard container.environmentOverrides["WINEDEBUG"] == nil else { return [:] }
        return [
            "WINEDEBUG": "+timestamp,+seh,+warn,+err,+dcomp,+macdrv,+dxgi,+wined3d"
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

    var hasRunningContainers: Bool {
        containers.contains { isContainerRunning($0.id) }
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
        activeRunSessionIDsByContainerID[session.containerID]?.remove(session.id)
        let hasRemainingRuns = activeRunSessionIDsByContainerID[session.containerID]?.isEmpty == false
        if !hasRemainingRuns {
            activeRunSessionIDsByContainerID.removeValue(forKey: session.containerID)
            mark(session.containerID, as: session.outcome == .succeeded ? .succeeded : .failed)
        }
        refreshInstalledPrograms(for: session.containerID)
        Task {
            await refreshContainerSession(for: session.containerID)
        }
        logLines.insert(
            LogLine(
                containerID: session.containerID,
                level: session.outcome == .succeeded ? "info" : "error",
                source: session.containerName,
                message: "Runner exited with code \(session.exitCode.map(String.init) ?? "unknown")."
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
        guard let index = containers.firstIndex(where: { $0.id == containerID }) else { return }
        mutation(&containers[index])
        containers[index].lastModified = Date()
        persistLibrary()
    }

    private func nextContainerName() -> String {
        let baseName = "New Container"
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
