import AppCore
import Darwin
import Foundation

@main
private enum SwitchyardShortcutHandler {
    static func main() {
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
            windowsShortcutPath: route.windowsShortcutPath
        )
        guard let requestURL = try? writeProtectedRequest(request) else { return }
        defer { try? FileManager.default.removeItem(at: requestURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: route.runnerPath)
        process.arguments = ["open-shortcut", "--request", requestURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
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
