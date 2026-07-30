import AppCore
import AppKit
import Darwin
import Foundation

private enum URLHandlerError: LocalizedError {
    case runnerCancelled
    case runnerTimedOut
    case runnerTerminationUnconfirmed(pid_t)
    case runnerFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .runnerCancelled:
            "The Switchyard runner URL callback was cancelled."
        case .runnerTimedOut:
            "The Switchyard runner did not finish the URL callback within 120 seconds."
        case let .runnerTerminationUnconfirmed(processID):
            "The timed-out Switchyard runner process \(processID) could not be stopped."
        case let .runnerFailed(status):
            "The Switchyard runner failed to deliver the URL callback with status \(status)."
        }
    }
}

private final class URLDeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

private final class URLCallbackDelivery: @unchecked Sendable {
    private let bridgeRootURL: URL

    init(bridgeRootURL: URL) {
        self.bridgeRootURL = bridgeRootURL
    }

    func deliver(_ rawURL: String, cancellation: URLDeliveryCancellation) {
        do {
            try deliverThrowing(rawURL, cancellation: cancellation)
        } catch URLHandlerError.runnerCancelled {
            return
        } catch {
            FileHandle.standardError.write(
                Data("switchyard-url-handler failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private func deliverThrowing(
        _ rawURL: String,
        cancellation: URLDeliveryCancellation
    ) throws {
        guard !cancellation.isCancelled else {
            throw URLHandlerError.runnerCancelled
        }
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
        let requestURL = try writeProtectedRequest(request)
        defer { try? FileManager.default.removeItem(at: requestURL) }

        guard !cancellation.isCancelled else {
            throw URLHandlerError.runnerCancelled
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: route.runnerPath)
        process.arguments = ["open-url", "--request", requestURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        try waitForRunner(process, cancellation: cancellation)
    }

    private func waitForRunner(
        _ process: Process,
        cancellation: URLDeliveryCancellation
    ) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Self.runnerTimeout))
        while process.isRunning {
            if cancellation.isCancelled {
                try Self.stopAndReap(process)
                throw URLHandlerError.runnerCancelled
            }
            guard clock.now < deadline else {
                try Self.stopAndReap(process)
                throw URLHandlerError.runnerTimedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
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
        let routesURL = bridgeRootURL.appendingPathComponent("routes-v1.json")
        guard let data = try? Data(contentsOf: routesURL) else { return nil }
        return try? JSONDecoder().decode(WineProtocolRouteIndex.self, from: data)
    }

    private func writeProtectedRequest(_ request: WineURLCallbackRequest) throws -> URL {
        let requestsURL = bridgeRootURL.appendingPathComponent("Requests", isDirectory: true)
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
}

@MainActor
private final class URLDeliveryCoordinator {
    private let deliveryQueue = DispatchQueue(
        label: "com.switchyard.url-handler.delivery",
        qos: .userInitiated
    )
    private let deliver: @Sendable (String, URLDeliveryCancellation) -> Void
    private let idleDelay: TimeInterval
    private let onIdle: @MainActor () -> Void

    private var pendingURLs: [String] = []
    private var nextURLIndex = 0
    private var activeCancellation: URLDeliveryCancellation?
    private var idleWorkItem: DispatchWorkItem?
    private var idleGeneration = 0
    private var isShuttingDown = false

    init(
        delivery: URLCallbackDelivery,
        idleDelay: TimeInterval = 0.25,
        onIdle: @escaping @MainActor () -> Void
    ) {
        self.deliver = { rawURL, cancellation in
            delivery.deliver(rawURL, cancellation: cancellation)
        }
        self.idleDelay = idleDelay
        self.onIdle = onIdle
    }

    func enqueue(_ urls: [URL]) {
        guard !isShuttingDown, !urls.isEmpty else { return }
        idleGeneration &+= 1
        idleWorkItem?.cancel()
        idleWorkItem = nil
        pendingURLs.append(contentsOf: urls.map(\.absoluteString))
        startNextDeliveryIfNeeded()
    }

    /// Starts bounded cancellation for an external application termination.
    /// Returns true only when the caller must wait for an in-flight delivery.
    func beginTermination() -> Bool {
        isShuttingDown = true
        idleGeneration &+= 1
        idleWorkItem?.cancel()
        idleWorkItem = nil
        pendingURLs.removeAll(keepingCapacity: false)
        nextURLIndex = 0

        guard let activeCancellation else {
            return false
        }
        activeCancellation.cancel()
        return true
    }

    private func startNextDeliveryIfNeeded() {
        guard activeCancellation == nil else { return }
        guard nextURLIndex < pendingURLs.count else {
            pendingURLs.removeAll(keepingCapacity: false)
            nextURLIndex = 0
            scheduleIdle()
            return
        }

        let rawURL = pendingURLs[nextURLIndex]
        nextURLIndex += 1
        let cancellation = URLDeliveryCancellation()
        activeCancellation = cancellation
        let deliver = deliver
        deliveryQueue.async { [weak self] in
            deliver(rawURL, cancellation)
            DispatchQueue.main.async { [weak self] in
                self?.deliveryDidFinish()
            }
        }
    }

    private func deliveryDidFinish() {
        activeCancellation = nil
        if isShuttingDown {
            onIdle()
        } else {
            startNextDeliveryIfNeeded()
        }
    }

    private func scheduleIdle() {
        guard !isShuttingDown else {
            onIdle()
            return
        }
        idleGeneration &+= 1
        let scheduledGeneration = idleGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.idleGeneration == scheduledGeneration,
                  self.activeCancellation == nil,
                  self.nextURLIndex >= self.pendingURLs.count else {
                return
            }
            self.idleWorkItem = nil
            self.onIdle()
        }
        idleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: workItem)
    }
}

@MainActor
private final class URLHandlerDelegate: NSObject, NSApplicationDelegate {
    private let delivery = URLCallbackDelivery(bridgeRootURL: bridgeRootURL)
    private var launchTimeoutWorkItem: DispatchWorkItem?
    private var receivedURLBatch = false
    private var terminationReplyPending = false
    private lazy var coordinator = URLDeliveryCoordinator(delivery: delivery) { [weak self] in
        guard let self else { return }
        if self.terminationReplyPending {
            self.terminationReplyPending = false
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.receivedURLBatch else { return }
            self.launchTimeoutWorkItem = nil
            NSApplication.shared.terminate(nil)
        }
        launchTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        receivedURLBatch = true
        launchTimeoutWorkItem?.cancel()
        launchTimeoutWorkItem = nil
        coordinator.enqueue(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        launchTimeoutWorkItem?.cancel()
        launchTimeoutWorkItem = nil
        guard coordinator.beginTermination() else {
            return .terminateNow
        }
        terminationReplyPending = true
        return .terminateLater
    }

    fileprivate static var bridgeRootURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_BRIDGE_ROOT"],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Switchyard", isDirectory: true)
        .appendingPathComponent("ProtocolBridge", isDirectory: true)
    }
}

#if DEBUG
private struct URLHandlerTestEvent: Decodable {
    var delayMilliseconds: Int
    var urls: [URL]
    var markerPath: String?
}

@MainActor
private final class URLHandlerTestCompletion {
    var finished = false
}

@MainActor
private enum URLHandlerTestHarness {
    static func runIfRequested() -> Int32? {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              arguments[1] == "--test-deliver-url-events" else {
            return nil
        }

        do {
            let eventsURL = URL(fileURLWithPath: arguments[2])
            let events = try JSONDecoder().decode(
                [URLHandlerTestEvent].self,
                from: Data(contentsOf: eventsURL)
            )
            guard !events.isEmpty,
                  events.allSatisfy({ $0.delayMilliseconds >= 0 && !$0.urls.isEmpty }) else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let completion = URLHandlerTestCompletion()
            let delivery = URLCallbackDelivery(
                bridgeRootURL: URLHandlerDelegate.bridgeRootURL
            )
            let coordinator = URLDeliveryCoordinator(delivery: delivery) {
                completion.finished = true
            }
            for event in events {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .milliseconds(event.delayMilliseconds)
                ) {
                    if let markerPath = event.markerPath {
                        FileManager.default.createFile(
                            atPath: markerPath,
                            contents: Data()
                        )
                    }
                    coordinator.enqueue(event.urls)
                }
            }

            let deadline = Date(timeIntervalSinceNow: 5)
            while !completion.finished, Date() < deadline {
                RunLoop.main.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: 0.05)
                )
            }
            guard completion.finished else {
                _ = coordinator.beginTermination()
                let cancellationDeadline = Date(timeIntervalSinceNow: 4)
                while !completion.finished, Date() < cancellationDeadline {
                    RunLoop.main.run(
                        mode: .default,
                        before: Date(timeIntervalSinceNow: 0.05)
                    )
                }
                return 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("switchyard-url-handler test failed: \(error.localizedDescription)\n".utf8)
            )
            return 1
        }
    }
}
#endif

@main
@MainActor
private enum SwitchyardURLHandler {
    static func main() {
        #if DEBUG
        if let testStatus = URLHandlerTestHarness.runIfRequested() {
            Darwin.exit(testStatus)
        }
        #endif

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
