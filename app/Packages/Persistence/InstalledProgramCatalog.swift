import AppCore
import Foundation

public struct InstalledProgramCatalog {
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func installedPrograms(in container: Container) -> [InstalledProgram] {
        let containerURL = URL(fileURLWithPath: container.path, isDirectory: true)
        var candidates: [ProgramCandidate] = []

        for rootURL in programFilesRoots(in: containerURL) where directoryExists(rootURL) {
            candidates.append(contentsOf: executableCandidates(under: rootURL, source: .programFiles))
        }

        if let defaultExecutable = defaultExecutableCandidate(for: container, containerURL: containerURL) {
            candidates.append(defaultExecutable)
        }

        return bestCandidates(from: candidates)
            .sorted(by: { lhs, rhs in
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return lhs.executableURL.path < rhs.executableURL.path
            })
            .map { candidate in
                InstalledProgram(
                    name: candidate.name,
                    executablePath: candidate.executableURL.path,
                    installDirectory: candidate.installDirectoryURL.path,
                    source: candidate.source
                )
            }
    }

    private func programFilesRoots(in containerURL: URL) -> [URL] {
        let driveC = containerURL.appendingPathComponent("drive_c", isDirectory: true)
        return [
            driveC.appendingPathComponent("Program Files", isDirectory: true),
            driveC.appendingPathComponent("Program Files (x86)", isDirectory: true)
        ]
    }

    private func executableCandidates(under rootURL: URL, source: InstalledProgramSource) -> [ProgramCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [ProgramCandidate] = []
        for case let executableURL as URL in enumerator {
            let relativeComponents = relativePathComponents(from: rootURL, to: executableURL)
            let resourceValues = try? executableURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if resourceValues?.isDirectory == true {
                if shouldSkipDirectory(relativeComponents) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard executableURL.pathExtension.lowercased() == "exe" else { continue }
            guard resourceValues?.isRegularFile == true else { continue }
            guard relativeComponents.count >= 2, relativeComponents.count <= 8 else { continue }
            guard !isIgnoredPath(relativeComponents) else { continue }

            let topLevelDirectoryURL = rootURL.appendingPathComponent(relativeComponents[0], isDirectory: true)
            let candidate = ProgramCandidate(
                name: displayName(for: executableURL, topLevelName: relativeComponents[0]),
                executableURL: executableURL,
                installDirectoryURL: topLevelDirectoryURL,
                topLevelName: relativeComponents[0],
                relativeComponents: relativeComponents,
                source: source,
                score: score(relativeComponents: relativeComponents, source: source)
            )
            candidates.append(candidate)
        }

        return candidates
    }

    private func defaultExecutableCandidate(for container: Container, containerURL: URL) -> ProgramCandidate? {
        guard let executablePath = container.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !executablePath.isEmpty else {
            return nil
        }

        let executableURL = URL(fileURLWithPath: executablePath)
        guard executableURL.pathExtension.lowercased() == "exe",
              isRegularFile(executableURL),
              isDescendant(executableURL, of: containerURL) else {
            return nil
        }

        let metadata = defaultExecutableMetadata(for: executableURL, containerURL: containerURL)
        return ProgramCandidate(
            name: displayName(for: executableURL, topLevelName: metadata.topLevelName),
            executableURL: executableURL,
            installDirectoryURL: metadata.installDirectoryURL,
            topLevelName: metadata.topLevelName,
            relativeComponents: metadata.relativeComponents,
            source: .defaultExecutable,
            score: score(relativeComponents: metadata.relativeComponents, source: .defaultExecutable) + 25
        )
    }

    private func defaultExecutableMetadata(
        for executableURL: URL,
        containerURL: URL
    ) -> (installDirectoryURL: URL, topLevelName: String, relativeComponents: [String]) {
        for rootURL in programFilesRoots(in: containerURL) where isDescendant(executableURL, of: rootURL) {
            let relativeComponents = relativePathComponents(from: rootURL, to: executableURL)
            if relativeComponents.count >= 2 {
                return (
                    rootURL.appendingPathComponent(relativeComponents[0], isDirectory: true),
                    relativeComponents[0],
                    relativeComponents
                )
            }
        }

        let installDirectoryURL = executableURL.deletingLastPathComponent()
        let topLevelName = installDirectoryURL.lastPathComponent
        return (installDirectoryURL, topLevelName, [topLevelName, executableURL.lastPathComponent])
    }

    private func bestCandidates(from candidates: [ProgramCandidate]) -> [ProgramCandidate] {
        var bestByDirectory: [String: ProgramCandidate] = [:]

        for candidate in candidates where candidate.score >= 0 {
            let key = candidate.installDirectoryURL.standardizedFileURL.resolvingSymlinksInPath().path
            guard let current = bestByDirectory[key] else {
                bestByDirectory[key] = candidate
                continue
            }

            if candidate.isBetterMatch(than: current) {
                bestByDirectory[key] = candidate
            }
        }

        return Array(bestByDirectory.values)
    }

    private func score(relativeComponents: [String], source: InstalledProgramSource) -> Int {
        let executableStem = URL(fileURLWithPath: relativeComponents.last ?? "").deletingPathExtension().lastPathComponent
        let executableName = normalizedName(executableStem)
        let topLevelName = normalizedName(relativeComponents.first ?? executableStem)
        var score = source == .defaultExecutable ? 40 : 0

        if executableName == topLevelName {
            score += 100
        } else if executableName.contains(topLevelName) || topLevelName.contains(executableName) {
            score += 80
        }

        if executableName.contains("launcher") || executableName.contains("client") {
            score += 18
        }

        score += max(0, 32 - (relativeComponents.count * 4))

        let pathText = normalizedName(relativeComponents.joined(separator: " "))
        for token in ["uninstall", "unins", "updater", "update", "crash", "reporter", "helper", "service", "setup", "installer", "repair", "redist", "vcredist", "dxsetup", "bootstrap"] where pathText.contains(token) {
            score -= 80
        }

        if pathText.contains("cef") || pathText.contains("crashpad") {
            score -= 120
        }

        return score
    }

    private func isIgnoredPath(_ relativeComponents: [String]) -> Bool {
        let pathText = normalizedName(relativeComponents.joined(separator: " "))
        return pathText.contains("uninstall")
            || pathText.contains("vcredist")
            || pathText.contains("dxsetup")
            || pathText.contains("redistributable")
    }

    private func shouldSkipDirectory(_ relativeComponents: [String]) -> Bool {
        guard !relativeComponents.isEmpty else { return false }
        if relativeComponents.count >= 8 {
            return true
        }

        let ignoredDirectoryNames: Set<String> = [
            "cache",
            "cef",
            "compatdata",
            "crashpad",
            "dumps",
            "htmlcache",
            "installer",
            "logs",
            "redistributable",
            "redist",
            "shadercache",
            "steamapps",
            "temp",
            "tmp",
            "uninstall"
        ]
        let leafName = normalizedName(relativeComponents.last ?? "")
        return ignoredDirectoryNames.contains(leafName)
    }

    private func relativePathComponents(from rootURL: URL, to fileURL: URL) -> [String] {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return []
        }
        return Array(fileComponents.dropFirst(rootComponents.count))
    }

    private func normalizedName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func displayName(for executableURL: URL, topLevelName: String) -> String {
        let executableName = URL(fileURLWithPath: executableURL.lastPathComponent)
            .deletingPathExtension()
            .lastPathComponent
        return normalizedName(executableName) == normalizedName(topLevelName) ? topLevelName : executableName
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    }

    private func isDescendant(_ url: URL, of ancestorURL: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let ancestorPath = ancestorURL.standardizedFileURL.resolvingSymlinksInPath().path
        return path == ancestorPath || path.hasPrefix(ancestorPath + "/")
    }
}

private struct ProgramCandidate {
    var name: String
    var executableURL: URL
    var installDirectoryURL: URL
    var topLevelName: String
    var relativeComponents: [String]
    var source: InstalledProgramSource
    var score: Int

    func isBetterMatch(than other: ProgramCandidate) -> Bool {
        if score != other.score {
            return score > other.score
        }

        if relativeComponents.count != other.relativeComponents.count {
            return relativeComponents.count < other.relativeComponents.count
        }

        return executableURL.path.localizedStandardCompare(other.executableURL.path) == .orderedAscending
    }
}
