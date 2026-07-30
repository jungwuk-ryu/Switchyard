import AppCore
import Foundation

public struct InstalledProgramCatalog {
    private static let knownStarterApplicationScoreBonus = 200

    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func installedPrograms(in container: Container) -> [InstalledProgram] {
        guard let boundary = containerBoundary(for: container) else {
            return []
        }
        var candidates: [ProgramCandidate] = []

        for proposedRootURL in programFilesRoots(in: boundary.canonicalRootURL) {
            guard let rootURL = validatedDirectoryURL(
                proposedRootURL,
                inside: boundary
            ) else {
                continue
            }
            candidates.append(
                contentsOf: executableCandidates(
                    under: rootURL,
                    source: .programFiles,
                    boundary: boundary
                )
            )
        }

        if let defaultExecutable = defaultExecutableCandidate(
            for: container,
            boundary: boundary
        ) {
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
            .map(\.installedProgram)
    }

    private func programFilesRoots(in containerURL: URL) -> [URL] {
        let driveC = containerURL.appendingPathComponent("drive_c", isDirectory: true)
        return [
            driveC.appendingPathComponent("Program Files", isDirectory: true),
            driveC.appendingPathComponent("Program Files (x86)", isDirectory: true)
        ]
    }

    private func executableCandidates(
        under rootURL: URL,
        source: InstalledProgramSource,
        boundary: ContainerBoundary
    ) -> [ProgramCandidate] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [ProgramCandidate] = []
        for case let listedURL as URL in enumerator {
            guard let resourceValues = try? listedURL.resourceValues(
                forKeys: resourceKeys
            ) else {
                enumerator.skipDescendants()
                continue
            }

            if resourceValues.isSymbolicLink == true {
                // The catalog deliberately rejects even container-internal links.
                // That keeps every returned path rooted in the enumerated tree and
                // avoids trusting a link that can be retargeted after discovery.
                enumerator.skipDescendants()
                continue
            }

            let relativeComponents = relativePathComponents(
                from: rootURL,
                to: listedURL
            )
            if resourceValues.isDirectory == true {
                if shouldSkipDirectory(relativeComponents) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard listedURL.pathExtension.lowercased() == "exe" else { continue }
            guard resourceValues.isRegularFile == true else { continue }
            guard relativeComponents.count >= 2, relativeComponents.count <= 8 else { continue }
            guard !isIgnoredPath(relativeComponents) else { continue }
            guard let executableURL = validatedRegularFileURL(
                listedURL,
                inside: boundary,
                scanRootURL: rootURL
            ) else {
                continue
            }

            let topLevelDirectoryURL = rootURL.appendingPathComponent(relativeComponents[0], isDirectory: true)
            var candidate = ProgramCandidate(
                name: displayName(for: executableURL, topLevelName: relativeComponents[0]),
                executableURL: executableURL,
                installDirectoryURL: topLevelDirectoryURL,
                topLevelName: relativeComponents[0],
                relativeComponents: relativeComponents,
                source: source,
                score: score(relativeComponents: relativeComponents, source: source)
            )
            if StarterApplicationCatalog.all.contains(where: {
                $0.recognizesInstalledProgram(candidate.installedProgram)
            }) {
                candidate.score += Self.knownStarterApplicationScoreBonus
            }
            candidates.append(candidate)
        }

        return candidates
    }

    private func defaultExecutableCandidate(
        for container: Container,
        boundary: ContainerBoundary
    ) -> ProgramCandidate? {
        guard let executablePath = container.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !executablePath.isEmpty else {
            return nil
        }

        let listedExecutableURL = URL(fileURLWithPath: executablePath)
        guard listedExecutableURL.pathExtension.lowercased() == "exe",
              let executableURL = validatedRegularFileURL(
                listedExecutableURL,
                inside: boundary
              ) else {
            return nil
        }

        let metadata = defaultExecutableMetadata(
            for: executableURL,
            boundary: boundary
        )
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
        boundary: ContainerBoundary
    ) -> (installDirectoryURL: URL, topLevelName: String, relativeComponents: [String]) {
        for proposedRootURL in programFilesRoots(in: boundary.canonicalRootURL) {
            guard let rootURL = validatedDirectoryURL(
                proposedRootURL,
                inside: boundary
            ), isComponentContained(executableURL, in: rootURL) else {
                continue
            }
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

    private func containerBoundary(for container: Container) -> ContainerBoundary? {
        let listedRootURL = URL(
            fileURLWithPath: container.path,
            isDirectory: true
        ).standardizedFileURL
        guard directoryExists(listedRootURL) else {
            return nil
        }

        let canonicalRootURL = listedRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard directoryExists(canonicalRootURL) else {
            return nil
        }
        return ContainerBoundary(
            listedRootURL: listedRootURL,
            canonicalRootURL: canonicalRootURL
        )
    }

    private func validatedDirectoryURL(
        _ url: URL,
        inside boundary: ContainerBoundary
    ) -> URL? {
        guard let confinedURL = confinedNonSymbolicURL(
            url,
            inside: boundary
        ), let values = try? confinedURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ), values.isDirectory == true,
           values.isSymbolicLink != true else {
            return nil
        }
        return confinedURL
    }

    private func validatedRegularFileURL(
        _ url: URL,
        inside boundary: ContainerBoundary,
        scanRootURL: URL? = nil
    ) -> URL? {
        guard let confinedURL = confinedNonSymbolicURL(
            url,
            inside: boundary
        ), scanRootURL.map({
            isComponentContained(confinedURL, in: $0)
        }) ?? true,
        let values = try? confinedURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true,
           values.isSymbolicLink != true else {
            return nil
        }
        return confinedURL
    }

    private func confinedNonSymbolicURL(
        _ url: URL,
        inside boundary: ContainerBoundary
    ) -> URL? {
        let standardizedURL = url.standardizedFileURL
        let relativeComponents: [String]
        if let canonicalRelativeComponents = containedRelativePathComponents(
            from: boundary.canonicalRootURL,
            to: standardizedURL
        ) {
            relativeComponents = canonicalRelativeComponents
        } else if let listedRelativeComponents = containedRelativePathComponents(
            from: boundary.listedRootURL,
            to: standardizedURL
        ) {
            relativeComponents = listedRelativeComponents
        } else {
            return nil
        }

        var projectedURL = boundary.canonicalRootURL
        for component in relativeComponents {
            projectedURL.appendPathComponent(component)
            guard let values = try? projectedURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ), values.isSymbolicLink != true else {
                return nil
            }
        }

        let resolvedURL = projectedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isComponentContained(
            resolvedURL,
            in: boundary.canonicalRootURL
        ) else {
            return nil
        }
        return projectedURL.standardizedFileURL
    }

    private func containedRelativePathComponents(
        from rootURL: URL,
        to candidateURL: URL
    ) -> [String]? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count))
                == rootComponents else {
            return nil
        }
        return Array(candidateComponents.dropFirst(rootComponents.count))
    }

    private func isComponentContained(
        _ candidateURL: URL,
        in rootURL: URL
    ) -> Bool {
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count))
                == rootComponents
    }
}

private struct ContainerBoundary {
    var listedRootURL: URL
    var canonicalRootURL: URL
}

private struct ProgramCandidate {
    var name: String
    var executableURL: URL
    var installDirectoryURL: URL
    var topLevelName: String
    var relativeComponents: [String]
    var source: InstalledProgramSource
    var score: Int

    var installedProgram: InstalledProgram {
        InstalledProgram(
            name: name,
            executablePath: executableURL.path,
            installDirectory: installDirectoryURL.path,
            source: source
        )
    }

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
