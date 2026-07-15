import AppCore
import AppKit
import Darwin
import Foundation

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
            handlerExecutablePath: route.handlerExecutablePath
        )
        guard let requestURL = try? writeProtectedRequest(request) else { return }
        defer { try? FileManager.default.removeItem(at: requestURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: route.runnerPath)
        process.arguments = ["open-url", "--request", requestURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
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

    private static var bridgeRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("ProtocolBridge", isDirectory: true)
    }
}

@main
private enum SwitchyardURLHandler {
    static func main() {
        let delegate = URLHandlerDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.prohibited)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
