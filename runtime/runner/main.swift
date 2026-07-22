import AppCore
import Darwin
import Foundation

private enum SwitchyardRunnerError: LocalizedError {
    case missingWineServer(String)
    case invalidURLCallbackRequest
    case urlCallbackTimedOut
    case urlCallbackCommandFailed(Int32)
    case wineServerCommandFailed(arguments: [String], status: Int32, output: String)
    case wineServerCommandTimedOut(arguments: [String])
    case wineProcessesCouldNotBeStopped([pid_t])
    case processInspectionFailed(Int32)
    case processInspectionTimedOut
    case terminationRequested

    var errorDescription: String? {
        switch self {
        case let .missingWineServer(path):
            "wineserver was not found next to the Wine executable at \(path)."
        case .invalidURLCallbackRequest:
            "The Wine URL callback request was invalid."
        case .urlCallbackTimedOut:
            "The Wine URL callback did not finish within 15 seconds."
        case let .urlCallbackCommandFailed(status):
            "The Wine URL callback command failed with status \(status)."
        case let .wineServerCommandFailed(arguments, status, output):
            "wineserver \(arguments.joined(separator: " ")) failed with status \(status): \(output)"
        case let .wineServerCommandTimedOut(arguments):
            "wineserver \(arguments.joined(separator: " ")) did not finish within 15 seconds."
        case let .wineProcessesCouldNotBeStopped(processIDs):
            "Wine processes for this prefix could not be stopped: \(processIDs.map(String.init).joined(separator: ", "))."
        case let .processInspectionFailed(status):
            "The Wine process list command failed with status \(status)."
        case .processInspectionTimedOut:
            "The Wine process list command did not finish within 15 seconds."
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

private let prefixProcessTerminationTimeout: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_PREFIX_PROCESS_TIMEOUT"],
          let seconds = TimeInterval(value),
          seconds > 0 else {
        return 2
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
    private var processes: [ObjectIdentifier: Process] = [:]
    private var terminationSignal: Int32?

    func launch(_ process: Process) throws {
        lock.lock()
        guard terminationSignal == nil else {
            lock.unlock()
            throw SwitchyardRunnerError.terminationRequested
        }
        let identifier = ObjectIdentifier(process)
        processes[identifier] = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            processes.removeValue(forKey: identifier)
            lock.unlock()
            throw error
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func requestTermination(signalNumber: Int32) -> Int32 {
        lock.lock()
        if terminationSignal == nil {
            terminationSignal = signalNumber
        }
        let exitStatus = 128 + (terminationSignal ?? signalNumber)
        let activeProcesses = Array(processes.values)
        lock.unlock()

        for activeProcess in activeProcesses {
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
        case "list-processes":
            do {
                try listProcesses(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("Unable to inspect Wine processes: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "stop-prefix":
            do {
                try stopPrefix(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("Unable to stop Wine prefix session: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
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
        var protocolMonitor = try startProtocolAssociationMonitor(plan: plan)
        defer {
            stopProtocolAssociationMonitor(&protocolMonitor)
        }

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
        stopProtocolAssociationMonitor(&protocolMonitor)
        runnerExit(process.terminationStatus)
    }

    private static func listProcesses(arguments: [String]) throws {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix" else {
            printUsage()
            runnerExit(2)
        }

        let prefixLock = try WinePrefixFileLock(
            prefixPath: arguments[3],
            mode: .shared
        )
        defer { prefixLock.unlock() }
        guard FileManager.default.isExecutableFile(atPath: arguments[1]),
              FileManager.default.fileExists(atPath: arguments[3]) else {
            printUsage()
            runnerExit(2)
        }

        let process = Process()
        let output = Pipe()
        let collector = ProcessOutputCollector()
        process.executableURL = URL(fileURLWithPath: arguments[1])
        process.arguments = ["wmic", "process", "get", "ExecutablePath"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "WINEPREFIX": arguments[3],
            "WINEDEBUG": "-all"
        ]) { _, new in new }
        process.currentDirectoryURL = URL(fileURLWithPath: arguments[3], isDirectory: true)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.consumeAvailableData(from: handle)
        }
        defer { RunnerProcessRegistry.shared.clear(process) }

        do {
            try RunnerProcessRegistry.shared.launch(process)
        } catch {
            collector.cancel(from: output.fileHandleForReading)
            throw error
        }
        guard waitForExit(process, timeout: wineServerCommandTimeout) else {
            stopProcessWithinDeadline(process)
            collector.finish(from: output.fileHandleForReading)
            throw SwitchyardRunnerError.processInspectionTimedOut
        }
        collector.finish(from: output.fileHandleForReading)
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.processInspectionFailed(process.terminationStatus)
        }

        let paths = Set(
            collector.text
                .components(separatedBy: .newlines)
                .dropFirst()
                .compactMap(WineProtocolAssociationFormat.normalizedWindowsExecutablePath)
        ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        FileHandle.standardOutput.write(try JSONEncoder().encode(paths))
    }

    private static func stopPrefix(arguments: [String]) throws {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix",
              FileManager.default.isExecutableFile(atPath: arguments[1]),
              FileManager.default.fileExists(atPath: arguments[3]) else {
            printUsage()
            runnerExit(2)
        }

        let environment = ProcessInfo.processInfo.environment.merging([
            "WINEPREFIX": arguments[3],
            "WINEDEBUG": "-all"
        ]) { _, new in new }
        try stopWinePrefixSession(
            wineExecutablePath: arguments[1],
            prefixPath: arguments[3],
            environment: environment
        )
    }

    private static func startProtocolAssociationMonitor(plan: CommandPlan) throws -> Process? {
        guard plan.environment[WineProtocolAssociationFormat.manifestEnvironmentKey]?.isEmpty == false else {
            return nil
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
        try RunnerProcessRegistry.shared.launch(process)
        return process
    }

    private static func stopProtocolAssociationMonitor(_ monitor: inout Process?) {
        guard let process = monitor else { return }
        stopProcessWithinDeadline(process)
        RunnerProcessRegistry.shared.clear(process)
        monitor = nil
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
            let result = try probeWinePrefixSession(
                wineExecutablePath: arguments[1],
                wineServerURL: wineServerURL,
                prefixPath: arguments[3]
            )
            runnerExit(result.exitStatus)
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
              scheme == request.scheme else {
            throw SwitchyardRunnerError.invalidURLCallbackRequest
        }

        let prefixLock = try WinePrefixFileLock(
            prefixPath: request.prefixPath,
            mode: .shared
        )
        defer { prefixLock.unlock() }
        guard FileManager.default.isExecutableFile(atPath: request.winePath),
              FileManager.default.fileExists(atPath: request.prefixPath) else {
            throw SwitchyardRunnerError.invalidURLCallbackRequest
        }

        let handlerExecutablePath: String?
        if let requestedHandlerExecutablePath = request.handlerExecutablePath {
            guard let normalizedHandlerExecutablePath = WineProtocolAssociationFormat
                .normalizedWindowsExecutablePath(requestedHandlerExecutablePath) else {
                throw SwitchyardRunnerError.invalidURLCallbackRequest
            }
            handlerExecutablePath = normalizedHandlerExecutablePath
        } else {
            handlerExecutablePath = nil
        }

        let environment = ProcessInfo.processInfo.environment.merging([
            "WINEPREFIX": request.prefixPath,
            WineProtocolAssociationFormat.manifestEnvironmentKey: WineProtocolAssociationFormat.windowsManifestPath
        ]) { _, new in new }
        if let handlerExecutablePath {
            let registrationExists = try protocolRegistrationExists(
                scheme: scheme,
                winePath: request.winePath,
                prefixPath: request.prefixPath,
                environment: environment
            )
            if !registrationExists {
                guard windowsExecutableExists(handlerExecutablePath, prefixPath: request.prefixPath) else {
                    throw SwitchyardRunnerError.invalidURLCallbackRequest
                }
                try runURLCallbackWineCommand(
                    winePath: request.winePath,
                    prefixPath: request.prefixPath,
                    environment: environment,
                    arguments: [handlerExecutablePath, request.rawURL]
                )
                do {
                    try registerLearnedProtocol(
                        scheme: scheme,
                        handlerExecutablePath: handlerExecutablePath,
                        winePath: request.winePath,
                        prefixPath: request.prefixPath,
                        environment: environment
                    )
                } catch {
                    removeLearnedProtocol(
                        scheme: scheme,
                        winePath: request.winePath,
                        prefixPath: request.prefixPath,
                        environment: environment
                    )
                    throw error
                }
                synchronizeUserProtocolRegistration(
                    scheme: scheme,
                    winePath: request.winePath,
                    prefixPath: request.prefixPath,
                    environment: environment
                )
                return
            }
        }
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
            throw SwitchyardRunnerError.urlCallbackCommandFailed(process.terminationStatus)
        }
    }

    private static func registerLearnedProtocol(
        scheme: String,
        handlerExecutablePath: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) throws {
        let key = "HKCU\\Software\\Classes\\\(scheme)"
        let handlerCommand = "\"\(handlerExecutablePath)\" \"%1\""
        let commands = [
            ["reg", "add", key, "/ve", "/d", "URL:\(scheme) protocol", "/f"],
            ["reg", "add", key, "/v", "URL Protocol", "/d", "", "/f"],
            ["reg", "add", "\(key)\\shell\\open\\command", "/ve", "/d", handlerCommand, "/f"]
        ]

        for arguments in commands {
            try runURLCallbackWineCommand(
                winePath: winePath,
                prefixPath: prefixPath,
                environment: environment,
                arguments: arguments
            )
        }
    }

    private static func protocolRegistrationExists(
        scheme: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = ["reg", "query", "HKCR\\\(scheme)\\shell\\open\\command", "/ve"]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)

        guard waitForExit(process, timeout: wineServerCommandTimeout) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.urlCallbackTimedOut
        }
        switch process.terminationStatus {
        case 0:
            return true
        case 1:
            return false
        default:
            throw SwitchyardRunnerError.urlCallbackCommandFailed(process.terminationStatus)
        }
    }

    private static func removeLearnedProtocol(
        scheme: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) {
        for key in ["HKCU\\Software\\Classes\\\(scheme)", "HKCR\\\(scheme)"] {
            try? runURLCallbackWineCommand(
                winePath: winePath,
                prefixPath: prefixPath,
                environment: environment,
                arguments: ["reg", "delete", key, "/f"]
            )
        }
    }

    private static func runURLCallbackWineCommand(
        winePath: String,
        prefixPath: String,
        environment: [String: String],
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)

        guard waitForExit(process, timeout: wineServerCommandTimeout) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.urlCallbackTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.urlCallbackCommandFailed(process.terminationStatus)
        }
    }

    private static func windowsExecutableExists(_ windowsPath: String, prefixPath: String) -> Bool {
        let relativeComponents = windowsPath.dropFirst(3).split(separator: "\\").map(String.init)
        guard !relativeComponents.isEmpty else { return false }

        let driveLetter = String(windowsPath.prefix(1)).lowercased()
        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true).standardizedFileURL
        let mappedDriveURL: URL
        if driveLetter == "c" {
            mappedDriveURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        } else {
            mappedDriveURL = prefixURL
                .appendingPathComponent("dosdevices", isDirectory: true)
                .appendingPathComponent("\(driveLetter):", isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: mappedDriveURL.path) else { return false }

        let driveRootURL = mappedDriveURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executableURL = relativeComponents.reduce(driveRootURL) { url, component in
            url.appendingPathComponent(component)
        }
        let resolvedExecutableURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let driveRootPath = driveRootURL.path
        let isInsideMappedDrive = driveRootPath == "/"
            ? resolvedExecutableURL.path.hasPrefix("/")
            : resolvedExecutableURL.path.hasPrefix(driveRootPath + "/")
        guard isInsideMappedDrive else { return false }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: resolvedExecutableURL.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
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
            Data("usage: switchyard-runner diagnose | probe-prefix --wine <path> --prefix <path> | list-processes --wine <path> --prefix <path> | stop-prefix --wine <path> --prefix <path> | open-url --request <request.json> | run --plan <command-plan.json>\n".utf8)
        )
    }
}

private func terminateExistingPrefixSession(plan: CommandPlan) throws {
    FileHandle.standardOutput.write(
        Data("[\(plan.logSource)] Stopping any existing Wine session for this prefix before relaunch.\n".utf8)
    )

    let environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
    try stopWinePrefixSession(
        wineExecutablePath: plan.executable,
        prefixPath: plan.environment["WINEPREFIX"] ?? plan.workingDirectory ?? "",
        environment: environment
    )
}

private func stopWinePrefixSession(
    wineExecutablePath: String,
    prefixPath: String,
    environment: [String: String]
) throws {
    guard let wineServerURL = wineServerURL(forWineExecutable: wineExecutablePath) else {
        throw SwitchyardRunnerError.missingWineServer(wineExecutablePath)
    }

    try runWineServer(
        at: wineServerURL,
        arguments: ["-k"],
        environment: environment,
        acceptedExitStatuses: [0, 1]
    )
    try runWineServer(at: wineServerURL, arguments: ["-w"], environment: environment)
    try stopResidualWineProcesses(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
}

private func wineServerURL(forWineExecutable path: String) -> URL? {
    let wineURL = URL(fileURLWithPath: path)
    let candidates = [
        wineURL.deletingLastPathComponent().appendingPathComponent("wineserver"),
        wineURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("wineserver")
    ]

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private enum WinePrefixProbeResult {
    case active
    case inactive
    case residualProcesses

    var exitStatus: Int32 {
        switch self {
        case .active: 0
        case .inactive: 1
        case .residualProcesses: 3
        }
    }
}

private func probeWinePrefixSession(
    wineExecutablePath: String,
    wineServerURL: URL,
    prefixPath: String
) throws -> WinePrefixProbeResult {
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
        let hasResidualProcesses = !wineProcessIDs(
            wineExecutablePath: wineExecutablePath,
            prefixPath: prefixPath
        ).isEmpty
        return hasResidualProcesses ? .residualProcesses : .inactive
    }

    stopProcessWithinDeadline(process)
    return .active
}

private let knownWineProcessExecutableNames: Set<String> = [
    "switchyard-wine",
    "wine",
    "wine-preloader",
    "wine64",
    "wine64-preloader",
    "wineserver"
]

private func wineProcessIDs(wineExecutablePath: String, prefixPath: String) -> [pid_t] {
    guard !prefixPath.isEmpty else { return [] }

    let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let expectedExecutablePaths = Set(
        [
            URL(fileURLWithPath: wineExecutablePath).standardizedFileURL.path,
            URL(fileURLWithPath: wineExecutablePath).resolvingSymlinksInPath().standardizedFileURL.path
        ]
    )
    let currentProcessID = ProcessInfo.processInfo.processIdentifier

    return allProcessIDs().filter { processID in
        guard processID > 0,
              processID != currentProcessID,
              let executablePath = processExecutablePath(processID) else {
            return false
        }

        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let resolvedExecutablePath = executableURL.resolvingSymlinksInPath().path
        let executableName = executableURL.lastPathComponent.lowercased()
        guard expectedExecutablePaths.contains(executableURL.path)
                || expectedExecutablePaths.contains(resolvedExecutablePath)
                || knownWineProcessExecutableNames.contains(executableName) else {
            return false
        }

        if let workingDirectoryPath = processWorkingDirectoryPath(processID) {
            let workingDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if path(workingDirectoryURL.path, isWithin: prefixURL.path) {
                return true
            }
        }

        guard let environmentPrefixPath = processEnvironmentValue(
            processID,
            key: "WINEPREFIX"
        ) else {
            return false
        }
        let environmentPrefixURL = URL(fileURLWithPath: environmentPrefixPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return environmentPrefixURL.path == prefixURL.path
    }.sorted()
}

private func allProcessIDs() -> [pid_t] {
    let estimatedCount = proc_listallpids(nil, 0)
    guard estimatedCount > 0 else { return [] }

    var capacity = Int(estimatedCount) + 32
    var latestProcessIDs: [pid_t] = []
    for _ in 0..<4 {
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let listedCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard listedCount > 0 else { return [] }
        latestProcessIDs = Array(processIDs.prefix(Int(listedCount)))
        if listedCount < capacity {
            return latestProcessIDs
        }
        capacity *= 2
    }
    return latestProcessIDs
}

private func processExecutablePath(_ processID: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = buffer.withUnsafeMutableBytes { bytes in
        proc_pidpath(processID, bytes.baseAddress, UInt32(bytes.count))
    }
    guard length > 0 else { return nil }
    let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: pathBytes, as: UTF8.self)
}

private func processWorkingDirectoryPath(_ processID: pid_t) -> String? {
    var pathInfo = proc_vnodepathinfo()
    let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(
        processID,
        PROC_PIDVNODEPATHINFO,
        0,
        &pathInfo,
        expectedSize
    ) == expectedSize else {
        return nil
    }

    return withUnsafePointer(to: &pathInfo.pvi_cdir.vip_path) { pathPointer in
        pathPointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
            String(cString: $0)
        }
    }
}

private func processEnvironmentValue(_ processID: pid_t, key: String) -> String? {
    var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
    var byteCount = 0
    guard sysctl(
        &managementInformationBase,
        UInt32(managementInformationBase.count),
        nil,
        &byteCount,
        nil,
        0
    ) == 0,
    byteCount > MemoryLayout<Int32>.size else {
        return nil
    }

    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard bytes.withUnsafeMutableBytes({ buffer in
        sysctl(
            &managementInformationBase,
            UInt32(managementInformationBase.count),
            buffer.baseAddress,
            &byteCount,
            nil,
            0
        )
    }) == 0 else {
        return nil
    }

    let argumentCount = bytes.withUnsafeBytes {
        $0.loadUnaligned(as: Int32.self)
    }
    var offset = MemoryLayout<Int32>.size

    func skipString() {
        while offset < byteCount && bytes[offset] != 0 {
            offset += 1
        }
        if offset < byteCount {
            offset += 1
        }
    }

    skipString()
    while offset < byteCount && bytes[offset] == 0 {
        offset += 1
    }
    for _ in 0..<max(0, Int(argumentCount)) {
        skipString()
    }

    let environmentKeyPrefix = key + "="
    while offset < byteCount {
        while offset < byteCount && bytes[offset] == 0 {
            offset += 1
        }
        let entryStart = offset
        while offset < byteCount && bytes[offset] != 0 {
            offset += 1
        }
        guard entryStart < offset else { continue }

        let entry = String(decoding: bytes[entryStart..<offset], as: UTF8.self)
        if entry.hasPrefix(environmentKeyPrefix) {
            return String(entry.dropFirst(environmentKeyPrefix.count))
        }
    }
    return nil
}

private func path(_ candidatePath: String, isWithin directoryPath: String) -> Bool {
    candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
}

private func stopResidualWineProcesses(
    wineExecutablePath: String,
    prefixPath: String
) throws {
    var remainingProcessIDs = wineProcessIDs(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    guard !remainingProcessIDs.isEmpty else { return }

    signalWineProcesses(
        remainingProcessIDs,
        signal: SIGTERM,
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    remainingProcessIDs = waitForWineProcessesToExit(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath,
        timeout: prefixProcessTerminationTimeout
    )
    guard !remainingProcessIDs.isEmpty else { return }

    signalWineProcesses(
        remainingProcessIDs,
        signal: SIGKILL,
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    remainingProcessIDs = waitForWineProcessesToExit(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath,
        timeout: 1
    )
    guard remainingProcessIDs.isEmpty else {
        throw SwitchyardRunnerError.wineProcessesCouldNotBeStopped(remainingProcessIDs)
    }
}

private func signalWineProcesses(
    _ processIDs: [pid_t],
    signal: Int32,
    wineExecutablePath: String,
    prefixPath: String
) {
    let currentlyAssociatedProcessIDs = Set(
        wineProcessIDs(
            wineExecutablePath: wineExecutablePath,
            prefixPath: prefixPath
        )
    )
    for processID in processIDs where currentlyAssociatedProcessIDs.contains(processID) {
        _ = Darwin.kill(processID, signal)
    }
}

private func waitForWineProcessesToExit(
    wineExecutablePath: String,
    prefixPath: String,
    timeout: TimeInterval
) -> [pid_t] {
    let deadline = Date().addingTimeInterval(timeout)
    var processIDs = wineProcessIDs(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    while !processIDs.isEmpty && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        processIDs = wineProcessIDs(
            wineExecutablePath: wineExecutablePath,
            prefixPath: prefixPath
        )
    }
    return processIDs
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
