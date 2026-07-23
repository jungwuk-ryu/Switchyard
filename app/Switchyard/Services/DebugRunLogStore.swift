import AppCore
import Darwin
import Foundation

struct DebugRunLogStorageSnapshot: Equatable, Sendable {
    static let empty = DebugRunLogStorageSnapshot(fileCount: 0, totalBytes: 0)

    var fileCount: Int
    var totalBytes: Int64
}

struct DebugRunLogRemovalResult: Equatable, Sendable {
    var removedFileCount: Int
    var storage: DebugRunLogStorageSnapshot
}

struct DebugRunLogStore: @unchecked Sendable {
    let rootURL: URL

    private let fileManager: FileManager
    private let lock: NSRecursiveLock

    init(
        rootURL: URL = Self.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        lock = NSRecursiveLock()
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DebugRuns", isDirectory: true)
    }

    func prepareLogURL(
        containerName: String,
        executablePath: String,
        policy: DebugRunLogRetentionPolicy,
        now: Date = Date(),
        runID: UUID = UUID()
    ) throws -> URL {
        try withLock {
            try ensureDirectory()
            _ = try prune(
                policy: policy,
                now: now,
                maximumFileCount: max(0, policy.maximumFileCount - 1)
            )

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: now)
            let shortRunID = String(runID.uuidString.prefix(8)).lowercased()
            let executableName = URL(fileURLWithPath: executablePath)
                .deletingPathExtension()
                .lastPathComponent
            let fileName = [
                stamp,
                shortRunID,
                sanitizeFilename(containerName),
                sanitizeFilename(executableName),
            ]
            .joined(separator: "-") + ".log"
            let fileURL = rootURL.appendingPathComponent(fileName)
            try reserveLogFile(at: fileURL)
            return fileURL
        }
    }

    func ensureDirectory() throws {
        try withLock {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootURL.path
            )
        }
    }

    func prune(
        policy: DebugRunLogRetentionPolicy,
        now: Date = Date()
    ) throws -> DebugRunLogStorageSnapshot {
        try withLock {
            try prune(
                policy: policy,
                now: now,
                maximumFileCount: policy.maximumFileCount
            )
        }
    }

    func removeAllLogs() throws -> DebugRunLogRemovalResult {
        try withLock {
            let entries = try logEntries()
            for entry in entries {
                try fileManager.removeItem(at: entry.url)
            }
            return DebugRunLogRemovalResult(
                removedFileCount: entries.count,
                storage: try snapshot()
            )
        }
    }

    func snapshot() throws -> DebugRunLogStorageSnapshot {
        try withLock {
            let entries = try logEntries()
            return DebugRunLogStorageSnapshot(
                fileCount: entries.count,
                totalBytes: entries.reduce(0) { $0 + $1.fileSize }
            )
        }
    }

    private func prune(
        policy: DebugRunLogRetentionPolicy,
        now: Date,
        maximumFileCount: Int
    ) throws -> DebugRunLogStorageSnapshot {
        let cutoff = now.addingTimeInterval(
            -TimeInterval(policy.retentionDays * 24 * 60 * 60)
        )
        var retained: [LogEntry] = []

        for entry in try logEntries() {
            if entry.modifiedAt < cutoff {
                try fileManager.removeItem(at: entry.url)
            } else {
                retained.append(entry)
            }
        }

        let overflow = retained
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .dropFirst(maximumFileCount)
        for entry in overflow {
            try fileManager.removeItem(at: entry.url)
        }
        return try snapshot()
    }

    private func logEntries() throws -> [LogEntry] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url in
            guard url.pathExtension.lowercased() == "log",
                  let values = try? url.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isRegularFileKey,
                    ]
                  ),
                  values.isRegularFile == true else {
                return nil
            }
            return LogEntry(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                fileSize: Int64(max(0, values.fileSize ?? 0))
            )
        }
    }

    private func sanitizeFilename(_ value: String) -> String {
        let legal = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        return value.unicodeScalars
            .map { legal.contains($0) ? String($0) : "_" }
            .joined()
    }

    private func reserveLogFile(at url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw posixError(operation: "reserve debug log")
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let error = posixError(operation: "protect reserved debug log")
            Darwin.close(descriptor)
            try? fileManager.removeItem(at: url)
            throw error
        }
        Darwin.close(descriptor)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func posixError(operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }

    private struct LogEntry {
        var url: URL
        var modifiedAt: Date
        var fileSize: Int64
    }
}
