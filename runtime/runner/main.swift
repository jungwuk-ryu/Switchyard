import AppCore
import Darwin
import Foundation

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
    static func main() throws {
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
        case "run":
            try run(arguments: Array(arguments.dropFirst()))
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

    private static func printUsage() {
        FileHandle.standardError.write(Data("usage: switchyard-runner diagnose | run --plan <command-plan.json>\n".utf8))
    }
}
