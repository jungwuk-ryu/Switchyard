import AppCore
import Foundation

enum SwitchyardRunnerClientError: Error, CustomStringConvertible {
    case missingRunner
    case couldNotEncodePlan

    var description: String {
        switch self {
        case .missingRunner:
            "switchyard-runner helper was not found in the app bundle or build directory."
        case .couldNotEncodePlan:
            "Command plan could not be serialized for the runner."
        }
    }
}

final class SwitchyardRunnerClient: @unchecked Sendable {
    private var processes: [UUID: Process] = [:]
    private let lock = NSLock()

    func launch(
        _ plan: CommandPlan,
        containerID: UUID,
        containerName: String,
        onLog: @escaping @Sendable (LogLine) -> Void,
        onExit: @escaping @Sendable (RunSession) -> Void
    ) throws -> RunSession {
        let runnerURL = try locateRunner()
        let session = RunSession(containerID: containerID, containerName: containerName, outcome: .running)
        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchyard-\(session.id.uuidString).json")

        guard let data = try? JSONEncoder().encode(plan) else {
            throw SwitchyardRunnerClientError.couldNotEncodePlan
        }
        try data.write(to: planURL, options: [.atomic])

        let process = Process()
        process.executableURL = runnerURL
        process.arguments = ["run", "--plan", planURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            emitLogs(from: handle, level: "info", source: containerName, onLog: onLog)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            emitLogs(from: handle, level: "error", source: containerName, onLog: onLog)
        }

        process.terminationHandler = { [weak self] process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: planURL)
            self?.removeProcess(session.id)

            let outcome: OperationState = process.terminationStatus == 0 ? .succeeded : .failed
            onExit(
                RunSession(
                    id: session.id,
                    containerID: containerID,
                    containerName: containerName,
                    startedAt: session.startedAt,
                    endedAt: Date(),
                    exitCode: process.terminationStatus,
                    outcome: outcome
                )
            )
        }

        store(process, for: session.id)
        do {
            try process.run()
        } catch {
            removeProcess(session.id)
            try? FileManager.default.removeItem(at: planURL)
            throw error
        }
        return session
    }

    func stopAll() {
        lock.lock()
        let activeProcesses = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        for process in activeProcesses where process.isRunning {
            process.terminate()
        }
    }

    private func locateRunner() throws -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("switchyard-runner")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        if let override = ProcessInfo.processInfo.environment["SWITCHYARD_RUNNER_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let buildFallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/switchyard-runner")
        if FileManager.default.isExecutableFile(atPath: buildFallback.path) {
            return buildFallback
        }

        throw SwitchyardRunnerClientError.missingRunner
    }

    private func store(_ process: Process, for sessionID: UUID) {
        lock.lock()
        processes[sessionID] = process
        lock.unlock()
    }

    private func removeProcess(_ sessionID: UUID) {
        lock.lock()
        processes.removeValue(forKey: sessionID)
        lock.unlock()
    }
}

private func emitLogs(
    from handle: FileHandle,
    level: String,
    source: String,
    onLog: @Sendable (LogLine) -> Void
) {
    let data = handle.availableData
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
        return
    }

    for line in text.split(whereSeparator: \.isNewline) {
        onLog(LogLine(level: level, source: source, message: String(line)))
    }
}
