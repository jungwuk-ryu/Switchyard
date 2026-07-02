import AppCore
import Foundation
import JobEngine
import Persistence
import RuntimeCatalog
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var selectedSection: SidebarSelection = .gamesLaunchers
    @Published var selectedLauncherID: UUID?
    @Published var selectedLogSessionID: UUID?
    @Published var showInspector = true
    @Published var hasCompletedSetup: Bool
    @Published var libraryPath: String
    @Published var gptkPath: String
    @Published var winePath: String
    @Published private(set) var runtimeStatus = RuntimeStatus()
    @Published private(set) var diagnostics: [DiagnosticCheck] = []
    @Published var bottles: [Bottle]
    @Published var launchers: [Launcher]
    @Published var operations: [InstallJob] = []
    @Published var runSessions: [RunSession] = []
    @Published var logLines: [LogLine] = []

    private let jobEngine = JobEngine()
    private let runnerClient = SwitchyardRunnerClient()
    private let defaults = UserDefaults.standard
    private var diagnosticsTask: Task<Void, Never>?

    init() {
        let defaultLibrary = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .path ?? ""

        let initialLibraryPath = defaults.string(forKey: "libraryPath") ?? defaultLibrary
        libraryPath = initialLibraryPath
        gptkPath = defaults.string(forKey: "gptkPath") ?? ""
        winePath = defaults.string(forKey: "winePath") ?? RuntimeLocator().defaultWineRuntimePath()
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")

        let snapshot = Self.initialLibrarySnapshot(libraryPath: initialLibraryPath)
        bottles = snapshot.bottles
        launchers = snapshot.launchers
        selectedLauncherID = launchers.first?.id
        selectedLogSessionID = nil

        persistLibrary()
    }

    var selectedLauncher: Launcher? {
        guard let selectedLauncherID else { return launchers.first }
        return launchers.first(where: { $0.id == selectedLauncherID })
    }

    var selectedBottle: Bottle? {
        guard let selectedLauncher else { return nil }
        return bottles.first(where: { $0.id == selectedLauncher.bottleID })
    }

    var currentRuntime: RuntimeBuild {
        RuntimeBuild(
            id: "local-source-cache",
            winePath: winePath,
            patchsetID: "switchyard-v1",
            sourceRevision: "third_party/wine"
        )
    }

    private var libraryStore: LibraryManifestStore {
        LibraryManifestStore(rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true))
    }

    private var patchSeriesPath: String {
        if let bundledPath = Bundle.main.resourceURL?
            .appendingPathComponent("patches/wine/series")
            .path,
            FileManager.default.fileExists(atPath: bundledPath) {
            return bundledPath
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("patches/wine/series")
            .path
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
        let patchSeriesPath = patchSeriesPath
        diagnosticsTask = Task { [gptkPath, winePath, patchSeriesPath] in
            let result = await Task.detached(priority: .userInitiated) {
                RuntimeLocator().diagnose(gptkPath: gptkPath, winePath: winePath, patchSeriesPath: patchSeriesPath)
            }.value

            guard !Task.isCancelled else { return }
            runtimeStatus = result.0
            diagnostics = result.1
        }
    }

    func addLauncher() {
        let bottle = Bottle(
            name: "New Launcher",
            path: URL(fileURLWithPath: libraryPath).appendingPathComponent("NewLauncher.bottle", isDirectory: true).path,
            wineBuildID: currentRuntime.id,
            patchsetID: currentRuntime.patchsetID,
            gptkFingerprint: runtimeStatus.gptkFingerprint
        )
        bottles.append(bottle)
        let launcher = Launcher(name: "New Launcher", kind: .steam, bottleID: bottle.id, status: .needsSetup)
        launchers.append(launcher)
        selectedLauncherID = launcher.id
        selectedSection = .gamesLaunchers
        persistLibrary()
    }

    func runSelectedLauncher() {
        guard let launcher = selectedLauncher else { return }

        guard runtimeStatus.canLaunch else {
            appendFailedRun(for: launcher, message: runtimeStatus.summary)
            return
        }

        do {
            let plan = try jobEngine.runPlan(
                launcher: launcher,
                bottles: bottles,
                runtime: currentRuntime,
                gptkPath: gptkPath
            )
            let session = try runnerClient.launch(
                plan,
                launcherID: launcher.id,
                launcherName: launcher.name,
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
            mark(launcher.id, as: .running)
            runSessions.insert(session, at: 0)
            selectedLogSessionID = session.id
            logLines.insert(LogLine(level: "info", source: launcher.name, message: "Launch command started through switchyard-runner."), at: 0)
        } catch {
            appendFailedRun(for: launcher, message: "Could not create launch plan: \(error)")
        }
    }

    func stopRunningOperations() {
        for index in operations.indices where operations[index].state == .running {
            operations[index].state = .cancelled
        }
        runnerClient.stopAll()
        if let launcher = selectedLauncher, launcher.status == .running {
            mark(launcher.id, as: .failed)
            logLines.insert(LogLine(level: "warning", source: launcher.name, message: "Stop requested for selected launcher."), at: 0)
        }
    }

    func diagnosticBundle() -> DiagnosticBundle {
        DiagnosticBundle(runtimeStatus: runtimeStatus, checks: diagnostics, recentLogs: Array(logLines.prefix(50)))
    }

    private func appendFailedRun(for launcher: Launcher, message: String) {
        mark(launcher.id, as: .failed)
        let session = RunSession(
            launcherID: launcher.id,
            launcherName: launcher.name,
            endedAt: Date(),
            exitCode: 1,
            outcome: .failed
        )
        runSessions.insert(session, at: 0)
        selectedLogSessionID = session.id
        selectedSection = .logs
        logLines.insert(LogLine(level: "error", source: launcher.name, message: message), at: 0)
    }

    private func completeRunSession(_ session: RunSession) {
        if let index = runSessions.firstIndex(where: { $0.id == session.id }) {
            runSessions[index] = session
        } else {
            runSessions.insert(session, at: 0)
        }
        mark(session.launcherID, as: session.outcome == .succeeded ? .succeeded : .failed)
        logLines.insert(
            LogLine(
                level: session.outcome == .succeeded ? "info" : "error",
                source: session.launcherName,
                message: "Runner exited with code \(session.exitCode.map(String.init) ?? "unknown")."
            ),
            at: 0
        )
    }

    private func mark(_ launcherID: UUID, as status: LauncherStatus) {
        guard let index = launchers.firstIndex(where: { $0.id == launcherID }) else { return }
        launchers[index].status = status
        launchers[index].lastRun = Date()
        persistLibrary()
    }

    private func persistLibrary() {
        do {
            try libraryStore.save(SwitchyardLibrarySnapshot(bottles: bottles, launchers: launchers))
        } catch {
            logLines.insert(LogLine(level: "error", source: "persistence", message: "Could not save library manifest: \(error)"), at: 0)
        }
    }

    private static func initialLibrarySnapshot(libraryPath: String) -> SwitchyardLibrarySnapshot {
        let store = LibraryManifestStore(rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true))
        if let loaded = try? store.loadSnapshot(), !loaded.bottles.isEmpty, !loaded.launchers.isEmpty {
            return loaded
        }

        let steamBottle = Bottle(
            name: "Steam",
            path: URL(fileURLWithPath: libraryPath).appendingPathComponent("Steam.bottle", isDirectory: true).path,
            wineBuildID: "local-source-cache",
            patchsetID: "switchyard-v1"
        )
        let epicBottle = Bottle(
            name: "Epic Games",
            path: URL(fileURLWithPath: libraryPath).appendingPathComponent("Epic.bottle", isDirectory: true).path,
            wineBuildID: "local-source-cache",
            patchsetID: "switchyard-v1"
        )
        let gogBottle = Bottle(
            name: "GOG Galaxy",
            path: URL(fileURLWithPath: libraryPath).appendingPathComponent("GOG.bottle", isDirectory: true).path,
            wineBuildID: "local-source-cache",
            patchsetID: "switchyard-v1"
        )

        let launchers = [
            Launcher(name: "Steam", kind: .steam, bottleID: steamBottle.id, status: .needsSetup),
            Launcher(name: "Epic Games Launcher", kind: .epicGames, bottleID: epicBottle.id, status: .needsSetup),
            Launcher(name: "GOG Galaxy", kind: .gogGalaxy, bottleID: gogBottle.id, status: .needsSetup)
        ]

        return SwitchyardLibrarySnapshot(bottles: [steamBottle, epicBottle, gogBottle], launchers: launchers)
    }
}
