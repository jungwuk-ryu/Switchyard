import AppCore
import Darwin
import Foundation

enum WinePrefixSessionState: Equatable {
    case active
    case orphaned
    case inactive
    case unavailable
}

enum SwitchyardRunnerClientError: Error, CustomStringConvertible {
    case missingRunner
    case couldNotEncodePlan
    case couldNotListWindowsProcesses(Int32)
    case couldNotStopWineServer(Int32, String)

    var description: String {
        switch self {
        case .missingRunner:
            String(
                localized: "switchyard-runner helper was not found in the app bundle or build directory.",
                bundle: SwitchyardStrings.bundle
            )
        case .couldNotEncodePlan:
            String(
                localized: "Command plan could not be serialized for the runner.",
                bundle: SwitchyardStrings.bundle
            )
        case let .couldNotListWindowsProcesses(status):
            String(
                localized: "Running Windows applications could not be inspected (exit code \(status)).",
                bundle: SwitchyardStrings.bundle
            )
        case let .couldNotStopWineServer(status, detail):
            detail.isEmpty
                ? String(
                    localized: "wineserver could not be stopped (exit code \(status)).",
                    bundle: SwitchyardStrings.bundle
                )
                : String(
                    localized: "wineserver could not be stopped (exit code \(status)): \(detail)",
                    bundle: SwitchyardStrings.bundle
                )
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
        case 3:
            return .orphaned
        default:
            return .unavailable
        }
    }

    func hostProcessPrefixSessionState(
        winePath: String,
        prefixPath: String
    ) -> WinePrefixSessionState {
        guard let runnerURL = try? locateRunner() else { return .unavailable }

        let process = Process()
        process.executableURL = runnerURL
        process.arguments = ["probe-prefix-host", "--wine", winePath, "--prefix", prefixPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unavailable
        }

        switch process.terminationStatus {
        case 1:
            return .inactive
        case 3:
            return .orphaned
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

    func stopWineServer(winePath: String, prefixPath: String) throws {
        let runnerURL = try locateRunner()
        let process = Process()
        let errorOutput = Pipe()
        process.executableURL = runnerURL
        process.arguments = ["stop-prefix", "--wine", winePath, "--prefix", prefixPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput
        try process.run()
        let data = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SwitchyardRunnerClientError.couldNotStopWineServer(
                process.terminationStatus,
                detail
            )
        }
    }

    func launch(
        _ plan: CommandPlan,
        containerID: UUID,
        containerName: String,
        onLogs: @escaping @Sendable ([LogLine]) -> Void,
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

        let logCapture: ProcessLogCapture?
        if plan.liveLogPath == nil {
            let capture = ProcessLogCapture(
                containerID: containerID,
                source: containerName,
                onLogs: onLogs
            )
            capture.configure(process)
            capture.start()
            logCapture = capture
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            logCapture = nil
        }

        process.terminationHandler = { [weak self] process in
            logCapture?.finish()
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
            logCapture?.cancel()
            removeProcess(session.id)
            try? FileManager.default.removeItem(at: planURL)
            throw error
        }
        return session
    }

    func launchAndWait(
        _ plan: CommandPlan,
        containerID: UUID,
        containerName: String,
        onLogs: @escaping @Sendable ([LogLine]) -> Void
    ) async throws -> RunSession {
        try await withCheckedThrowingContinuation { continuation in
            do {
                _ = try launch(
                    plan,
                    containerID: containerID,
                    containerName: containerName,
                    onLogs: onLogs,
                    onExit: { session in
                        continuation.resume(returning: session)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
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

private final class ProcessLogCapture: @unchecked Sendable {
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let batcher: ProcessLogBatcher
    private let stdoutStream: ProcessLogStream
    private let stderrStream: ProcessLogStream

    init(
        containerID: UUID,
        source: String,
        onLogs: @escaping @Sendable ([LogLine]) -> Void
    ) {
        let batcher = ProcessLogBatcher(
            containerID: containerID,
            source: source,
            onLogs: onLogs
        )
        self.batcher = batcher
        stdoutStream = ProcessLogStream(
            handle: stdout.fileHandleForReading,
            level: "info",
            containerID: containerID,
            source: source,
            batcher: batcher
        )
        stderrStream = ProcessLogStream(
            handle: stderr.fileHandleForReading,
            level: "error",
            containerID: containerID,
            source: source,
            batcher: batcher
        )
    }

    func configure(_ process: Process) {
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() {
        stdoutStream.start()
        stderrStream.start()
    }

    func finish() {
        stdoutStream.finish()
        stderrStream.finish()
        batcher.finish()
    }

    func cancel() {
        stdoutStream.cancel()
        stderrStream.cancel()
        batcher.finish()
    }
}

private final class ProcessLogStream: @unchecked Sendable {
    private let handle: FileHandle
    private let level: String
    private let containerID: UUID
    private let source: String
    private let batcher: ProcessLogBatcher
    private let lock = NSLock()
    private let accumulator = LogStreamAccumulator()
    private var isFinished = false

    init(
        handle: FileHandle,
        level: String,
        containerID: UUID,
        source: String,
        batcher: ProcessLogBatcher
    ) {
        self.handle = handle
        self.level = level
        self.containerID = containerID
        self.source = source
        self.batcher = batcher
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
        let logs = accumulator.consume(data, finish: finish).map { line in
            LogLine(
                containerID: containerID,
                level: ProcessLogLevelPolicy.normalizedLevel(
                    for: line,
                    fallbackLevel: level
                ),
                source: source,
                message: line
            )
        }
        batcher.append(logs)
    }
}

final class ProcessLogBatcher: @unchecked Sendable {
    private let containerID: UUID
    private let source: String
    private let onLogs: @Sendable ([LogLine]) -> Void
    private let flushInterval: TimeInterval
    private let maximumPendingLineCount: Int
    private let queue = DispatchQueue(label: "dev.switchyard.live-log-batcher", qos: .utility)
    private var pending: [LogLine] = []
    private var omittedLineCount = 0
    private var isFlushScheduled = false
    private var isFinished = false

    init(
        containerID: UUID,
        source: String,
        flushInterval: TimeInterval = 0.25,
        maximumPendingLineCount: Int = 2_048,
        onLogs: @escaping @Sendable ([LogLine]) -> Void
    ) {
        self.containerID = containerID
        self.source = source
        self.flushInterval = flushInterval
        self.maximumPendingLineCount = max(1, maximumPendingLineCount)
        self.onLogs = onLogs
    }

    func append(_ logs: [LogLine]) {
        guard !logs.isEmpty else { return }
        queue.async { [weak self] in
            self?.enqueue(logs)
        }
    }

    func finish() {
        queue.sync {
            isFinished = true
            drain()
        }
    }

    private func enqueue(_ logs: [LogLine]) {
        guard !isFinished else { return }

        let overflow = pending.count + logs.count - maximumPendingLineCount
        if overflow > 0 {
            omittedLineCount += overflow
            if logs.count >= maximumPendingLineCount {
                pending.removeAll(keepingCapacity: true)
                pending.append(contentsOf: logs.suffix(maximumPendingLineCount))
            } else {
                pending.removeFirst(min(overflow, pending.count))
                pending.append(contentsOf: logs)
            }
        } else {
            pending.append(contentsOf: logs)
        }

        let shouldScheduleFlush = !isFlushScheduled
        isFlushScheduled = true

        if shouldScheduleFlush {
            queue.asyncAfter(
                deadline: .now() + flushInterval
            ) { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        var logs = pending
        pending.removeAll(keepingCapacity: true)
        let omitted = omittedLineCount
        omittedLineCount = 0
        isFlushScheduled = false

        if omitted > 0 {
            let omittedEntryMessage = String(
                localized: "\(omitted) high-volume log entries were omitted from the live view; the protected per-run debug log retains the complete output when developer logging is enabled.",
                bundle: SwitchyardStrings.bundle
            )
            logs.append(
                LogLine(
                    containerID: containerID,
                    level: "warning",
                    source: source,
                    message: omittedEntryMessage
                )
            )
        }
        if !logs.isEmpty {
            onLogs(logs)
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
        var lineStart = buffer.startIndex
        while lineStart < buffer.endIndex,
              let newlineIndex = buffer[lineStart...].firstIndex(of: 0x0A) {
            let lineData = buffer[lineStart..<newlineIndex]
            appendDecodedLine(lineData, to: &lines)
            lineStart = buffer.index(after: newlineIndex)
        }
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
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
