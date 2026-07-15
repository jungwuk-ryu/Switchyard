import AppCore
import Foundation

enum InstalledProgramIconResolver {
    static func iconData(for program: InstalledProgram) async -> Data? {
        await Task.detached(priority: .utility) {
            resolveIconData(for: program)
        }.value
    }

    private static func resolveIconData(for program: InstalledProgram) -> Data? {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: program.installDirectory, isDirectory: true)
        let executableStem = URL(fileURLWithPath: program.executablePath)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        let programStem = program.name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let rootPath = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        var candidates: [(score: Int, url: URL)] = []
        var directories: [(url: URL, depth: Int)] = [(directoryURL, 0)]
        var visitedDirectories: Set<String> = [rootPath]
        var inspectedCount = 0

        while !directories.isEmpty, inspectedCount <= 2_000 {
            let directory = directories.removeFirst()
            guard
                let urls = try? fileManager.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }

            for url in urls.sorted(by: { $0.path < $1.path }) {
                inspectedCount += 1
                guard inspectedCount <= 2_000 else { break }
                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .isDirectoryKey, .isRegularFileKey,
                ])
                if values?.isDirectory == true {
                    let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                    let staysInsideProgram =
                        resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/")
                    if directory.depth < 6,
                        staysInsideProgram,
                        visitedDirectories.insert(resolvedPath).inserted
                    {
                        directories.append((url, directory.depth + 1))
                    }
                    continue
                }

                let fileExtension = url.pathExtension.lowercased()
                guard ["ico", "icns", "png", "jpg", "jpeg"].contains(fileExtension),
                    values?.isRegularFile == true,
                    let fileSize = values?.fileSize,
                    fileSize > 0,
                    fileSize <= 8_000_000
                else {
                    continue
                }

                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                let compactStem = stem.filter { $0.isLetter || $0.isNumber }
                let compactPath = url.path.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "/" }
                var score = fileExtension == "ico" || fileExtension == "icns" ? 40 : 0
                if stem == executableStem { score += 100 }
                if compactStem == programStem { score += 90 }
                if stem.contains(executableStem), executableStem.count >= 4 { score += 55 }
                if compactPath.contains("/\(programStem)/"), programStem.count >= 4 { score += 30 }
                if stem.contains("icon") { score += 35 }
                if stem.contains("logo") { score += 25 }
                if directory.depth == 0 { score += 15 }
                guard score >= 35 else { continue }
                candidates.append((score, url))
            }
        }

        for candidate in candidates.sorted(by: { lhs, rhs in
            lhs.score == rhs.score ? lhs.url.path < rhs.url.path : lhs.score > rhs.score
        }) {
            if let data = try? Data(contentsOf: candidate.url, options: [.mappedIfSafe]), !data.isEmpty {
                return data
            }
        }
        return nil
    }
}
