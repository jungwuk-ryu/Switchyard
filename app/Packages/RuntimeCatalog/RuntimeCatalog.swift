import AppCore
import Darwin
import Foundation

private struct SwitchyardRuntimeManifest: Decodable {
    var id: String?
    var buildProfile: String?
    var peArchitectures: [String]?
    var executable: String?
    var patchQueueDigest: String?
}

private struct SwitchyardRuntimeCandidate {
    var winePath: String
    var modifiedAt: Date
    var isCompleteWoW64: Bool
}

public struct RuntimeLocator {
    public var fileManager: FileManager
    private let hdiutilPath = "/usr/bin/hdiutil"
    private let hdiutilTimeout: DispatchTimeInterval = .seconds(20)

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func diagnose(
        gptkPath: String?,
        winePath: String?,
        patchSeriesPath: String = "patches/wine/series",
        fontCachePath: String? = nil
    ) -> (RuntimeStatus, [DiagnosticCheck]) {
        let architectureStatus = isAppleSilicon ? HealthStatus.ok : .unsupported
        let macOSStatus = isSupportedMacOS ? HealthStatus.ok : .unsupported
        let gptkValidation = validateGPTK(at: gptkPath)
        let wineValidation = validateWine(at: winePath)
        let patchStatus: HealthStatus = fileManager.fileExists(atPath: patchSeriesPath) ? .ok : .missing
        let fontCacheURL = fontCachePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? OpenFontPackCatalog.defaultCacheRoot(fileManager: fileManager)
        let fontPackStatus = OpenFontPackCatalog.diagnose(cacheRoot: fontCacheURL, fileManager: fileManager)

        let checks = [
            DiagnosticCheck(
                id: "apple-silicon",
                title: "Apple Silicon",
                status: architectureStatus,
                result: isAppleSilicon ? "Running on \(machineHardwareName)." : "Switchyard v1 supports Apple Silicon only.",
                recoveryAction: nil
            ),
            DiagnosticCheck(
                id: "macos-version",
                title: "macOS Version",
                status: macOSStatus,
                result: "Detected macOS \(operatingSystemVersion).",
                recoveryAction: nil
            ),
            DiagnosticCheck(
                id: "gptk",
                title: "Game Porting Toolkit",
                status: gptkValidation.status,
                result: gptkValidation.message,
                recoveryAction: gptkValidation.status == .ok ? nil : "Open GPTK Settings"
            ),
            DiagnosticCheck(
                id: "wine-runtime",
                title: "Wine Runtime",
                status: wineValidation.status,
                result: wineValidation.message,
                recoveryAction: wineValidation.status == .ok ? nil : "Open Wine Settings"
            ),
            DiagnosticCheck(
                id: "patch-series",
                title: "Wine Patch Series",
                status: patchStatus,
                result: patchStatus == .ok ? "Patch queue metadata is present." : "Patch queue metadata is missing. Create patches/wine/series.",
                recoveryAction: patchStatus == .ok ? nil : "Open Wine Settings"
            ),
            DiagnosticCheck(
                id: "open-font-pack",
                title: "Open Font Pack",
                status: fontPackStatus.status,
                result: fontPackStatus.message,
                recoveryAction: fontPackStatus.status == .ok ? nil : "Install Open Font Pack"
            )
        ]

        let summary: String
        if architectureStatus == .ok && macOSStatus == .ok && gptkValidation.status == .ok && wineValidation.status == .ok && patchStatus == .ok {
            summary = "Ready to launch supported game launchers."
        } else {
            summary = "Setup is incomplete. Resolve diagnostics before launching."
        }

        let runtimeStatus = RuntimeStatus(
            architecture: architectureStatus,
            macOS: macOSStatus,
            gptk: gptkValidation.status,
            wine: wineValidation.status,
            patchset: patchStatus,
            summary: summary,
            gptkFingerprint: gptkValidation.fingerprint
        )

        return (runtimeStatus, checks)
    }

    public func validateGPTK(at path: String?) -> (status: HealthStatus, message: String, fingerprint: String?) {
        guard let path, !path.isEmpty else {
            return (.missing, "No GPTK path has been selected.", nil)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return (.missing, "Selected GPTK path does not exist.", nil)
        }

        if !isDirectory.boolValue {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.lowercased() == "dmg" else {
                return (.missing, "Selected GPTK path is not a directory or supported .dmg disk image.", nil)
            }
            return validateGPTKDiskImage(at: url)
        }

        return validateGPTKDirectory(at: path, sourceDescription: "Path")
    }

    public func defaultWineRuntimePath() -> String {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support?
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Runtimes", isDirectory: true)
            .appendingPathComponent("Wine", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("wine")
            .path ?? ""
    }

    public func resolveWineExecutablePath(for path: String?) -> String? {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedPath.isEmpty {
            return resolveWineExecutable(at: trimmedPath)
        }

        if let cachedPath = latestCachedSwitchyardWineExecutablePath() {
            return cachedPath
        }

        return resolveWineExecutable(at: defaultWineRuntimePath())
    }

    public func importGPTKDiskImage(at path: String, to importRoot: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "dmg" else {
            throw RuntimeLocatorError.unsupportedGPTKImportSource
        }

        let outerMount = try attachDiskImage(at: url.path)
        defer { detachDiskImage(outerMount) }

        for mount in outerMount.mountPoints {
            let markers = findGPTKMarkers(under: mount)
            if !markers.isEmpty {
                return try copyGPTKRuntime(from: mount, sourceImagePath: url.path, to: importRoot)
            }

            for nestedImage in findNestedDiskImages(under: mount) {
                let nestedMount = try attachDiskImage(at: nestedImage)
                defer { detachDiskImage(nestedMount) }

                for nestedMountPoint in nestedMount.mountPoints {
                    let nestedMarkers = findGPTKMarkers(under: nestedMountPoint)
                    if !nestedMarkers.isEmpty {
                        return try copyGPTKRuntime(from: nestedMountPoint, sourceImagePath: nestedImage, to: importRoot)
                    }
                }
            }
        }

        throw RuntimeLocatorError.noGPTKMarkersInDiskImage
    }

    private func validateGPTKDirectory(at path: String, sourceDescription: String) -> (status: HealthStatus, message: String, fingerprint: String?) {
        let markers = findGPTKMarkers(under: path)
        guard !markers.isEmpty else {
            return (.warning, "\(sourceDescription) exists, but no known D3DMetal/GPTK marker files were found.", fingerprint(forMarkersAt: path, markers: []))
        }

        return (.ok, "GPTK markers found: \(markers.prefix(3).joined(separator: ", ")).", fingerprint(forMarkersAt: path, markers: markers))
    }

    private func validateGPTKDiskImage(at url: URL) -> (status: HealthStatus, message: String, fingerprint: String?) {
        do {
            let outerMount = try attachDiskImage(at: url.path)
            defer { detachDiskImage(outerMount) }

            for mount in outerMount.mountPoints {
                let markers = findGPTKMarkers(under: mount)
                if !markers.isEmpty {
                    return (.warning, "GPTK disk image is valid and can be imported automatically. Markers found: \(markers.prefix(3).joined(separator: ", ")).", fingerprint(forMarkersAt: mount, markers: markers))
                }

                for nestedImage in findNestedDiskImages(under: mount) {
                    let nestedMount = try attachDiskImage(at: nestedImage)
                    defer { detachDiskImage(nestedMount) }

                    for nestedMountPoint in nestedMount.mountPoints {
                        let nestedMarkers = findGPTKMarkers(under: nestedMountPoint)
                        if !nestedMarkers.isEmpty {
                            let nestedName = URL(fileURLWithPath: nestedImage).lastPathComponent
                            return (.warning, "GPTK disk image contains \(nestedName) and can be imported automatically. Markers found: \(nestedMarkers.prefix(3).joined(separator: ", ")).", fingerprint(forMarkersAt: nestedMountPoint, markers: nestedMarkers))
                        }
                    }
                }
            }

            return (.warning, "GPTK disk image mounted, but no known D3DMetal/GPTK marker files were found.", fingerprint(forMarkersAt: url.path, markers: []))
        } catch {
            return (.warning, "Selected GPTK disk image could not be mounted: \(error.localizedDescription)", fingerprint(forMarkersAt: url.path, markers: []))
        }
    }

    private func validateWine(at path: String?) -> WineValidation {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = trimmedPath.isEmpty ? (latestCachedSwitchyardWineExecutablePath() ?? defaultWineRuntimePath()) : trimmedPath

        if let resolvedPath = resolveWineExecutable(at: candidate) {
            return describeWine(at: resolvedPath)
        }

        if trimmedPath.isEmpty {
            return WineValidation(
                status: .missing,
                message: "No Wine runtime has been selected. Expected Switchyard runtime cache under \(switchyardRuntimeCacheRoot().path) or \(defaultWineRuntimePath())."
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) else {
            return WineValidation(status: .missing, message: "Selected Wine path does not exist: \(candidate).")
        }

        if isDirectory.boolValue {
            return WineValidation(
                status: .missing,
                message: "Selected Wine directory exists, but no executable wine or wine64 was found in expected locations: \(candidate)."
            )
        }

        return WineValidation(status: .missing, message: "Selected Wine path exists but is not executable: \(candidate).")
    }

    private func describeWine(at resolvedPath: String) -> WineValidation {
        guard let rootURL = runtimeRoot(forWineExecutable: resolvedPath),
              let manifest = loadSwitchyardRuntimeManifest(under: rootURL) else {
            return WineValidation(status: .ok, message: "Wine executable found at \(resolvedPath).")
        }

        let runtimeID = manifest.id ?? rootURL.lastPathComponent
        let profile = manifest.buildProfile ?? "unknown profile"
        let missingArchitectures = ["i386", "x86_64"].filter {
            !hasPEArchitecture($0, under: rootURL, manifest: manifest)
        }

        if !missingArchitectures.isEmpty {
            return WineValidation(
                status: .warning,
                message: "Switchyard Wine runtime \(runtimeID) is selected at \(resolvedPath), but it is missing PE architecture(s): \(missingArchitectures.joined(separator: ", ")). Rebuild the Switchyard WoW64 runtime before installing the official Steam bootstrap."
            )
        }

        let declaredArchitectures = manifest.peArchitectures?.sorted().joined(separator: ", ") ?? "i386, x86_64"
        return WineValidation(
            status: .ok,
            message: "Switchyard Wine runtime \(runtimeID) (\(profile)) found at \(resolvedPath). PE architectures: \(declaredArchitectures)."
        )
    }

    private func resolveWineExecutable(at path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }

        if !isDirectory.boolValue {
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }

        let baseURL = URL(fileURLWithPath: path, isDirectory: true)
        let candidateRelativePaths = [
            "bin/switchyard-wine",
            "bin/wine",
            "bin/wine64",
            "wine",
            "wine64",
            "Contents/Resources/wine/bin/wine",
            "Contents/Resources/wine/bin/wine64",
            "Contents/SharedSupport/wine/bin/wine",
            "Contents/SharedSupport/wine/bin/wine64",
            "Contents/SharedSupport/CrossOver/bin/wine",
            "Contents/SharedSupport/CrossOver/bin/wine64"
        ]

        for relativePath in candidateRelativePaths {
            let candidate = baseURL.appendingPathComponent(relativePath).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func latestCachedSwitchyardWineExecutablePath() -> String? {
        let cacheRoot = switchyardRuntimeCacheRoot()
        guard let runtimeURLs = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = runtimeURLs.compactMap { runtimeURL -> SwitchyardRuntimeCandidate? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: runtimeURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let manifest = loadSwitchyardRuntimeManifest(under: runtimeURL) else {
                return nil
            }

            let manifestURL = runtimeURL.appendingPathComponent("switchyard-runtime.json")
            let modifiedAt = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let executable = manifest.executable.flatMap { resolveWineExecutable(at: $0) }
                ?? resolveWineExecutable(at: runtimeURL.path)

            guard let executable else {
                return nil
            }

            let isCompleteWoW64 = hasPEArchitecture("i386", under: runtimeURL, manifest: manifest)
                && hasPEArchitecture("x86_64", under: runtimeURL, manifest: manifest)
            return SwitchyardRuntimeCandidate(winePath: executable, modifiedAt: modifiedAt, isCompleteWoW64: isCompleteWoW64)
        }

        return candidates.sorted {
            if $0.isCompleteWoW64 != $1.isCompleteWoW64 {
                return $0.isCompleteWoW64
            }
            return $0.modifiedAt > $1.modifiedAt
        }.first?.winePath
    }

    private func switchyardRuntimeCacheRoot() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".switchyard", isDirectory: true)
            .appendingPathComponent("runtimes", isDirectory: true)
    }

    private func runtimeRoot(forWineExecutable path: String) -> URL? {
        let wineURL = URL(fileURLWithPath: path)
        let parent = wineURL.deletingLastPathComponent()
        if parent.lastPathComponent == "bin" {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    private func loadSwitchyardRuntimeManifest(under rootURL: URL) -> SwitchyardRuntimeManifest? {
        let manifestURL = rootURL.appendingPathComponent("switchyard-runtime.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(SwitchyardRuntimeManifest.self, from: data)
    }

    private func hasPEArchitecture(_ architecture: String, under rootURL: URL, manifest: SwitchyardRuntimeManifest) -> Bool {
        if let declaredArchitectures = manifest.peArchitectures,
           !declaredArchitectures.contains(architecture) {
            return false
        }

        return fileManager.fileExists(
            atPath: rootURL
                .appendingPathComponent("lib/wine", isDirectory: true)
                .appendingPathComponent("\(architecture)-windows", isDirectory: true)
                .appendingPathComponent("ntdll.dll")
                .path
        )
    }

    private var isAppleSilicon: Bool {
        machineHardwareName == "arm64"
    }

    private var isSupportedMacOS: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
    }

    private var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var machineHardwareName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private func findGPTKMarkers(under path: String) -> [String] {
        let markerNames: Set<String> = [
            "libd3dmetal.dylib",
            "libd3dshared.dylib",
            "D3DMetal.framework",
            "gameportingtoolkit"
        ]

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return []
        }

        var markers: [String] = []
        for case let item as String in enumerator {
            let name = URL(fileURLWithPath: item).lastPathComponent
            if markerNames.contains(name) {
                markers.append(item)
            }
            if markers.count >= 8 {
                break
            }
        }
        return markers
    }

    private func findNestedDiskImages(under path: String) -> [String] {
        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return []
        }

        var images: [String] = []
        for case let item as String in enumerator {
            let url = URL(fileURLWithPath: item)
            if url.pathExtension.lowercased() == "dmg" {
                images.append(URL(fileURLWithPath: path).appendingPathComponent(item).path)
            }
            if images.count >= 4 {
                break
            }
        }
        return images
    }

    private func copyGPTKRuntime(from sourcePath: String, sourceImagePath: String, to importRoot: String) throws -> String {
        let destination = importDestination(forDiskImageAt: sourceImagePath, under: importRoot)
        if fileManager.fileExists(atPath: destination),
           validateGPTK(at: destination).status == .ok {
            return destination
        }

        let rootURL = URL(fileURLWithPath: importRoot, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let destinationURL = URL(fileURLWithPath: destination, isDirectory: true)
        let temporaryURL = rootURL.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: true)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.copyItem(at: URL(fileURLWithPath: sourcePath, isDirectory: true), to: temporaryURL)
        guard !findGPTKMarkers(under: temporaryURL.path).isEmpty else {
            throw RuntimeLocatorError.noGPTKMarkersInImportedRuntime
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        shouldRemoveTemporary = false
        return destinationURL.path
    }

    private func importDestination(forDiskImageAt path: String, under importRoot: String) -> String {
        let url = URL(fileURLWithPath: path)
        let baseName = sanitizedRuntimeName(url.deletingPathExtension().lastPathComponent)
        let attributes = (try? fileManager.attributesOfItem(atPath: path)) ?? [:]
        let size = attributes[.size] as? UInt64 ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = fnvDigest("\(canonicalPath(path)):\(size):\(modified)")
        return URL(fileURLWithPath: importRoot, isDirectory: true)
            .appendingPathComponent("\(baseName)-\(digest)", isDirectory: true)
            .path
    }

    private func sanitizedRuntimeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var result = ""
        var previousWasSeparator = false

        for scalar in name.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("_")
                previousWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return trimmed.isEmpty ? "GPTK" : trimmed
    }

    private func attachDiskImage(at path: String) throws -> MountedDiskImage {
        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SwitchyardGPTK-\(UUID().uuidString)", isDirectory: true)
            .path
        try fileManager.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)

        var shouldCleanUpMountPoint = true
        defer {
            if shouldCleanUpMountPoint {
                _ = try? runHdiutil(arguments: ["detach", mountPoint])
                try? fileManager.removeItem(atPath: mountPoint)
            }
        }

        let output: Data
        do {
            output = try runHdiutil(arguments: ["attach", "-readonly", "-nobrowse", "-plist", "-mountpoint", mountPoint, path])
        } catch {
            if isResourceBusy(error),
               let existingMountPoints = try? existingMountPoints(forDiskImageAt: path),
               !existingMountPoints.isEmpty {
                return MountedDiskImage(mountPoints: existingMountPoints, ownedMountPointRoot: nil)
            }
            throw error
        }

        let plist = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
        guard let dictionary = plist as? [String: Any],
              let entities = dictionary["system-entities"] as? [[String: Any]] else {
            throw RuntimeLocatorError.invalidDiskImageOutput
        }

        let mountPoints = entities.compactMap { $0["mount-point"] as? String }
        guard !mountPoints.isEmpty else {
            throw RuntimeLocatorError.noMountPoint
        }
        shouldCleanUpMountPoint = false
        return MountedDiskImage(mountPoints: mountPoints, ownedMountPointRoot: mountPoint)
    }

    private func detachDiskImage(_ mountedImage: MountedDiskImage) {
        guard let ownedMountPointRoot = mountedImage.ownedMountPointRoot else {
            return
        }

        for mountPoint in mountedImage.mountPoints.reversed() {
            if fileManager.fileExists(atPath: mountPoint) {
                _ = try? runHdiutil(arguments: ["detach", mountPoint])
            }
            try? fileManager.removeItem(atPath: mountPoint)
        }
        try? fileManager.removeItem(atPath: ownedMountPointRoot)
    }

    private func existingMountPoints(forDiskImageAt path: String) throws -> [String] {
        let output = try runHdiutil(arguments: ["info", "-plist"])
        let plist = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
        guard let dictionary = plist as? [String: Any],
              let images = dictionary["images"] as? [[String: Any]] else {
            throw RuntimeLocatorError.invalidDiskImageOutput
        }

        let targetPath = canonicalPath(path)
        for image in images {
            guard let imagePath = image["image-path"] as? String else {
                continue
            }

            guard canonicalPath(imagePath) == targetPath else {
                continue
            }

            let entities = image["system-entities"] as? [[String: Any]] ?? []
            let mountPoints = entities.compactMap { $0["mount-point"] as? String }
            if !mountPoints.isEmpty {
                return mountPoints
            }
        }

        return []
    }

    private func isResourceBusy(_ error: Error) -> Bool {
        guard case RuntimeLocatorError.hdiutilFailed(let message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("Resource busy")
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func runHdiutil(arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutilPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        try process.run()

        if semaphore.wait(timeout: .now() + hdiutilTimeout) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw RuntimeLocatorError.hdiutilTimedOut
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0 {
            return output
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw RuntimeLocatorError.hdiutilFailed(errorMessage ?? "hdiutil exited with status \(process.terminationStatus)")
    }

    private func fingerprint(forMarkersAt rootPath: String, markers: [String]) -> String {
        let markerInput = markers.sorted().map { marker in
            let fullPath = URL(fileURLWithPath: rootPath).appendingPathComponent(marker).path
            let attributes = (try? fileManager.attributesOfItem(atPath: fullPath)) ?? [:]
            let size = attributes[.size] as? UInt64 ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(marker):\(size):\(modified)"
        }.joined(separator: "|")
        let input = markerInput.isEmpty ? "no-markers" : markerInput
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "gptk-%016llx", hash)
    }

    private func fnvDigest(_ input: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private enum RuntimeLocatorError: LocalizedError {
    case hdiutilFailed(String)
    case hdiutilTimedOut
    case invalidDiskImageOutput
    case noMountPoint
    case noGPTKMarkersInDiskImage
    case noGPTKMarkersInImportedRuntime
    case unsupportedGPTKImportSource

    var errorDescription: String? {
        switch self {
        case .hdiutilFailed(let message):
            return message
        case .hdiutilTimedOut:
            return "hdiutil timed out while mounting the disk image."
        case .invalidDiskImageOutput:
            return "hdiutil returned an unexpected plist."
        case .noMountPoint:
            return "hdiutil did not report a mounted volume."
        case .noGPTKMarkersInDiskImage:
            return "The disk image did not contain known D3DMetal/GPTK marker files."
        case .noGPTKMarkersInImportedRuntime:
            return "The imported runtime did not contain known D3DMetal/GPTK marker files."
        case .unsupportedGPTKImportSource:
            return "Only .dmg disk images can be imported automatically."
        }
    }
}

private struct MountedDiskImage {
    var mountPoints: [String]
    var ownedMountPointRoot: String?
}

private struct WineValidation {
    var status: HealthStatus
    var message: String
}
