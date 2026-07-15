import AppCore
import Darwin
import Foundation

enum WinePrefixSessionState {
    case active
    case inactive
    case unavailable
}

enum SwitchyardRunnerClientError: Error, CustomStringConvertible {
    case missingRunner
    case couldNotEncodePlan
    case couldNotListWindowsProcesses(Int32)

    var description: String {
        switch self {
        case .missingRunner:
            "switchyard-runner helper was not found in the app bundle or build directory."
        case .couldNotEncodePlan:
            "Command plan could not be serialized for the runner."
        case let .couldNotListWindowsProcesses(status):
            "Running Windows applications could not be inspected (exit code \(status))."
        }
    }
}

final class SwitchyardRunnerClient: @unchecked Sendable {
    private var processes: [UUID: Process] = [:]
    private let lock = NSLock()

    func runnerURL() throws -> URL {
        try locateRunner()
    }

    func prefixSessionState(winePath: String, prefixPath: String) -> WinePrefixSessionState {
        guard let runnerURL = try? locateRunner() else { return .unavailable }

        let process = Process()
        process.executableURL = runnerURL
        process.arguments = ["probe-prefix", "--wine", winePath, "--prefix", prefixPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unavailable
        }

        switch process.terminationStatus {
        case 0:
            return .active
        case 1:
            return .inactive
        default:
            return .unavailable
        }
    }

    func runningWindowsExecutablePaths(winePath: String, prefixPath: String) throws -> [String] {
        let runnerURL = try locateRunner()
        let process = Process()
        let output = Pipe()
        process.executableURL = runnerURL
        process.arguments = ["list-processes", "--wine", winePath, "--prefix", prefixPath]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerClientError.couldNotListWindowsProcesses(process.terminationStatus)
        }
        return try JSONDecoder().decode([String].self, from: data)
    }

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
        do {
            try data.write(to: planURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: planURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: planURL)
            throw error
        }

        let process = Process()
        process.executableURL = runnerURL
        process.arguments = ["run", "--plan", planURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutStream = ProcessLogStream(
            handle: stdout.fileHandleForReading,
            level: "info",
            source: containerName,
            onLog: onLog
        )
        let stderrStream = ProcessLogStream(
            handle: stderr.fileHandleForReading,
            level: "error",
            source: containerName,
            onLog: onLog
        )
        process.standardOutput = stdout
        process.standardError = stderr

        stdoutStream.start()
        stderrStream.start()

        process.terminationHandler = { [weak self] process in
            stdoutStream.finish()
            stderrStream.finish()
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
            stdoutStream.cancel()
            stderrStream.cancel()
            removeProcess(session.id)
            try? FileManager.default.removeItem(at: planURL)
            throw error
        }
        return session
    }

    func deliverURLCallback(
        _ request: WineURLCallbackRequest,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        let runnerURL = try locateRunner()
        let requestURL = try writeProtectedCallbackRequest(request)
        let processID = UUID()
        let process = Process()
        process.executableURL = runnerURL
        process.arguments = ["open-url", "--request", requestURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            try? FileManager.default.removeItem(at: requestURL)
            self?.removeProcess(processID)
            onExit(process.terminationStatus)
        }

        store(process, for: processID)
        do {
            try process.run()
        } catch {
            removeProcess(processID)
            try? FileManager.default.removeItem(at: requestURL)
            throw error
        }
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

    private func writeProtectedCallbackRequest(_ request: WineURLCallbackRequest) throws -> URL {
        let rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("ProtocolBridge", isDirectory: true)
        let requestsURL = rootURL.appendingPathComponent("Requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requestsURL, withIntermediateDirectories: true)
        guard Darwin.chmod(requestsURL.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(.EACCES)
        }

        let requestURL = requestsURL.appendingPathComponent("\(UUID().uuidString).json")
        do {
            try JSONEncoder().encode(request).write(to: requestURL, options: [.atomic])
            guard Darwin.chmod(requestURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw POSIXError(.EACCES)
            }
        } catch {
            try? FileManager.default.removeItem(at: requestURL)
            throw error
        }
        return requestURL
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

private final class ProcessLogStream: @unchecked Sendable {
    private let handle: FileHandle
    private let level: String
    private let source: String
    private let onLog: @Sendable (LogLine) -> Void
    private let lock = NSLock()
    private let accumulator = LogStreamAccumulator()
    private var isFinished = false

    init(
        handle: FileHandle,
        level: String,
        source: String,
        onLog: @escaping @Sendable (LogLine) -> Void
    ) {
        self.handle = handle
        self.level = level
        self.source = source
        self.onLog = onLog
    }

    func start() {
        handle.readabilityHandler = { [weak self] _ in
            self?.consumeAvailableData()
        }
    }

    func finish() {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        emit(handle.readDataToEndOfFile(), finish: true)
        isFinished = true
    }

    func cancel() {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        emit(Data(), finish: true)
        isFinished = true
    }

    private func consumeAvailableData() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        let data = handle.availableData
        let reachedEnd = data.isEmpty
        emit(data, finish: reachedEnd)
        if reachedEnd {
            handle.readabilityHandler = nil
            isFinished = true
        }
    }

    private func emit(_ data: Data, finish: Bool) {
        for line in accumulator.consume(data, finish: finish) {
            onLog(LogLine(level: level, source: source, message: line))
        }
    }
}

private final class LogStreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false

    func consume(_ data: Data, finish: Bool) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return [] }

        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            appendDecodedLine(lineData, to: &lines)
        }

        if finish {
            appendDecodedLine(buffer[...], to: &lines)
            buffer.removeAll(keepingCapacity: false)
            isFinished = true
        }
        return lines
    }

    private func appendDecodedLine(_ data: Data.SubSequence, to lines: inout [String]) {
        var line = String(decoding: data, as: UTF8.self)
        if line.last == "\r" {
            line.removeLast()
        }
        if !line.isEmpty {
            lines.append(line)
        }
    }
}
