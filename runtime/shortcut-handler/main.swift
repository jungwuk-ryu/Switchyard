import AppCore
import Darwin
import Foundation

private enum ShortcutHandlerError: LocalizedError {
    case runnerTimedOut
    case runnerTerminationUnconfirmed(pid_t)
    case runnerFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .runnerTimedOut:
            "The Switchyard runner did not finish opening the desktop shortcut within 30 seconds."
        case let .runnerTerminationUnconfirmed(processID):
            "The timed-out Switchyard runner process \(processID) could not be stopped."
        case let .runnerFailed(status):
            "The Switchyard runner failed to open the desktop shortcut with status \(status)."
        }
    }
}

@main
private enum SwitchyardShortcutHandler {
    static func main() {
        WineCallbackRequestCleanup.removeStaleRequests(inBridgeRoot: bridgeRootURL)
        guard let shortcutID = Bundle.main.object(
            forInfoDictionaryKey: "SwitchyardDesktopShortcutID"
        ) as? String,
              let route = loadRouteIndex()?.route(forID: shortcutID),
              FileManager.default.isExecutableFile(atPath: route.runnerPath),
              FileManager.default.isExecutableFile(atPath: route.winePath),
              FileManager.default.fileExists(atPath: route.prefixPath),
              let shortcutURL = WineDesktopShortcutFormat.hostShortcutURL(
                  windowsPath: route.windowsShortcutPath,
                  prefixPath: route.prefixPath
              ),
              FileManager.default.fileExists(atPath: shortcutURL.path) else {
            return
        }

        let request = WineDesktopShortcutRequest(
            shortcutID: route.id,
            prefixPath: route.prefixPath,
            winePath: route.winePath,
            windowsShortcutPath: route.windowsShortcutPath,
            rosettaAVXAdvertisingPreference:
                route.rosettaAVXAdvertisingPreference
        )
        guard let requestURL = try? writeProtectedRequest(request) else { return }
        defer { try? FileManager.default.removeItem(at: requestURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: route.runnerPath)
        process.arguments = ["open-shortcut", "--request", requestURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            try waitForRunner(process)
        } catch {
            FileHandle.standardError.write(
                Data("switchyard-shortcut-handler failed: \(error.localizedDescription)\n".utf8)
            )
            return
        }
    }

    private static func waitForRunner(_ process: Process) throws {
        guard waitForExit(process, timeout: runnerTimeout) else {
            try stopAndReap(process)
            throw ShortcutHandlerError.runnerTimedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShortcutHandlerError.runnerFailed(process.terminationStatus)
        }
    }

    private static var runnerTimeout: TimeInterval {
        #if DEBUG
        if let rawValue = ProcessInfo.processInfo.environment[
            "SWITCHYARD_TEST_HANDLER_RUNNER_TIMEOUT"
        ],
           let value = TimeInterval(rawValue),
           value >= 0.05,
           value <= 5 {
            return value
        }
        #endif
        return 30
    }

    private static func stopAndReap(_ process: Process) throws {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        let processID = process.processIdentifier
        process.terminate()
        if !waitForExit(process, timeout: 2) {
            guard process.isRunning else {
                process.waitUntilExit()
                return
            }
            _ = Darwin.kill(processID, SIGKILL)
            guard waitForExit(process, timeout: 1) else {
                throw ShortcutHandlerError.runnerTerminationUnconfirmed(processID)
            }
        }
        process.waitUntilExit()
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while process.isRunning, clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    private static func loadRouteIndex() -> WineDesktopShortcutRouteIndex? {
        let routesURL = bridgeRootURL.appendingPathComponent("routes-v1.json")
        guard let data = try? Data(contentsOf: routesURL) else { return nil }
        return try? JSONDecoder().decode(WineDesktopShortcutRouteIndex.self, from: data)
    }

    private static func writeProtectedRequest(_ request: WineDesktopShortcutRequest) throws -> URL {
        let requestsURL = bridgeRootURL.appendingPathComponent("Requests", isDirectory: true)
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

    private static var bridgeRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("DesktopShortcutBridge", isDirectory: true)
    }
}
