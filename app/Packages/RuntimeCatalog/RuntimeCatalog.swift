import AppCore
import Darwin
import Foundation
import Security

private struct SwitchyardRuntimeManifest: Decodable {
    var id: String?
    var buildProfile: String?
    var peArchitectures: [String]?
    var executable: String?
    var wineRevision: String?
    var sourceRepository: String?
    var sourceRevision: String?
    var sourceDirty: Bool?
    var patchsetID: String?
}

private struct SwitchyardRuntimeCandidate {
    var winePath: String
    var modifiedAt: Date
    var isCompleteWoW64: Bool
    var sourceRevision: String?
    var sourceDirty: Bool
}

public struct RuntimeLocator {
    public var fileManager: FileManager
    private let runtimeCacheRootOverride: URL?
    private let hdiutilPath = "/usr/bin/hdiutil"
    private let hdiutilTimeout: DispatchTimeInterval = .seconds(20)

    public init(fileManager: FileManager = .default, runtimeCacheRoot: URL? = nil) {
        self.fileManager = fileManager
        runtimeCacheRootOverride = runtimeCacheRoot
    }

    public func diagnose(
        gptkPath: String?,
        winePath: String?,
        expectedSourceRevision: String? = nil,
        fontCachePath: String? = nil
    ) -> (RuntimeStatus, [DiagnosticCheck]) {
        let architectureStatus = isAppleSilicon ? HealthStatus.ok : .unsupported
        let macOSStatus = isSupportedMacOS ? HealthStatus.ok : .unsupported
        let gptkValidation = validateGPTK(at: gptkPath)
        let wineValidation = validateWine(at: winePath, expectedSourceRevision: expectedSourceRevision)
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
                id: "runtime-source",
                title: "Wine Runtime Source",
                status: wineValidation.sourceStatus,
                result: wineValidation.sourceMessage,
                recoveryAction: wineValidation.sourceStatus == .ok ? nil : "Open Wine Settings"
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
        if architectureStatus == .ok && macOSStatus == .ok && gptkValidation.status == .ok && wineValidation.status == .ok && wineValidation.sourceStatus == .ok {
            summary = "Ready to launch Windows executables in Switchyard containers."
        } else {
            summary = "Setup is incomplete. Resolve diagnostics before launching."
        }

        let runtimeStatus = RuntimeStatus(
            architecture: architectureStatus,
            macOS: macOSStatus,
            gptk: gptkValidation.status,
            wine: wineValidation.status,
            patchset: wineValidation.sourceStatus,
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
            let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            let size = attributes[.size] as? UInt64 ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let fingerprint = "gptk-image-\(fnvDigest("\(canonicalPath(url.path)):\(size):\(modified)"))"
            return (
                .warning,
                "The selected GPTK disk image has not been imported. Use Import Selected GPTK to verify Apple-signed code before mounting it.",
                fingerprint
            )
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

    public func latestDownloadedGPTKDiskImage(in downloadsDirectory: URL? = nil) -> String? {
        let directory = downloadsDirectory
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let directory,
              let candidates = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        return candidates
            .compactMap { url -> (url: URL, modifiedAt: Date)? in
                guard url.pathExtension.lowercased() == "dmg" else { return nil }
                let normalizedName = url.deletingPathExtension().lastPathComponent
                    .lowercased()
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                guard normalizedName.contains("game porting toolkit")
                    || normalizedName.contains("gameportingtoolkit") else {
                    return nil
                }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return (url, values?.contentModificationDate ?? .distantPast)
            }
            .max(by: { $0.modifiedAt < $1.modifiedAt })?
            .url.path
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

    public func preferredWineExecutablePath(for path: String?, expectedSourceRevision: String? = nil) -> String? {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferredCachedPath = latestCachedSwitchyardWineExecutablePath(matchingSourceRevision: expectedSourceRevision)
            ?? latestCachedSwitchyardWineExecutablePath()

        if trimmedPath.isEmpty {
            return preferredCachedPath ?? resolveWineExecutable(at: defaultWineRuntimePath())
        }

        let isManagedCacheSelection = isSwitchyardRuntimeCachePath(trimmedPath)
        guard let resolvedPath = resolveWineExecutable(at: trimmedPath) else {
            return isManagedCacheSelection ? preferredCachedPath : nil
        }

        if isManagedCacheSelection || isManagedSwitchyardRuntimePath(resolvedPath) {
            guard let expectedSourceRevision else {
                return resolvedPath
            }
            if let rootURL = runtimeRoot(forWineExecutable: resolvedPath),
               let manifest = loadSwitchyardRuntimeManifest(under: rootURL),
               (manifest.sourceRevision ?? manifest.wineRevision) == expectedSourceRevision,
               manifest.sourceDirty != true,
               hasPEArchitecture("i386", under: rootURL, manifest: manifest),
               hasPEArchitecture("x86_64", under: rootURL, manifest: manifest) {
                return resolvedPath
            }
            return preferredCachedPath
        }

        return resolvedPath
    }

    public func runtimeBuild(for path: String?) -> RuntimeBuild {
        let resolvedPath = resolveWineExecutablePath(for: path)
            ?? path?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard let rootURL = runtimeRoot(forWineExecutable: resolvedPath),
              let manifest = loadSwitchyardRuntimeManifest(under: rootURL) else {
            return RuntimeBuild(
                id: "external-unverified",
                winePath: resolvedPath,
                patchsetID: "external-unverified",
                sourceRevision: ""
            )
        }

        let sourceRevision = manifest.sourceRevision ?? manifest.wineRevision ?? ""
        let patchsetID = manifest.patchsetID
            ?? (sourceRevision.isEmpty ? "switchyard-wine-unverified" : "switchyard-wine-\(sourceRevision.prefix(12))")
        let manifestURL = rootURL.appendingPathComponent("switchyard-runtime.json")
        let createdAt = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return RuntimeBuild(
            id: manifest.id ?? rootURL.lastPathComponent,
            winePath: resolvedPath,
            patchsetID: patchsetID,
            sourceRevision: sourceRevision,
            createdAt: createdAt
        )
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

        do {
            try validateNoEscapingSymbolicLinks(under: path)
            try validateAppleSignedMachOFiles(under: path)
        } catch {
            return (
                .warning,
                "\(sourceDescription) contains GPTK markers, but its executable code is not fully Apple-signed: \(error.localizedDescription)",
                fingerprint(forMarkersAt: path, markers: markers)
            )
        }

        return (.ok, "Apple-signed GPTK code and markers found: \(markers.prefix(3).joined(separator: ", ")).", fingerprint(forMarkersAt: path, markers: markers))
    }

    private func validateWine(at path: String?, expectedSourceRevision: String?) -> WineValidation {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate = trimmedPath.isEmpty ? (latestCachedSwitchyardWineExecutablePath() ?? defaultWineRuntimePath()) : trimmedPath

        if let resolvedPath = resolveWineExecutable(at: candidate) {
            return describeWine(at: resolvedPath, expectedSourceRevision: expectedSourceRevision)
        }

        if trimmedPath.isEmpty {
            return WineValidation(
                status: .missing,
                message: "No Wine runtime has been selected. Expected Switchyard runtime cache under \(switchyardRuntimeCacheRoot().path) or \(defaultWineRuntimePath()).",
                sourceStatus: .missing,
                sourceMessage: "No Wine runtime is available to verify against the pinned Switchyard Wine source."
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory) else {
            return WineValidation(
                status: .missing,
                message: "Selected Wine path does not exist: \(candidate).",
                sourceStatus: .missing,
                sourceMessage: "The selected Wine runtime does not exist, so its source identity cannot be verified."
            )
        }

        if isDirectory.boolValue {
            return WineValidation(
                status: .missing,
                message: "Selected Wine directory exists, but no executable wine or wine64 was found in expected locations: \(candidate).",
                sourceStatus: .missing,
                sourceMessage: "The selected directory is not a runnable Wine runtime, so its source identity cannot be verified."
            )
        }

        return WineValidation(
            status: .missing,
            message: "Selected Wine path exists but is not executable: \(candidate).",
            sourceStatus: .missing,
            sourceMessage: "The selected Wine file is not executable, so its source identity cannot be verified."
        )
    }

    private func describeWine(at resolvedPath: String, expectedSourceRevision: String?) -> WineValidation {
        guard let rootURL = runtimeRoot(forWineExecutable: resolvedPath),
              let manifest = loadSwitchyardRuntimeManifest(under: rootURL) else {
            let sourceStatus: HealthStatus = expectedSourceRevision == nil ? .ok : .warning
            return WineValidation(
                status: .ok,
                message: "Wine executable found at \(resolvedPath).",
                sourceStatus: sourceStatus,
                sourceMessage: expectedSourceRevision == nil
                    ? "External Wine runtime selected; no source revision policy was requested."
                    : "External Wine runtime selected, but it has no Switchyard manifest and cannot be verified against the pinned source revision."
            )
        }

        let runtimeID = manifest.id ?? rootURL.lastPathComponent
        let profile = manifest.buildProfile ?? "unknown profile"
        let sourceValidation = validateRuntimeSource(
            manifest,
            runtimeID: runtimeID,
            expectedSourceRevision: expectedSourceRevision
        )
        let missingArchitectures = ["i386", "x86_64"].filter {
            !hasPEArchitecture($0, under: rootURL, manifest: manifest)
        }

        if !missingArchitectures.isEmpty {
            return WineValidation(
                status: .warning,
                message: "Switchyard Wine runtime \(runtimeID) is selected at \(resolvedPath), but it is missing PE architecture(s): \(missingArchitectures.joined(separator: ", ")). Rebuild the Switchyard WoW64 runtime before running 32-bit Windows installers or programs.",
                sourceStatus: sourceValidation.status,
                sourceMessage: sourceValidation.message
            )
        }

        let declaredArchitectures = manifest.peArchitectures?.sorted().joined(separator: ", ") ?? "i386, x86_64"
        return WineValidation(
            status: .ok,
            message: "Switchyard Wine runtime \(runtimeID) (\(profile)) found at \(resolvedPath). PE architectures: \(declaredArchitectures).",
            sourceStatus: sourceValidation.status,
            sourceMessage: sourceValidation.message
        )
    }

    private func validateRuntimeSource(
        _ manifest: SwitchyardRuntimeManifest,
        runtimeID: String,
        expectedSourceRevision: String?
    ) -> RuntimeSourceValidation {
        guard let sourceRevision = manifest.sourceRevision ?? manifest.wineRevision else {
            return RuntimeSourceValidation(
                status: .warning,
                message: "Switchyard Wine runtime \(runtimeID) does not record a source revision. Rebuild it from the pinned switchyard-wine repository."
            )
        }

        let shortRevision = String(sourceRevision.prefix(12))
        let repository = manifest.sourceRepository ?? "unrecorded repository"
        if manifest.sourceDirty == true {
            return RuntimeSourceValidation(
                status: .warning,
                message: "Switchyard Wine runtime \(runtimeID) was built from a dirty source tree at \(shortRevision). Build a clean pinned revision before release use."
            )
        }

        if let expectedSourceRevision, sourceRevision != expectedSourceRevision {
            return RuntimeSourceValidation(
                status: .warning,
                message: "Switchyard Wine runtime \(runtimeID) was built from source \(shortRevision), but this Switchyard build pins \(expectedSourceRevision.prefix(12)). Rebuild the runtime from the pinned revision."
            )
        }

        return RuntimeSourceValidation(
            status: .ok,
            message: "Runtime source verified at \(repository) revision \(shortRevision)."
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

    private func latestCachedSwitchyardWineExecutablePath(matchingSourceRevision expectedSourceRevision: String? = nil) -> String? {
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
            return SwitchyardRuntimeCandidate(
                winePath: executable,
                modifiedAt: modifiedAt,
                isCompleteWoW64: isCompleteWoW64,
                sourceRevision: manifest.sourceRevision ?? manifest.wineRevision,
                sourceDirty: manifest.sourceDirty == true
            )
        }

        let matchingCandidates: [SwitchyardRuntimeCandidate]
        if let expectedSourceRevision {
            matchingCandidates = candidates.filter {
                $0.sourceRevision == expectedSourceRevision && !$0.sourceDirty
            }
        } else {
            matchingCandidates = candidates
        }

        let sortedCandidates = matchingCandidates.sorted {
            if $0.isCompleteWoW64 != $1.isCompleteWoW64 {
                return $0.isCompleteWoW64
            }
            return $0.modifiedAt > $1.modifiedAt
        }
        return sortedCandidates.first?.winePath
    }

    private func switchyardRuntimeCacheRoot() -> URL {
        if let runtimeCacheRootOverride {
            return runtimeCacheRootOverride
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".switchyard", isDirectory: true)
            .appendingPathComponent("runtimes", isDirectory: true)
    }

    private func isManagedSwitchyardRuntimePath(_ path: String) -> Bool {
        guard let rootURL = runtimeRoot(forWineExecutable: path),
              loadSwitchyardRuntimeManifest(under: rootURL) != nil else {
            return false
        }
        return isSwitchyardRuntimeCachePath(rootURL.path)
    }

    private func isSwitchyardRuntimeCachePath(_ path: String) -> Bool {
        let cacheRootPath = switchyardRuntimeCacheRoot().standardizedFileURL.path
        let candidatePath = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidatePath == cacheRootPath || candidatePath.hasPrefix(cacheRootPath + "/")
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
        try validateNoEscapingSymbolicLinks(under: sourcePath)
        try validateAppleSignedMachOFiles(under: sourcePath)
        let destination = importDestination(forDiskImageAt: sourceImagePath, under: importRoot)
        if fileManager.fileExists(atPath: destination) {
            guard validateGPTK(at: destination).status == .ok else {
                throw RuntimeLocatorError.importDestinationConflict
            }
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
        try validateNoEscapingSymbolicLinks(under: temporaryURL.path)
        try validateAppleSignedMachOFiles(under: temporaryURL.path)

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

    private func validateAppleSignedMachOFiles(under rootPath: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            throw RuntimeLocatorError.invalidAppleSigningRequirement
        }
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw RuntimeLocatorError.noAppleSignedGPTKCode
        }

        var machOCount = 0
        var signedRuntimeMarkerCount = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, try isMachOFile(url) else { continue }
            machOCount += 1
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
                  let code,
                  SecStaticCodeCheckValidity(
                    code,
                    SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                    requirement
                  ) == errSecSuccess else {
                throw RuntimeLocatorError.invalidGPTKCodeSignature(url.lastPathComponent)
            }
            let normalizedPath = url.path.lowercased()
            if normalizedPath.contains("d3dmetal") || normalizedPath.contains("d3dshared") {
                signedRuntimeMarkerCount += 1
            }
        }
        guard machOCount > 0, signedRuntimeMarkerCount > 0 else {
            throw RuntimeLocatorError.noAppleSignedGPTKCode
        }
    }

    private func validateNoEscapingSymbolicLinks(under rootPath: String) throws {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let resolvedRootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw RuntimeLocatorError.escapingGPTKSymbolicLink
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            guard !target.hasPrefix("/") else {
                throw RuntimeLocatorError.escapingGPTKSymbolicLink
            }
            let resolvedTarget = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            guard resolvedTarget == resolvedRootPath || resolvedTarget.hasPrefix(resolvedRootPath + "/") else {
                throw RuntimeLocatorError.escapingGPTKSymbolicLink
            }
        }
    }

    private func isMachOFile(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4), data.count == 4 else { return false }
        let bytes = Array(data)
        let magics: [[UInt8]] = [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]
        ]
        return magics.contains(bytes)
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
    case escapingGPTKSymbolicLink
    case hdiutilFailed(String)
    case hdiutilTimedOut
    case importDestinationConflict
    case invalidAppleSigningRequirement
    case invalidGPTKCodeSignature(String)
    case invalidDiskImageOutput
    case noMountPoint
    case noGPTKMarkersInDiskImage
    case noGPTKMarkersInImportedRuntime
    case noAppleSignedGPTKCode
    case unsupportedGPTKImportSource

    var errorDescription: String? {
        switch self {
        case .escapingGPTKSymbolicLink:
            return "The GPTK source contains a symbolic link outside its import directory."
        case .hdiutilFailed(let message):
            return message
        case .hdiutilTimedOut:
            return "hdiutil timed out while mounting the disk image."
        case .importDestinationConflict:
            return "A different GPTK import already exists at the immutable destination."
        case .invalidAppleSigningRequirement:
            return "The Apple code-signing requirement could not be created."
        case .invalidGPTKCodeSignature(let name):
            return "GPTK executable code has an invalid Apple signature: \(name)."
        case .invalidDiskImageOutput:
            return "hdiutil returned an unexpected plist."
        case .noMountPoint:
            return "hdiutil did not report a mounted volume."
        case .noGPTKMarkersInDiskImage:
            return "The disk image did not contain known D3DMetal/GPTK marker files."
        case .noGPTKMarkersInImportedRuntime:
            return "The imported runtime did not contain known D3DMetal/GPTK marker files."
        case .noAppleSignedGPTKCode:
            return "No Apple-signed GPTK executable code was found."
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
    var sourceStatus: HealthStatus
    var sourceMessage: String
}

private struct RuntimeSourceValidation {
    var status: HealthStatus
    var message: String
}
