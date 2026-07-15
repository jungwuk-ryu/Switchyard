import AppCore
import Darwin
import Foundation

private enum SwitchyardRunnerError: LocalizedError {
    case missingWineServer(String)
    case invalidURLCallbackRequest
    case urlCallbackTimedOut
    case wineServerCommandFailed(arguments: [String], status: Int32, output: String)
    case wineServerCommandTimedOut(arguments: [String])
    case terminationRequested

    var errorDescription: String? {
        switch self {
        case let .missingWineServer(path):
            "Cannot replace the existing Wine prefix session because wineserver was not found next to \(path)."
        case .invalidURLCallbackRequest:
            "The Wine URL callback request was invalid."
        case .urlCallbackTimedOut:
            "The Wine URL callback did not finish within 15 seconds."
        case let .wineServerCommandFailed(arguments, status, output):
            "wineserver \(arguments.joined(separator: " ")) failed with status \(status): \(output)"
        case let .wineServerCommandTimedOut(arguments):
            "wineserver \(arguments.joined(separator: " ")) did not finish within 15 seconds."
        case .terminationRequested:
            "Runner termination was requested before the child process started."
        }
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var isFinished = false

    func consumeAvailableData(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        data.append(handle.availableData)
    }

    func finish(from handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        data.append(handle.readDataToEndOfFile())
        isFinished = true
    }

    func cancel(from handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.lock()
        isFinished = true
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private let wineServerCommandTimeout: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_WINESERVER_TIMEOUT"],
          let seconds = TimeInterval(value),
          seconds > 0 else {
        return 15
    }
    return seconds
}()

private let outputDrainTimeout: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_OUTPUT_DRAIN_TIMEOUT"],
          let seconds = TimeInterval(value),
          seconds > 0 else {
        return 1
    }
    return seconds
}()

private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func consume(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer += chunk
        guard !buffer.isEmpty else { return [] }

        let lines = buffer.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        if buffer.last == "\n" {
            buffer.removeAll(keepingCapacity: true)
            return lines
        }

        let completeLines = lines.dropLast()
        buffer = lines.last ?? ""
        return Array(completeLines)
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        return pending
    }
}

private final class DebugLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var isClosed = false

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if Darwin.chmod(directory.path, mode_t(S_IRWXU)) != 0 {
            throw Self.posixError(operation: "protect debug log directory")
        }

        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Self.posixError(operation: "open debug log")
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let error = Self.posixError(operation: "protect debug log")
            Darwin.close(descriptor)
            throw error
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func write(source: String, level: String, message: String) {
        guard let data = "[\(source)] [\(level)] \(message)\n".data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        handle.write(data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        try? handle.synchronize()
        try? handle.close()
        isClosed = true
    }

    private static func posixError(operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

private final class RunnerProcessRegistry: @unchecked Sendable {
    static let shared = RunnerProcessRegistry()

    private let lock = NSLock()
    private var process: Process?
    private var terminationSignal: Int32?

    func launch(_ process: Process) throws {
        lock.lock()
        guard terminationSignal == nil else {
            lock.unlock()
            throw SwitchyardRunnerError.terminationRequested
        }
        self.process = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            lock.unlock()
            throw error
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func requestTermination(signalNumber: Int32) -> Int32 {
        lock.lock()
        if terminationSignal == nil {
            terminationSignal = signalNumber
        }
        let exitStatus = 128 + (terminationSignal ?? signalNumber)
        let activeProcess = process
        lock.unlock()

        if let activeProcess {
            stopProcessWithinDeadline(activeProcess)
        }
        return exitStatus
    }

    var requestedExitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return terminationSignal.map { 128 + $0 }
    }
}

private func runnerExit(_ status: Int32) -> Never {
    Foundation.exit(RunnerProcessRegistry.shared.requestedExitStatus ?? status)
}

private final class TerminationSignalMonitor {
    private let sources: [DispatchSourceSignal]

    init() {
        sources = [SIGTERM, SIGINT].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler {
                let status = RunnerProcessRegistry.shared.requestTermination(signalNumber: signalNumber)
                Foundation.exit(status)
            }
            source.resume()
            return source
        }
    }

    deinit {
        for source in sources {
            source.cancel()
        }
    }
}

@main
struct SwitchyardRunner {
    static func main() {
        let signalMonitor = TerminationSignalMonitor()

        withExtendedLifetime(signalMonitor) {
            runCommand()
        }
    }

    private static func runCommand() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            runnerExit(2)
        }

        switch arguments[0] {
        case "diagnose":
            print("switchyard-runner ok")
        case "probe-prefix":
            probePrefix(arguments: Array(arguments.dropFirst()))
        case "open-url":
            do {
                try openURL(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("switchyard-runner failed to deliver a URL callback: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "run":
            do {
                try run(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("switchyard-runner failed: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        default:
            printUsage()
            runnerExit(2)
        }
    }

    private static func run(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--plan" else {
            printUsage()
            runnerExit(2)
        }

        let planURL = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: planURL)
        let plan = try JSONDecoder().decode(CommandPlan.self, from: data)
        let debugLogWriter = openDebugLogWriter(path: plan.debugLogPath, source: plan.logSource)
        defer { debugLogWriter?.close() }
        let environmentKeys = plan.environment.keys.sorted().joined(separator: ",")
        emit(
            source: plan.logSource,
            level: "info",
            message: "switchyard-runner start: executable=\(plan.executable) argumentCount=\(plan.arguments.count)",
            logWriter: debugLogWriter
        )
        emit(
            source: plan.logSource,
            level: "info",
            message: "environment-keys=\(environmentKeys)",
            logWriter: debugLogWriter
        )

        if plan.terminateExistingPrefixSession == true {
            try terminateExistingPrefixSession(plan: plan)
        }
        startProtocolAssociationMonitor(plan: plan)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        if let workingDirectory = plan.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutBuffer = LineAccumulator()
        let stderrBuffer = LineAccumulator()
        try RunnerProcessRegistry.shared.launch(process)
        let outputGroup = DispatchGroup()
        streamOutput(
            from: stdout.fileHandleForReading,
            source: plan.logSource,
            level: "info",
            to: FileHandle.standardOutput,
            accumulator: stdoutBuffer,
            logWriter: debugLogWriter,
            group: outputGroup
        )
        streamOutput(
            from: stderr.fileHandleForReading,
            source: plan.logSource,
            level: "error",
            to: FileHandle.standardError,
            accumulator: stderrBuffer,
            logWriter: debugLogWriter,
            group: outputGroup
        )
        process.waitUntilExit()
        RunnerProcessRegistry.shared.clear(process)
        if outputGroup.wait(timeout: .now() + outputDrainTimeout) == .timedOut {
            emit(
                source: plan.logSource,
                level: "warning",
                message: "output drain timed out after the launched process exited; a descendant may still hold its output streams open",
                logWriter: debugLogWriter
            )
        }
        emit(
            source: plan.logSource,
            level: "info",
            message: "switchyard-runner exit: status=\(process.terminationStatus)",
            logWriter: debugLogWriter
        )
        debugLogWriter?.close()
        runnerExit(process.terminationStatus)
    }

    private static func startProtocolAssociationMonitor(plan: CommandPlan) {
        guard plan.environment[WineProtocolAssociationFormat.manifestEnvironmentKey]?.isEmpty == false else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = ["winemenubuilder.exe", "-m"]
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        if let workingDirectory = plan.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func probePrefix(arguments: [String]) {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix" else {
            printUsage()
            runnerExit(2)
        }

        guard let wineServerURL = wineServerURL(forWineExecutable: arguments[1]) else {
            runnerExit(2)
        }

        do {
            let isActive = try winePrefixSessionIsActive(
                wineServerURL: wineServerURL,
                prefixPath: arguments[3]
            )
            runnerExit(isActive ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("Unable to inspect Wine prefix session: \(error)\n".utf8))
            runnerExit(2)
        }
    }

    private static func openURL(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--request" else {
            throw SwitchyardRunnerError.invalidURLCallbackRequest
        }

        let requestURL = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: requestURL)
        try? FileManager.default.removeItem(at: requestURL)
        let request = try JSONDecoder().decode(WineURLCallbackRequest.self, from: data)
        guard let scheme = WineProtocolAssociationFormat.scheme(inRawURL: request.rawURL),
              scheme == request.scheme,
              FileManager.default.isExecutableFile(atPath: request.winePath),
              FileManager.default.fileExists(atPath: request.prefixPath) else {
            throw SwitchyardRunnerError.invalidURLCallbackRequest
        }

        let environment = ProcessInfo.processInfo.environment.merging([
            "WINEPREFIX": request.prefixPath,
            WineProtocolAssociationFormat.manifestEnvironmentKey: WineProtocolAssociationFormat.windowsManifestPath
        ]) { _, new in new }
        synchronizeUserProtocolRegistration(
            scheme: scheme,
            winePath: request.winePath,
            prefixPath: request.prefixPath,
            environment: environment
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.winePath)
        process.arguments = ["start", request.rawURL]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: request.prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)

        guard waitForExit(process, timeout: 15) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.urlCallbackTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.wineServerCommandFailed(
                arguments: ["start"],
                status: process.terminationStatus,
                output: ""
            )
        }
    }

    private static func synchronizeUserProtocolRegistration(
        scheme: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = [
            "reg", "copy",
            "HKCU\\Software\\Classes\\\(scheme)",
            "HKCR\\\(scheme)",
            "/s", "/f"
        ]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }

        do {
            try RunnerProcessRegistry.shared.launch(process)
        } catch {
            return
        }
        guard waitForExit(process, timeout: 15) else {
            stopProcessWithinDeadline(process)
            return
        }
    }

    private static func printUsage() {
        FileHandle.standardError.write(
            Data("usage: switchyard-runner diagnose | probe-prefix --wine <path> --prefix <path> | open-url --request <request.json> | run --plan <command-plan.json>\n".utf8)
        )
    }
}

private func terminateExistingPrefixSession(plan: CommandPlan) throws {
    guard let wineServerURL = wineServerURL(forWineExecutable: plan.executable) else {
        throw SwitchyardRunnerError.missingWineServer(plan.executable)
    }

    FileHandle.standardOutput.write(
        Data("[\(plan.logSource)] Stopping any existing Wine session for this prefix before relaunch.\n".utf8)
    )

    let environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
    try runWineServer(
        at: wineServerURL,
        arguments: ["-k"],
        environment: environment,
        acceptedExitStatuses: [0, 1]
    )
    try runWineServer(at: wineServerURL, arguments: ["-w"], environment: environment)
}

private func wineServerURL(forWineExecutable path: String) -> URL? {
    let wineURL = URL(fileURLWithPath: path)
    let candidates = [
        wineURL.deletingLastPathComponent().appendingPathComponent("wineserver"),
        wineURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("wineserver")
    ]

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func winePrefixSessionIsActive(wineServerURL: URL, prefixPath: String) throws -> Bool {
    let process = Process()
    process.executableURL = wineServerURL
    process.arguments = ["-w"]
    process.environment = ProcessInfo.processInfo.environment.merging(["WINEPREFIX": prefixPath]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    defer { RunnerProcessRegistry.shared.clear(process) }
    try RunnerProcessRegistry.shared.launch(process)

    if waitForExit(process, timeout: 0.25) {
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.wineServerCommandFailed(
                arguments: ["-w"],
                status: process.terminationStatus,
                output: ""
            )
        }
        return false
    }

    stopProcessWithinDeadline(process)
    return true
}

private func runWineServer(
    at url: URL,
    arguments: [String],
    environment: [String: String],
    acceptedExitStatuses: Set<Int32> = [0]
) throws {
    let process = Process()
    let output = Pipe()
    let outputCollector = ProcessOutputCollector()
    process.executableURL = url
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    output.fileHandleForReading.readabilityHandler = { handle in
        outputCollector.consumeAvailableData(from: handle)
    }
    defer { RunnerProcessRegistry.shared.clear(process) }
    do {
        try RunnerProcessRegistry.shared.launch(process)
    } catch {
        outputCollector.cancel(from: output.fileHandleForReading)
        throw error
    }

    guard waitForExit(process, timeout: wineServerCommandTimeout) else {
        stopProcessWithinDeadline(process)
        outputCollector.finish(from: output.fileHandleForReading)
        throw SwitchyardRunnerError.wineServerCommandTimedOut(arguments: arguments)
    }

    outputCollector.finish(from: output.fileHandleForReading)
    guard acceptedExitStatuses.contains(process.terminationStatus) else {
        throw SwitchyardRunnerError.wineServerCommandFailed(
            arguments: arguments,
            status: process.terminationStatus,
            output: outputCollector.text
        )
    }
}

private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return !process.isRunning
}

private func stopProcessWithinDeadline(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    if waitForExit(process, timeout: 0.5) {
        return
    }

    Darwin.kill(process.processIdentifier, SIGKILL)
    _ = waitForExit(process, timeout: 0.5)
}

private func emitLine(
    source: String,
    level: String,
    message: String,
    outputHandle: FileHandle,
    logWriter: DebugLogWriter?
) {
    let text = "[\(source)] \(message)"
    outputHandle.write(Data((text + "\n").utf8))
    emit(source: source, level: level, message: message, logWriter: logWriter)
}

private func emit(
    source: String,
    level: String,
    message: String,
    logWriter: DebugLogWriter?
) {
    logWriter?.write(source: source, level: level, message: message)
}

private func openDebugLogWriter(path: String?, source: String) -> DebugLogWriter? {
    guard let path else { return nil }
    do {
        let writer = try DebugLogWriter(path: path)
        writer.write(source: source, level: "info", message: "created protected debug log")
        return writer
    } catch {
        FileHandle.standardError.write(Data("[\(source)] Unable to open switchyard debug log file: \(error)\n".utf8))
        return nil
    }
}

private func streamOutput(
    from inputHandle: FileHandle,
    source: String,
    level: String,
    to outputHandle: FileHandle,
    accumulator: LineAccumulator,
    logWriter: DebugLogWriter?,
    group: DispatchGroup
) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        defer {
            if let tail = accumulator.flush(), !tail.isEmpty {
                emitLine(
                    source: source,
                    level: level,
                    message: tail,
                    outputHandle: outputHandle,
                    logWriter: logWriter
                )
            }
            group.leave()
        }

        while true {
            let data = inputHandle.availableData
            guard !data.isEmpty else { break }
            let chunk = String(decoding: data, as: UTF8.self)
            for line in accumulator.consume(chunk) where !line.isEmpty {
                emitLine(
                    source: source,
                    level: level,
                    message: line,
                    outputHandle: outputHandle,
                    logWriter: logWriter
                )
            }
        }
    }
}
