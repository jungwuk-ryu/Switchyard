import AppCore
import AppKit
import Darwin
import Foundation

private enum URLHandlerError: LocalizedError {
    case runnerTimedOut
    case runnerTerminationUnconfirmed(pid_t)
    case runnerFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .runnerTimedOut:
            "The Switchyard runner did not finish the URL callback within 120 seconds."
        case let .runnerTerminationUnconfirmed(processID):
            "The timed-out Switchyard runner process \(processID) could not be stopped."
        case let .runnerFailed(status):
            "The Switchyard runner failed to deliver the URL callback with status \(status)."
        }
    }
}

private final class URLHandlerDelegate: NSObject, NSApplicationDelegate {
    private var handledURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            NSApplication.shared.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !handledURL, let url = urls.first else {
            application.terminate(nil)
            return
        }
        handledURL = true

        deliver(url.absoluteString)
        application.terminate(nil)
    }

    private func deliver(_ rawURL: String) {
        guard let scheme = WineProtocolAssociationFormat.scheme(inRawURL: rawURL),
              let route = loadRouteIndex()?.route(forScheme: scheme),
              FileManager.default.isExecutableFile(atPath: route.runnerPath),
              FileManager.default.isExecutableFile(atPath: route.winePath),
              FileManager.default.fileExists(atPath: route.prefixPath) else {
            return
        }

        let request = WineURLCallbackRequest(
            scheme: scheme,
            rawURL: rawURL,
            prefixPath: route.prefixPath,
            winePath: route.winePath,
            handlerExecutablePath: route.handlerExecutablePath,
            rosettaAVXAdvertisingPreference:
                route.rosettaAVXAdvertisingPreference
        )
        guard let requestURL = try? writeProtectedRequest(request) else { return }
        defer { try? FileManager.default.removeItem(at: requestURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: route.runnerPath)
        process.arguments = ["open-url", "--request", requestURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            try waitForRunner(process)
        } catch {
            FileHandle.standardError.write(
                Data("switchyard-url-handler failed: \(error.localizedDescription)\n".utf8)
            )
            return
        }
    }

    private func waitForRunner(_ process: Process) throws {
        guard Self.waitForExit(process, timeout: Self.runnerTimeout) else {
            try Self.stopAndReap(process)
            throw URLHandlerError.runnerTimedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw URLHandlerError.runnerFailed(process.terminationStatus)
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
        return 120
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
                throw URLHandlerError.runnerTerminationUnconfirmed(processID)
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

    private func loadRouteIndex() -> WineProtocolRouteIndex? {
        let routesURL = Self.bridgeRootURL
            .appendingPathComponent("routes-v1.json")
        guard let data = try? Data(contentsOf: routesURL) else { return nil }
        return try? JSONDecoder().decode(WineProtocolRouteIndex.self, from: data)
    }

    private func writeProtectedRequest(_ request: WineURLCallbackRequest) throws -> URL {
        let requestsURL = Self.bridgeRootURL.appendingPathComponent("Requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requestsURL, withIntermediateDirectories: true)
        guard Darwin.chmod(requestsURL.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(.EACCES)
        }

        let requestURL = requestsURL.appendingPathComponent("\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(request)
        try data.write(to: requestURL, options: [.atomic])
        guard Darwin.chmod(requestURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            try? FileManager.default.removeItem(at: requestURL)
            throw POSIXError(.EACCES)
        }
        return requestURL
    }

    fileprivate static var bridgeRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("ProtocolBridge", isDirectory: true)
    }
}

@main
private enum SwitchyardURLHandler {
    static func main() {
        WineCallbackRequestCleanup.removeStaleRequests(
            inBridgeRoot: URLHandlerDelegate.bridgeRootURL
        )
        let delegate = URLHandlerDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
