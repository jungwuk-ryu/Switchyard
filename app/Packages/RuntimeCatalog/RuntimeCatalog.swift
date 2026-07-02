import AppCore
import Darwin
import Foundation

public struct RuntimeLocator {
    public var fileManager: FileManager
    private let hdiutilPath = "/usr/bin/hdiutil"
    private let hdiutilTimeout: DispatchTimeInterval = .seconds(20)

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func diagnose(gptkPath: String?, winePath: String?, patchSeriesPath: String = "patches/wine/series") -> (RuntimeStatus, [DiagnosticCheck]) {
        let architectureStatus = isAppleSilicon ? HealthStatus.ok : .unsupported
        let macOSStatus = isSupportedMacOS ? HealthStatus.ok : .unsupported
        let gptkValidation = validateGPTK(at: gptkPath)
        let wineStatus = validateWine(at: winePath)
        let patchStatus: HealthStatus = fileManager.fileExists(atPath: patchSeriesPath) ? .ok : .missing

        let checks = [
            DiagnosticCheck(
                id: "apple-silicon",
                title: "Apple Silicon",
                status: architectureStatus,
                result: isAppleSilicon ? "Running on \(machineHardwareName)." : "Switchyard v1 supports Apple Silicon only.",
                recoveryAction: architectureStatus == .ok ? nil : "Use an Apple Silicon Mac."
            ),
            DiagnosticCheck(
                id: "macos-version",
                title: "macOS Version",
                status: macOSStatus,
                result: "Detected macOS \(operatingSystemVersion).",
                recoveryAction: macOSStatus == .ok ? nil : "Upgrade to a supported macOS release."
            ),
            DiagnosticCheck(
                id: "gptk",
                title: "Game Porting Toolkit",
                status: gptkValidation.status,
                result: gptkValidation.message,
                recoveryAction: gptkValidation.status == .ok ? nil : "Choose a local Apple GPTK installation in Settings."
            ),
            DiagnosticCheck(
                id: "wine-runtime",
                title: "Wine Runtime",
                status: wineStatus,
                result: wineStatus == .ok ? "Wine executable found." : "No cached Switchyard Wine runtime found.",
                recoveryAction: wineStatus == .ok ? nil : "Build or select a Wine runtime."
            ),
            DiagnosticCheck(
                id: "patch-series",
                title: "Wine Patch Series",
                status: patchStatus,
                result: patchStatus == .ok ? "Patch queue metadata is present." : "Patch queue metadata is missing.",
                recoveryAction: patchStatus == .ok ? nil : "Create patches/wine/series."
            )
        ]

        let summary: String
        if architectureStatus == .ok && macOSStatus == .ok && gptkValidation.status == .ok && wineStatus == .ok && patchStatus == .ok {
            summary = "Ready to launch supported game launchers."
        } else {
            summary = "Setup is incomplete. Resolve diagnostics before launching."
        }

        let runtimeStatus = RuntimeStatus(
            architecture: architectureStatus,
            macOS: macOSStatus,
            gptk: gptkValidation.status,
            wine: wineStatus,
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

    private func validateGPTKDirectory(at path: String, sourceDescription: String) -> (status: HealthStatus, message: String, fingerprint: String?) {
        let markers = findGPTKMarkers(under: path)
        guard !markers.isEmpty else {
            return (.warning, "\(sourceDescription) exists, but no known D3DMetal/GPTK marker files were found.", fingerprint(forMarkersAt: path, markers: []))
        }

        return (.ok, "GPTK markers found: \(markers.prefix(3).joined(separator: ", ")).", fingerprint(forMarkersAt: path, markers: markers))
    }

    private func validateGPTKDiskImage(at url: URL) -> (status: HealthStatus, message: String, fingerprint: String?) {
        do {
            let outerMounts = try attachDiskImage(at: url.path)
            defer { detachDiskImages(at: outerMounts) }

            for mount in outerMounts {
                let markers = findGPTKMarkers(under: mount)
                if !markers.isEmpty {
                    return (.warning, "GPTK disk image is valid, but it must be installed or mounted as a directory before launch. Markers found: \(markers.prefix(3).joined(separator: ", ")).", fingerprint(forMarkersAt: mount, markers: markers))
                }

                for nestedImage in findNestedDiskImages(under: mount) {
                    let nestedMounts = try attachDiskImage(at: nestedImage)
                    defer { detachDiskImages(at: nestedMounts) }

                    for nestedMount in nestedMounts {
                        let nestedMarkers = findGPTKMarkers(under: nestedMount)
                        if !nestedMarkers.isEmpty {
                            let nestedName = URL(fileURLWithPath: nestedImage).lastPathComponent
                            return (.warning, "GPTK disk image contains \(nestedName), but the evaluation environment must be installed or mounted as a directory before launch. Markers found: \(nestedMarkers.prefix(3).joined(separator: ", ")).", fingerprint(forMarkersAt: nestedMount, markers: nestedMarkers))
                        }
                    }
                }
            }

            return (.warning, "GPTK disk image mounted, but no known D3DMetal/GPTK marker files were found.", fingerprint(forMarkersAt: url.path, markers: []))
        } catch {
            return (.warning, "Selected GPTK disk image could not be mounted: \(error.localizedDescription)", fingerprint(forMarkersAt: url.path, markers: []))
        }
    }

    private func validateWine(at path: String?) -> HealthStatus {
        let candidate = path?.isEmpty == false ? path! : defaultWineRuntimePath()
        return fileManager.isExecutableFile(atPath: candidate) ? .ok : .missing
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

    private func attachDiskImage(at path: String) throws -> [String] {
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
        return mountPoints
    }

    private func detachDiskImages(at mountPoints: [String]) {
        for mountPoint in mountPoints.reversed() {
            if fileManager.fileExists(atPath: mountPoint) {
                _ = try? runHdiutil(arguments: ["detach", mountPoint])
            }
            try? fileManager.removeItem(atPath: mountPoint)
        }
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
}

private enum RuntimeLocatorError: LocalizedError {
    case hdiutilFailed(String)
    case hdiutilTimedOut
    case invalidDiskImageOutput
    case noMountPoint

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
        }
    }
}
