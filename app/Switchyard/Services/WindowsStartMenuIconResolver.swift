import AppCore
import Foundation
import Persistence

enum WindowsStartMenuIconResolver {
    private static let cache = WindowsStartMenuIconCache()

    static func iconData(
        for entry: WindowsStartMenuEntry,
        prefixPath: String
    ) async -> Data? {
        let sources = await Task.detached(priority: .utility) {
            WindowsShortcutIconExtractor.sources(
                for: entry,
                prefixPath: prefixPath
            )
        }.value
        guard !Task.isCancelled else { return nil }
        for source in sources {
            guard !Task.isCancelled else { return nil }
            if let iconData = await cache.iconData(from: source) {
                return iconData
            }
        }
        return nil
    }
}

private actor WindowsStartMenuIconCache {
    private let maximumEntryCount = 32

    private struct Key: Hashable {
        let path: String
        let iconIndex: Int?
        let fileSize: Int?
        let modificationDate: Date?
    }

    private var tasksByKey: [Key: Task<Data?, Never>] = [:]
    private var keyOrder: [Key] = []

    func iconData(from source: WindowsShortcutIconSource) async -> Data? {
        let sourceURL = source.fileURL.standardizedFileURL
        let values = try? sourceURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let key = Key(
            path: sourceURL.path,
            iconIndex: source.iconIndex,
            fileSize: values?.fileSize,
            modificationDate: values?.contentModificationDate
        )
        if let task = tasksByKey[key] {
            keyOrder.removeAll { $0 == key }
            keyOrder.append(key)
            return await task.value
        }

        tasksByKey = tasksByKey.filter { cachedKey, _ in
            cachedKey.path != key.path || cachedKey.iconIndex != key.iconIndex
        }
        keyOrder.removeAll {
            $0.path == key.path && $0.iconIndex == key.iconIndex
        }
        let task = Task<Data?, Never>.detached(priority: .utility) {
            guard let iconData = WindowsShortcutIconExtractor.iconData(from: source),
                  InstalledProgramIconResolver.isUsableIconData(iconData) else {
                return nil
            }
            return iconData
        }
        tasksByKey[key] = task
        keyOrder.append(key)
        while keyOrder.count > maximumEntryCount {
            tasksByKey.removeValue(forKey: keyOrder.removeFirst())
        }
        return await task.value
    }
}
