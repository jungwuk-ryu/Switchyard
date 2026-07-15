import AppCore
import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation

enum WineProtocolBridgeError: LocalizedError {
    case missingURLHandler
    case couldNotSignHandler(String)
    case couldNotRegisterHandler(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingURLHandler:
            "switchyard-url-handler was not found in the app bundle or build directory."
        case let .couldNotSignHandler(scheme):
            "Could not sign the generated macOS handler for the \(scheme) URL scheme."
        case let .couldNotRegisterHandler(scheme, status):
            "Could not register the generated macOS handler for the \(scheme) URL scheme (status \(status))."
        }
    }
}

struct WineProtocolBridgeRefreshResult {
    var newlyRegisteredSchemes: [String]
}

@MainActor
final class WineProtocolBridge {
    private let fileManager: FileManager
    private let rootURL: URL
    private var registeredSchemes: Set<String> = []
    private var activationDates: [UUID: Date] = [:]

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Switchyard", isDirectory: true)
                .appendingPathComponent("ProtocolBridge", isDirectory: true)
    }

    func recordLaunch(containerID: UUID, at date: Date = Date()) {
        activationDates[containerID] = date
    }

    func refresh(
        containers: [Container],
        winePath: String,
        runnerPath: String
    ) throws -> WineProtocolBridgeRefreshResult {
        guard fileManager.isExecutableFile(atPath: winePath),
              fileManager.isExecutableFile(atPath: runnerPath) else {
            return WineProtocolBridgeRefreshResult(newlyRegisteredSchemes: [])
        }

        var routes: [WineProtocolRoute] = []
        for container in containers {
            let manifestURL = WineProtocolAssociationFormat.manifestURL(prefixPath: container.path)
            guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8) else { continue }
            let lastActivatedAt = activationDates[container.id] ?? container.lastRun ?? .distantPast
            for scheme in WineProtocolAssociationFormat.schemes(inManifest: contents) {
                routes.append(
                    WineProtocolRoute(
                        scheme: scheme,
                        containerID: container.id,
                        prefixPath: container.path,
                        winePath: winePath,
                        runnerPath: runnerPath,
                        lastActivatedAt: lastActivatedAt
                    )
                )
            }
        }

        routes.sort {
            if $0.scheme != $1.scheme { return $0.scheme < $1.scheme }
            if $0.lastActivatedAt != $1.lastActivatedAt { return $0.lastActivatedAt < $1.lastActivatedAt }
            return $0.containerID.uuidString < $1.containerID.uuidString
        }
        try writeRouteIndex(WineProtocolRouteIndex(routes: routes))
        guard !routes.isEmpty else {
            return WineProtocolBridgeRefreshResult(newlyRegisteredSchemes: [])
        }

        let helperURL = try locateURLHandler()
        var newlyRegisteredSchemes: [String] = []
        for scheme in Set(routes.map(\.scheme)).sorted() where !registeredSchemes.contains(scheme) {
            try registerHandler(for: scheme, helperURL: helperURL)
            registeredSchemes.insert(scheme)
            newlyRegisteredSchemes.append(scheme)
        }
        return WineProtocolBridgeRefreshResult(newlyRegisteredSchemes: newlyRegisteredSchemes)
    }

    private func writeRouteIndex(_ index: WineProtocolRouteIndex) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard Darwin.chmod(rootURL.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(.EACCES)
        }

        let routesURL = rootURL.appendingPathComponent("routes-v1.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        if (try? Data(contentsOf: routesURL)) == data { return }
        try data.write(to: routesURL, options: [.atomic])
        guard Darwin.chmod(routesURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    private func registerHandler(for scheme: String, helperURL: URL) throws {
        let handlersURL = rootURL.appendingPathComponent("Handlers", isDirectory: true)
        try fileManager.createDirectory(at: handlersURL, withIntermediateDirectories: true)
        let identifier = handlerBundleIdentifier(for: scheme)
        let handlerURL = handlersURL.appendingPathComponent("\(identifier).app", isDirectory: true)
        let temporaryURL = handlersURL.appendingPathComponent(".\(identifier)-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let macOSURL = temporaryURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let executableURL = macOSURL.appendingPathComponent("switchyard-url-handler")
        try fileManager.copyItem(at: helperURL, to: executableURL)
        guard Darwin.chmod(executableURL.path, mode_t(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)) == 0 else {
            throw POSIXError(.EACCES)
        }

        let infoPlist: [String: Any] = [
            "CFBundleDisplayName": "Switchyard URL Handler",
            "CFBundleExecutable": "switchyard-url-handler",
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Switchyard URL Handler",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleURLTypes": [[
                "CFBundleTypeRole": "Viewer",
                "CFBundleURLName": "\(identifier).\(scheme)",
                "CFBundleURLSchemes": [scheme]
            ]],
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "NSPrincipalClass": "NSApplication"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: temporaryURL.appendingPathComponent("Contents/Info.plist"), options: [.atomic])
        try signHandler(at: temporaryURL, scheme: scheme)

        if fileManager.fileExists(atPath: handlerURL.path) {
            try fileManager.removeItem(at: handlerURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: handlerURL)

        let registrationStatus = LSRegisterURL(handlerURL as CFURL, true)
        guard registrationStatus == noErr else {
            throw WineProtocolBridgeError.couldNotRegisterHandler(scheme, registrationStatus)
        }

        let callbackURL = URL(string: "\(scheme):")
        let existingHandler = callbackURL
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        if existingHandler == nil || existingHandler?.hasPrefix("dev.switchyard.protocol.") == true {
            let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, identifier as CFString)
            guard status == noErr else {
                throw WineProtocolBridgeError.couldNotRegisterHandler(scheme, status)
            }
        }
    }

    private func signHandler(at handlerURL: URL, scheme: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", handlerURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WineProtocolBridgeError.couldNotSignHandler(scheme)
        }
    }

    private func locateURLHandler() throws -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("switchyard-url-handler")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }

        if let override = ProcessInfo.processInfo.environment["SWITCHYARD_URL_HANDLER_PATH"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let fallback = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(".build/debug/switchyard-url-handler")
        if fileManager.isExecutableFile(atPath: fallback.path) { return fallback }
        throw WineProtocolBridgeError.missingURLHandler
    }

    private func handlerBundleIdentifier(for scheme: String) -> String {
        let digest = SHA256.hash(data: Data(scheme.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "dev.switchyard.protocol.\(digest)"
    }
}
