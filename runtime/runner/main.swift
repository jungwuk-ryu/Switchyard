import AppCore
import Darwin
import Foundation

private enum SwitchyardRunnerError: LocalizedError {
    case missingWineServer(String)
    case wineServerCommandFailed(arguments: [String], status: Int32, output: String)
    case wineServerCommandTimedOut(arguments: [String])

    var errorDescription: String? {
        switch self {
        case let .missingWineServer(path):
            "Cannot replace the existing Wine prefix session because wineserver was not found next to \(path)."
        case let .wineServerCommandFailed(arguments, status, output):
            "wineserver \(arguments.joined(separator: " ")) failed with status \(status): \(output)"
        case let .wineServerCommandTimedOut(arguments):
            "wineserver \(arguments.joined(separator: " ")) did not finish within 15 seconds."
        }
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
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

private final class RunnerProcessRegistry: @unchecked Sendable {
    static let shared = RunnerProcessRegistry()

    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func terminateChild() {
        lock.lock()
        let activeProcess = process
        lock.unlock()

        if let activeProcess, activeProcess.isRunning {
            activeProcess.terminate()
        }
    }
}

private let terminationSignalHandler: @convention(c) (Int32) -> Void = { signalNumber in
    RunnerProcessRegistry.shared.terminateChild()
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

@main
struct SwitchyardRunner {
    static func main() {
        signal(SIGTERM, terminationSignalHandler)
        signal(SIGINT, terminationSignalHandler)

        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            Foundation.exit(2)
        }

        switch arguments[0] {
        case "diagnose":
            print("switchyard-runner ok")
        case "probe-prefix":
            probePrefix(arguments: Array(arguments.dropFirst()))
        case "run":
            do {
                try run(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("switchyard-runner failed: \(error.localizedDescription)\n".utf8))
                Foundation.exit(1)
            }
        default:
            printUsage()
            Foundation.exit(2)
        }
    }

    private static func run(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--plan" else {
            printUsage()
            Foundation.exit(2)
        }

        let planURL = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: planURL)
        let plan = try JSONDecoder().decode(CommandPlan.self, from: data)

        if plan.terminateExistingPrefixSession == true {
            try terminateExistingPrefixSession(plan: plan)
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

        stdout.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                FileHandle.standardOutput.write(Data("[\(plan.logSource)] \(line)".utf8))
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                FileHandle.standardError.write(Data("[\(plan.logSource)] \(line)".utf8))
            }
        }

        try process.run()
        RunnerProcessRegistry.shared.set(process)
        process.waitUntilExit()
        RunnerProcessRegistry.shared.clear()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        Foundation.exit(process.terminationStatus)
    }

    private static func probePrefix(arguments: [String]) {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix" else {
            printUsage()
            Foundation.exit(2)
        }

        guard let wineServerURL = wineServerURL(forWineExecutable: arguments[1]) else {
            Foundation.exit(2)
        }

        do {
            let isActive = try winePrefixSessionIsActive(
                wineServerURL: wineServerURL,
                prefixPath: arguments[3]
            )
            Foundation.exit(isActive ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("Unable to inspect Wine prefix session: \(error)\n".utf8))
            Foundation.exit(2)
        }
    }

    private static func printUsage() {
        FileHandle.standardError.write(
            Data("usage: switchyard-runner diagnose | probe-prefix --wine <path> --prefix <path> | run --plan <command-plan.json>\n".utf8)
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
    try process.run()

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
        outputCollector.append(handle.availableData)
    }
    try process.run()

    guard waitForExit(process, timeout: wineServerCommandTimeout) else {
        stopProcessWithinDeadline(process)
        output.fileHandleForReading.readabilityHandler = nil
        throw SwitchyardRunnerError.wineServerCommandTimedOut(arguments: arguments)
    }

    output.fileHandleForReading.readabilityHandler = nil
    outputCollector.append(output.fileHandleForReading.readDataToEndOfFile())
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
