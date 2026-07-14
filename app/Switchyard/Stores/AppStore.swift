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

private let debugRunLogRetentionInterval: TimeInterval = 14 * 24 * 60 * 60
private let maximumRetainedDebugRunLogs = 50

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
    @Published private(set) var installedProgramsByContainerID: [UUID: [InstalledProgram]] = [:]
    @Published var containers: [Container]
    @Published var logLines: [LogLine] = []
    @AppStorage("developerLogging") private var developerLogging = false

    private let jobEngine = JobEngine()
    private let runnerClient = SwitchyardRunnerClient()
    private let defaults = UserDefaults.standard
    private let wineSourcePolicy = SwitchyardWineSourcePolicy.load()
    private let debugLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
    private var diagnosticsTask: Task<Void, Never>?
    private var installedProgramTasks: [UUID: Task<Void, Never>] = [:]

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

        persistLibrary()
        pruneDebugRunLogs(in: debugRunLogRoot)
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

    func chooseExecutableAndRun(in containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerBusy(containerID) else {
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
        containers.contains { $0.id == containerID && $0.status == .running }
    }

    func isContainerBusy(_ containerID: UUID) -> Bool {
        launchingContainerIDs.contains(containerID) || isContainerRunning(containerID)
    }

    func openContainerInFinder(_ containerID: UUID) {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: container.path, isDirectory: true)])
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
        installedProgramTasks[containerID]?.cancel()
        installedProgramTasks.removeValue(forKey: containerID)
        installedProgramsByContainerID.removeValue(forKey: containerID)
        selectedContainerID = containers.first?.id
        persistLibrary()
    }

    private func runSelectedContainer(containerID: UUID) async {
        await runContainer(containerID: containerID, executablePath: nil, executableArguments: [])
    }

    private func runContainer(containerID: UUID, executablePath: String?, executableArguments: [String]) async {
        guard let container = containers.first(where: { $0.id == containerID }) else { return }
        guard !isContainerBusy(containerID) else {
            logLines.insert(LogLine(level: "warning", source: "containers", message: "Wait for \(container.name) to finish launching before starting another executable."), at: 0)
            return
        }

        guard runtimeStatus.canLaunch else {
            appendFailedRun(for: container, message: runtimeStatus.summary)
            return
        }

        var terminateExistingPrefixSession = false
        if executablePath == nil {
            switch runnerClient.prefixSessionState(
                winePath: currentRuntime.winePath,
                prefixPath: container.path
            ) {
            case .active:
                guard confirmRestartOfExistingPrefixSession(for: container) else { return }
                terminateExistingPrefixSession = true
            case .inactive:
                break
            case .unavailable:
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

        launchingContainerIDs.insert(containerID)
        defer {
            launchingContainerIDs.remove(containerID)
        }

        let fontPreparationLog = await prepareOpenFontsForLaunch(for: container)
        logLines.insert(fontPreparationLog, at: 0)

        do {
            let launchedExecutable = executablePath ?? container.executablePath ?? "configured executable"
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
            _ = try runnerClient.launch(
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
            mark(container.id, as: .running)
            let executableName = launchedExecutable
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .last
                .map(String.init) ?? "configured executable"
            logLines.insert(
                LogLine(
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

    private func prepareOpenFontsForLaunch(for container: Container) async -> LogLine {
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
        containers.contains { $0.status == .running }
    }

    func stopAllRuns() {
        let runningContainers = containers.filter { $0.status == .running }
        runnerClient.stopAll()

        for container in runningContainers {
            mark(container.id, as: .failed)
            logLines.insert(
                LogLine(level: "warning", source: container.name, message: "Stop requested for this container."),
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
        logLines.insert(LogLine(level: "error", source: container.name, message: message), at: 0)
    }

    nonisolated private static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func completeRunSession(_ session: RunSession) {
        mark(session.containerID, as: session.outcome == .succeeded ? .succeeded : .failed)
        refreshInstalledPrograms(for: session.containerID)
        logLines.insert(
            LogLine(
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

    private static func initialLibrarySnapshot(libraryPath: String) -> SwitchyardContainerSnapshot {
        let store = LibraryManifestStore(rootURL: URL(fileURLWithPath: libraryPath, isDirectory: true))
        if let loaded = try? store.loadSnapshot(), !loaded.containers.isEmpty {
            return loaded
        }

        return SwitchyardContainerSnapshot(containers: [])
    }
}
