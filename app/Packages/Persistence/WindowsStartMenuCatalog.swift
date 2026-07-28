import AppCore
import Foundation

public struct WindowsStartMenuCatalog {
    public struct Limits: Equatable, Sendable {
        private static let hardMaximumEntries = 4_096
        private static let hardMaximumVisitedItems = 50_000
        private static let hardMaximumGroupDepth = 16
        private static let hardMaximumUserDirectories = 256

        public let maximumEntries: Int
        public let maximumVisitedItems: Int
        public let maximumGroupDepth: Int
        public let maximumUserDirectories: Int

        public init(
            maximumEntries: Int = 512,
            maximumVisitedItems: Int = 16_384,
            maximumGroupDepth: Int = 8,
            maximumUserDirectories: Int = 64
        ) {
            self.maximumEntries = min(
                max(0, maximumEntries),
                Self.hardMaximumEntries
            )
            self.maximumVisitedItems = min(
                max(0, maximumVisitedItems),
                Self.hardMaximumVisitedItems
            )
            self.maximumGroupDepth = min(
                max(0, maximumGroupDepth),
                Self.hardMaximumGroupDepth
            )
            self.maximumUserDirectories = min(
                max(0, maximumUserDirectories),
                Self.hardMaximumUserDirectories
            )
        }
    }

    public var fileManager: FileManager
    public var limits: Limits

    public init(
        fileManager: FileManager = .default,
        limits: Limits = Limits()
    ) {
        self.fileManager = fileManager
        self.limits = limits
    }

    public func entries(in container: Container) -> [WindowsStartMenuEntry] {
        entries(prefixPath: container.path)
    }

    public func entries(prefixPath: String) -> [WindowsStartMenuEntry] {
        guard limits.maximumEntries > 0,
              limits.maximumVisitedItems > 0 else {
            return []
        }

        var budget = ScanBudget(remainingItems: limits.maximumVisitedItems)
        var entriesByPath: [String: WindowsStartMenuEntry] = [:]
        if let systemRoot = programsRoot(for: .allUsers, prefixPath: prefixPath) {
            scan(
                root: systemRoot,
                prefixPath: prefixPath,
                budget: &budget,
                entriesByPath: &entriesByPath
            )
        }
        if !budget.isExhausted, entriesByPath.count < limits.maximumEntries {
            scanUserPrograms(
                prefixPath: prefixPath,
                budget: &budget,
                entriesByPath: &entriesByPath
            )
        }

        return entriesByPath.values.sorted(by: entryPrecedes)
    }

    private func scanUserPrograms(
        prefixPath: String,
        budget: inout ScanBudget,
        entriesByPath: inout [String: WindowsStartMenuEntry]
    ) {
        guard limits.maximumUserDirectories > 0,
              let usersURL = safeUsersDirectoryURL(prefixPath: prefixPath),
              let enumerator = fileManager.enumerator(
                  at: usersURL,
                  includingPropertiesForKeys: [.fileResourceTypeKey],
                  options: [.skipsSubdirectoryDescendants],
                  errorHandler: { _, _ in true }
              ) else {
            return
        }

        var scannedUserDirectories = 0
        for case let userURL as URL in enumerator {
            guard budget.consume(),
                  entriesByPath.count < limits.maximumEntries else {
                break
            }
            guard itemType(at: userURL) == .typeDirectory else { continue }
            let userName = userURL.lastPathComponent
            guard let root = programsRoot(
                for: .user(userName),
                prefixPath: prefixPath
            ) else {
                continue
            }
            scan(
                root: root,
                prefixPath: prefixPath,
                budget: &budget,
                entriesByPath: &entriesByPath
            )
            scannedUserDirectories += 1
            if scannedUserDirectories >= limits.maximumUserDirectories
                || budget.isExhausted
                || entriesByPath.count >= limits.maximumEntries {
                break
            }
        }
    }

    private func programsRoot(
        for scope: WindowsStartMenuScope,
        prefixPath: String
    ) -> ProgramsRoot? {
        guard let windowsProgramsPath = WindowsStartMenuPath.programsPath(for: scope),
              let hostURL = WindowsStartMenuPath.hostProgramsDirectoryURL(
                  for: scope,
                  prefixPath: prefixPath,
                  fileManager: fileManager
              ) else {
            return nil
        }
        return ProgramsRoot(
            scope: scope,
            windowsProgramsPath: windowsProgramsPath,
            hostURL: hostURL
        )
    }

    private func scan(
        root: ProgramsRoot,
        prefixPath: String,
        budget: inout ScanBudget,
        entriesByPath: inout [String: WindowsStartMenuEntry]
    ) {
        guard let enumerator = fileManager.enumerator(
            at: root.hostURL,
            includingPropertiesForKeys: [.fileResourceTypeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        for case let candidateURL as URL in enumerator {
            guard budget.consume(),
                  entriesByPath.count < limits.maximumEntries else {
                break
            }

            let relativeComponents = relativePathComponents(
                from: root.hostURL,
                to: candidateURL
            )
            guard !relativeComponents.isEmpty else {
                continue
            }

            let type = itemType(at: candidateURL)
            if type == .typeSymbolicLink {
                continue
            }
            if type == .typeDirectory {
                if relativeComponents.count > limits.maximumGroupDepth {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard type == .typeRegular,
                  relativeComponents.count - 1 <= limits.maximumGroupDepth else {
                continue
            }

            let windowsPath = root.windowsProgramsPath
                + #"\"#
                + relativeComponents.joined(separator: #"\"#)
            guard let entry = WindowsStartMenuEntry(windowsShortcutPath: windowsPath),
                  entry.scope == root.scope,
                  entry.hostURL(
                      prefixPath: prefixPath,
                      fileManager: fileManager
                  )?.standardizedFileURL.path == candidateURL.standardizedFileURL.path else {
                continue
            }
            entriesByPath[entry.id] = entry
        }
    }

    private func safeUsersDirectoryURL(prefixPath: String) -> URL? {
        guard !prefixPath.isEmpty,
              (prefixPath as NSString).isAbsolutePath else {
            return nil
        }
        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true).standardizedFileURL
        let usersURL = prefixURL
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)
            .standardizedFileURL
        guard isContained(usersURL, in: prefixURL),
              isContained(
                  usersURL.resolvingSymlinksInPath().standardizedFileURL,
                  in: prefixURL.resolvingSymlinksInPath().standardizedFileURL
              ) else {
            return nil
        }

        var currentURL = prefixURL
        for component in ["drive_c", "users"] {
            guard itemType(at: currentURL) == .typeDirectory else { return nil }
            currentURL.appendPathComponent(component)
            guard itemType(at: currentURL) == .typeDirectory else { return nil }
        }
        return usersURL
    }

    private func relativePathComponents(from rootURL: URL, to candidateURL: URL) -> [String] {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            return []
        }
        return Array(candidateComponents.dropFirst(rootComponents.count))
    }

    private func itemType(at url: URL) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private func isContained(_ candidateURL: URL, in rootURL: URL) -> Bool {
        candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(rootURL.path + "/")
    }

    private func entryPrecedes(
        _ lhs: WindowsStartMenuEntry,
        _ rhs: WindowsStartMenuEntry
    ) -> Bool {
        let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        let groupComparison = lhs.groupPath.localizedStandardCompare(rhs.groupPath)
        if groupComparison != .orderedSame {
            return groupComparison == .orderedAscending
        }
        return lhs.windowsShortcutPath.localizedStandardCompare(rhs.windowsShortcutPath)
            == .orderedAscending
    }
}

private struct ProgramsRoot {
    var scope: WindowsStartMenuScope
    var windowsProgramsPath: String
    var hostURL: URL
}

private struct ScanBudget {
    var remainingItems: Int

    var isExhausted: Bool {
        remainingItems <= 0
    }

    mutating func consume() -> Bool {
        guard remainingItems > 0 else { return false }
        remainingItems -= 1
        return true
    }
}
