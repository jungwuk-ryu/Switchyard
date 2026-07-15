import AppCore
import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation

enum WineProtocolBridgeError: LocalizedError {
    case missingURLHandler
    case invalidCallbackURL
    case missingCallbackContainer
    case couldNotSignHandler(String)
    case couldNotRegisterHandler(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingURLHandler:
            "switchyard-url-handler was not found in the app bundle or build directory."
        case .invalidCallbackURL:
            "The clipboard does not contain a supported custom callback URL."
        case .missingCallbackContainer:
            "The selected Wine container or runtime is not available."
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

        let validContainerIDs = Set(containers.map(\.id))
        let storedAssociations = loadLearnedAssociations()
        let learnedAssociations = storedAssociations.pruning(to: validContainerIDs)
        if fileManager.fileExists(atPath: learnedAssociationsURL.path),
           learnedAssociations != storedAssociations {
            try writeLearnedAssociations(learnedAssociations)
        }

        var routes: [WineProtocolRoute] = []
        for container in containers {
            let manifestURL = WineProtocolAssociationFormat.manifestURL(prefixPath: container.path)
            let contents = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
            let manifestSchemes = WineProtocolAssociationFormat.schemes(inManifest: contents)
            let learnedForContainer = learnedAssociations.associations(for: container.id)
            let latestLearnedAssociations = Dictionary(grouping: learnedForContainer, by: \.scheme)
                .compactMapValues { associations in
                    associations.max { $0.learnedAt < $1.learnedAt }
                }
            let schemes = manifestSchemes.union(latestLearnedAssociations.keys)
            let containerActivatedAt = activationDates[container.id] ?? container.lastRun ?? .distantPast

            for scheme in schemes {
                let learnedAssociation = latestLearnedAssociations[scheme]
                routes.append(
                    WineProtocolRoute(
                        scheme: scheme,
                        containerID: container.id,
                        prefixPath: container.path,
                        winePath: winePath,
                        runnerPath: runnerPath,
                        handlerExecutablePath: manifestSchemes.contains(scheme)
                            ? nil
                            : learnedAssociation?.handlerExecutablePath,
                        lastActivatedAt: max(
                            containerActivatedAt,
                            learnedAssociation?.learnedAt ?? .distantPast
                        )
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

    func makeCallbackRecoveryRequest(
        rawURL: String,
        containerID: UUID,
        containers: [Container],
        winePath: String,
        runnerPath: String,
        handlerExecutablePath: String?
    ) throws -> WineURLCallbackRequest {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = WineProtocolAssociationFormat.scheme(inRawURL: trimmedURL) else {
            throw WineProtocolBridgeError.invalidCallbackURL
        }
        guard let container = containers.first(where: { $0.id == containerID }),
              fileManager.fileExists(atPath: container.path),
              fileManager.isExecutableFile(atPath: winePath),
              fileManager.isExecutableFile(atPath: runnerPath) else {
            throw WineProtocolBridgeError.missingCallbackContainer
        }
        let normalizedHandlerPath = handlerExecutablePath.flatMap(
            WineProtocolAssociationFormat.normalizedWindowsExecutablePath
        )
        guard handlerExecutablePath == nil || normalizedHandlerPath != nil else {
            throw WineProtocolBridgeError.missingCallbackContainer
        }

        return WineURLCallbackRequest(
            scheme: scheme,
            rawURL: trimmedURL,
            prefixPath: container.path,
            winePath: winePath,
            handlerExecutablePath: normalizedHandlerPath
        )
    }

    func commitCallbackRecovery(
        _ request: WineURLCallbackRequest,
        containerID: UUID,
        containers: [Container],
        runnerPath: String,
        at date: Date = Date()
    ) throws {
        guard let container = containers.first(where: { $0.id == containerID }),
              container.path == request.prefixPath,
              fileManager.fileExists(atPath: request.prefixPath),
              fileManager.isExecutableFile(atPath: request.winePath),
              fileManager.isExecutableFile(atPath: runnerPath),
              let scheme = WineProtocolAssociationFormat.scheme(inRawURL: request.rawURL),
              scheme == request.scheme else {
            throw WineProtocolBridgeError.missingCallbackContainer
        }

        if request.handlerExecutablePath != nil {
            var learnedAssociations = loadLearnedAssociations()
                .pruning(to: Set(containers.map(\.id)))
            guard learnedAssociations.learn(
                scheme: scheme,
                for: containerID,
                handlerExecutablePath: request.handlerExecutablePath,
                at: date
            ) != nil else {
                throw WineProtocolBridgeError.invalidCallbackURL
            }
            try writeLearnedAssociations(learnedAssociations)
        }
        recordLaunch(containerID: containerID, at: date)
        _ = try refresh(containers: containers, winePath: request.winePath, runnerPath: runnerPath)
    }

    func learnedSchemes(for containerID: UUID) -> [String] {
        Array(
            Set(loadLearnedAssociations().associations(for: containerID).map(\.scheme))
        ).sorted()
    }

    func hasRegisteredScheme(_ rawScheme: String, in container: Container) -> Bool {
        guard let scheme = WineProtocolAssociationFormat.normalizedScheme(rawScheme),
              let contents = try? String(
                  contentsOf: WineProtocolAssociationFormat.manifestURL(prefixPath: container.path),
                  encoding: .utf8
              ) else {
            return false
        }
        return WineProtocolAssociationFormat.schemes(inManifest: contents).contains(scheme)
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

    private func loadLearnedAssociations() -> WineProtocolLearnedAssociationIndex {
        guard let data = try? Data(contentsOf: learnedAssociationsURL),
              let index = try? JSONDecoder().decode(WineProtocolLearnedAssociationIndex.self, from: data),
              index.version == WineProtocolLearnedAssociationIndex.currentVersion else {
            return WineProtocolLearnedAssociationIndex()
        }
        return index
    }

    private func writeLearnedAssociations(_ index: WineProtocolLearnedAssociationIndex) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard Darwin.chmod(rootURL.path, mode_t(S_IRWXU)) == 0 else {
            throw POSIXError(.EACCES)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: learnedAssociationsURL, options: [.atomic])
        guard Darwin.chmod(learnedAssociationsURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw POSIXError(.EACCES)
        }
    }

    private var learnedAssociationsURL: URL {
        rootURL.appendingPathComponent("learned-associations-v1.json")
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
