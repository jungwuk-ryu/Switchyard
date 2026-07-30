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
            String(
                localized: "switchyard-url-handler was not found in the app bundle or build directory.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidCallbackURL:
            String(
                localized: "The clipboard does not contain a supported custom callback URL.",
                bundle: SwitchyardStrings.bundle
            )
        case .missingCallbackContainer:
            String(
                localized: "The selected Wine container or runtime is not available.",
                bundle: SwitchyardStrings.bundle
            )
        case let .couldNotSignHandler(scheme):
            String(
                localized: "Could not sign the generated macOS handler for the \(scheme) URL scheme.",
                bundle: SwitchyardStrings.bundle
            )
        case let .couldNotRegisterHandler(scheme, status):
            String(
                localized: "Could not register the generated macOS handler for the \(scheme) URL scheme (status \(status)).",
                bundle: SwitchyardStrings.bundle
            )
        }
    }
}

struct WineProtocolBridgeRefreshResult {
    var newlyRegisteredSchemes: [String]
    var observedDependencyURLs: Set<URL>

    init(
        newlyRegisteredSchemes: [String],
        observedDependencyURLs: Set<URL> = []
    ) {
        self.newlyRegisteredSchemes = newlyRegisteredSchemes
        self.observedDependencyURLs = observedDependencyURLs
    }
}

enum WineManifestFileReader {
    static func contents(
        at manifestURL: URL,
        insidePrefix prefixPath: String,
        maximumBytes: Int,
        afterDirectoryValidation: ((String) -> Void)? = nil,
        afterFileValidation: (() -> Void)? = nil
    ) -> String? {
        guard maximumBytes >= 0,
              maximumBytes < Int.max,
              let relativeComponents = relativePathComponents(
                  of: manifestURL,
                  insidePrefix: prefixPath
              ) else {
            return nil
        }

        let rootDescriptor = prefixPath.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard rootDescriptor >= 0,
              verifiedRootDescriptor(rootDescriptor, path: prefixPath) else {
            if rootDescriptor >= 0 {
                Darwin.close(rootDescriptor)
            }
            return nil
        }

        var directoryDescriptors = [rootDescriptor]
        defer {
            for descriptor in directoryDescriptors.reversed() {
                Darwin.close(descriptor)
            }
        }

        var currentDirectoryDescriptor = rootDescriptor
        var openedPathComponents: [String] = []
        for component in relativeComponents.dropLast() {
            let directoryDescriptor = component.withCString {
                Darwin.openat(
                    currentDirectoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard directoryDescriptor >= 0,
                  verifiedChildDirectoryDescriptor(
                      directoryDescriptor,
                      parentDescriptor: currentDirectoryDescriptor,
                      name: component
                  ) else {
                if directoryDescriptor >= 0 {
                    Darwin.close(directoryDescriptor)
                }
                return nil
            }

            directoryDescriptors.append(directoryDescriptor)
            currentDirectoryDescriptor = directoryDescriptor
            openedPathComponents.append(component)
            afterDirectoryValidation?(openedPathComponents.joined(separator: "/"))
        }

        guard let filename = relativeComponents.last else { return nil }
        let fileDescriptor = filename.withCString {
            Darwin.openat(
                currentDirectoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard fileDescriptor >= 0 else { return nil }
        defer { Darwin.close(fileDescriptor) }

        var entryMetadata = stat()
        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0,
              filename.withCString({
                  Darwin.fstatat(
                      currentDirectoryDescriptor,
                      $0,
                      &entryMetadata,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0
              }),
              sameFile(metadata, entryMetadata),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes) else {
            return nil
        }

        afterFileValidation?()
        guard let data = boundedData(
            from: fileDescriptor,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func relativePathComponents(
        of manifestURL: URL,
        insidePrefix prefixPath: String
    ) -> [String]? {
        guard manifestURL.isFileURL,
              (prefixPath as NSString).isAbsolutePath,
              (manifestURL.path as NSString).isAbsolutePath else {
            return nil
        }

        let rootURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        let standardizedRootURL = rootURL.standardizedFileURL
        let standardizedManifestURL = manifestURL.standardizedFileURL
        guard standardizedRootURL.path == prefixPath,
              standardizedRootURL.resolvingSymlinksInPath().standardizedFileURL.path
                == prefixPath,
              standardizedManifestURL.path == manifestURL.path else {
            return nil
        }

        let rootComponents = standardizedRootURL.pathComponents
        let manifestComponents = standardizedManifestURL.pathComponents
        guard manifestComponents.count > rootComponents.count,
              Array(manifestComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }

        let relativeComponents = Array(manifestComponents.dropFirst(rootComponents.count))
        guard relativeComponents.allSatisfy({
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && !($0 as NSString).isAbsolutePath
        }) else {
            return nil
        }
        return relativeComponents
    }

    private static func verifiedRootDescriptor(_ descriptor: Int32, path: String) -> Bool {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              path.withCString({
                  Darwin.lstat($0, &pathMetadata) == 0
              }),
              descriptorMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              descriptorMetadata.st_uid == geteuid(),
              sameFile(descriptorMetadata, pathMetadata) else {
            return false
        }

        let rootURL = URL(fileURLWithPath: path, isDirectory: true)
        return rootURL.standardizedFileURL.path == path
            && rootURL.resolvingSymlinksInPath().standardizedFileURL.path == path
    }

    private static func verifiedChildDirectoryDescriptor(
        _ descriptor: Int32,
        parentDescriptor: Int32,
        name: String
    ) -> Bool {
        var descriptorMetadata = stat()
        var entryMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &entryMetadata,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0
              }) else {
            return false
        }
        return descriptorMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && descriptorMetadata.st_uid == geteuid()
            && sameFile(descriptorMetadata, entryMetadata)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func boundedData(
        from fileDescriptor: Int32,
        maximumBytes: Int
    ) -> Data? {
        let byteLimit = maximumBytes + 1
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        var buffer = [UInt8](
            repeating: 0,
            count: min(byteLimit, 64 * 1_024)
        )

        while data.count < byteLimit {
            let requestedBytes = min(buffer.count, byteLimit - data.count)
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, requestedBytes)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if bytesRead == 0 {
                return data
            }
            data.append(contentsOf: buffer.prefix(Int(bytesRead)))
        }
        return nil
    }

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
        var observedDependencyURLs = observedDependencyURLs(
            containers: containers,
            winePath: winePath,
            runnerPath: runnerPath
        )

        guard fileManager.isExecutableFile(atPath: winePath),
              fileManager.isExecutableFile(atPath: runnerPath) else {
            return WineProtocolBridgeRefreshResult(
                newlyRegisteredSchemes: [],
                observedDependencyURLs: observedDependencyURLs
            )
        }

        let validContainerIDs = Set(containers.map(\.id))
        let storedAssociations = loadLearnedAssociations()
        let learnedAssociations = storedAssociations.pruning(to: validContainerIDs)
        if fileManager.fileExists(atPath: learnedAssociationsURL.path),
           learnedAssociations != storedAssociations {
            try writeLearnedAssociations(learnedAssociations)
        }

        var routes: [WineProtocolRoute] = []
        var manifestSchemeCandidates: Set<String> = []
        var latestLearnedDateByScheme: [String: Date] = [:]
        for container in containers {
            let manifestURL = WineProtocolAssociationFormat.manifestURL(prefixPath: container.path)
            let contents = WineManifestFileReader.contents(
                at: manifestURL,
                insidePrefix: container.path,
                maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
            ) ?? ""
            let manifestSchemes = WineProtocolAssociationFormat.schemes(inManifest: contents)
            let learnedForContainer = learnedAssociations.associations(for: container.id)
            let latestLearnedAssociations = Dictionary(grouping: learnedForContainer, by: \.scheme)
                .compactMapValues { associations in
                    associations.max { $0.learnedAt < $1.learnedAt }
                }
            for scheme in manifestSchemes {
                insertBoundedManifestScheme(scheme, into: &manifestSchemeCandidates)
            }
            for association in latestLearnedAssociations.values {
                latestLearnedDateByScheme[association.scheme] = max(
                    latestLearnedDateByScheme[association.scheme] ?? .distantPast,
                    association.learnedAt
                )
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
                        ),
                        rosettaAVXAdvertisingPreference:
                            RosettaAVXAdvertisingPolicy.explicitPreference(
                                in: container.environmentOverrides
                            )
                    )
                )
            }
        }

        let acceptedSchemes = acceptedSchemes(
            manifestSchemes: manifestSchemeCandidates,
            latestLearnedDateByScheme: latestLearnedDateByScheme
        )
        routes.removeAll { !acceptedSchemes.contains($0.scheme) }
        routes.sort {
            if $0.scheme != $1.scheme { return $0.scheme < $1.scheme }
            if $0.lastActivatedAt != $1.lastActivatedAt { return $0.lastActivatedAt < $1.lastActivatedAt }
            return $0.containerID.uuidString < $1.containerID.uuidString
        }
        try writeRouteIndex(WineProtocolRouteIndex(routes: routes))
        try removeStaleHandlers(keeping: acceptedSchemes)
        registeredSchemes.formIntersection(acceptedSchemes)
        guard !routes.isEmpty else {
            return WineProtocolBridgeRefreshResult(
                newlyRegisteredSchemes: [],
                observedDependencyURLs: observedDependencyURLs
            )
        }

        let helperURL = try locateURLHandler()
        observedDependencyURLs.insert(helperURL.standardizedFileURL)
        var newlyRegisteredSchemes: [String] = []
        for scheme in Set(routes.map(\.scheme)).sorted() where !registeredSchemes.contains(scheme) {
            try registerHandler(for: scheme, helperURL: helperURL)
            registeredSchemes.insert(scheme)
            newlyRegisteredSchemes.append(scheme)
        }
        return WineProtocolBridgeRefreshResult(
            newlyRegisteredSchemes: newlyRegisteredSchemes,
            observedDependencyURLs: observedDependencyURLs
        )
    }

    func observedDependencyURLs(
        containers: [Container],
        winePath: String,
        runnerPath: String
    ) -> Set<URL> {
        var urls = Set(
            containers.map {
                WineProtocolAssociationFormat.manifestURL(
                    prefixPath: $0.path
                ).standardizedFileURL
            }
        )
        urls.insert(
            URL(fileURLWithPath: winePath).standardizedFileURL
        )
        urls.insert(
            URL(fileURLWithPath: runnerPath).standardizedFileURL
        )
        urls.insert(
            learnedAssociationsURL.standardizedFileURL
        )
        return urls
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
            handlerExecutablePath: normalizedHandlerPath,
            rosettaAVXAdvertisingPreference:
                RosettaAVXAdvertisingPolicy.explicitPreference(
                    in: container.environmentOverrides
                )
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
              let contents = WineManifestFileReader.contents(
                  at: WineProtocolAssociationFormat.manifestURL(prefixPath: container.path),
                  insidePrefix: container.path,
                  maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
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

    private func acceptedSchemes(
        manifestSchemes: Set<String>,
        latestLearnedDateByScheme: [String: Date]
    ) -> Set<String> {
        let learnedSchemes = latestLearnedDateByScheme.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }

        var accepted = Set(
            learnedSchemes.prefix(WineProtocolAssociationFormat.maximumSchemes).map(\.key)
        )
        for scheme in manifestSchemes.sorted()
        where accepted.count < WineProtocolAssociationFormat.maximumSchemes {
            accepted.insert(scheme)
        }
        return accepted
    }

    private func insertBoundedManifestScheme(
        _ scheme: String,
        into schemes: inout Set<String>
    ) {
        schemes.insert(scheme)
        guard schemes.count > WineProtocolAssociationFormat.maximumSchemes,
              let largestScheme = schemes.max() else {
            return
        }
        schemes.remove(largestScheme)
    }

    private func removeStaleHandlers(keeping schemes: Set<String>) throws {
        let handlersURL = rootURL.appendingPathComponent("Handlers", isDirectory: true)
        guard fileManager.fileExists(atPath: handlersURL.path) else { return }

        let desiredNames = Set(schemes.map {
            "\(handlerBundleIdentifier(for: $0)).app"
        })
        for entry in try fileManager.contentsOfDirectory(
            at: handlersURL,
            includingPropertiesForKeys: nil
        ) where isManagedHandlerName(entry.lastPathComponent)
            && !desiredNames.contains(entry.lastPathComponent) {
            try fileManager.removeItem(at: entry)
        }
    }

    private func isManagedHandlerName(_ name: String) -> Bool {
        let prefix = "dev.switchyard.protocol."
        let suffix = ".app"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let digest = name.dropFirst(prefix.count).dropLast(suffix.count)
        return digest.utf8.count == 24 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
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
