import AppCore
import Foundation
import ImageIO
import Persistence

enum InstalledProgramIconResolver {
    private static let cache = InstalledProgramIconCache()

    static func iconData(for program: InstalledProgram) async -> Data? {
        await cache.iconData(for: program)
    }

    fileprivate static func resolveIconData(for program: InstalledProgram) -> Data? {
        let fileManager = FileManager.default
        let executableURL = URL(fileURLWithPath: program.executablePath)
        if let embeddedIcon = WindowsExecutableIconExtractor.iconData(at: executableURL),
           isUsableIconData(embeddedIcon) {
            return embeddedIcon
        }

        let directoryURL = URL(fileURLWithPath: program.installDirectory, isDirectory: true)
        let executableStem = executableURL
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
            if let data = try? Data(contentsOf: candidate.url, options: [.mappedIfSafe]),
               !data.isEmpty,
               isUsableIconData(data) {
                return data
            }
        }
        return nil
    }

    private static func isUsableIconData(_ data: Data) -> Bool {
        guard data.count <= 8_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0, imageCount <= 256 else { return false }

        var foundImage = false
        for index in 0..<imageCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                continue
            }
            guard width.intValue > 0,
                  height.intValue > 0,
                  width.intValue <= 1_024,
                  height.intValue <= 1_024 else {
                return false
            }
            foundImage = true
        }
        return foundImage
    }
}

private actor InstalledProgramIconCache {
    private let maximumEntryCount = 24

    private struct Key: Hashable {
        let path: String
        let fileSize: Int?
        let modificationDate: Date?
    }

    private var tasksByKey: [Key: Task<Data?, Never>] = [:]
    private var keyOrder: [Key] = []

    func iconData(for program: InstalledProgram) async -> Data? {
        let executableURL = URL(fileURLWithPath: program.executablePath).standardizedFileURL
        let resourceValues = try? executableURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let key = Key(
            path: executableURL.path,
            fileSize: resourceValues?.fileSize,
            modificationDate: resourceValues?.contentModificationDate
        )
        if let task = tasksByKey[key] {
            keyOrder.removeAll { $0 == key }
            keyOrder.append(key)
            return await task.value
        }

        tasksByKey = tasksByKey.filter { cachedKey, _ in
            cachedKey.path != key.path
        }
        keyOrder.removeAll { $0.path == key.path }
        let task = Task.detached(priority: .utility) {
            InstalledProgramIconResolver.resolveIconData(for: program)
        }
        tasksByKey[key] = task
        keyOrder.append(key)
        while keyOrder.count > maximumEntryCount {
            tasksByKey.removeValue(forKey: keyOrder.removeFirst())
        }
        return await task.value
    }
}
