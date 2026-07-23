import AppCore
import Foundation
import Testing
@testable import Switchyard

@Test func debugRunLogStorePrunesByAgeAndCountWithoutTouchingOtherFiles() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let oldLog = root.appendingPathComponent("old.log")
    try Data("old".utf8).write(to: oldLog)
    try fileManager.setAttributes(
        [.modificationDate: now.addingTimeInterval(-8 * 24 * 60 * 60)],
        ofItemAtPath: oldLog.path
    )

    var recentLogs: [URL] = []
    for index in 0..<12 {
        let url = root.appendingPathComponent("recent-\(index).log")
        try Data(repeating: UInt8(index), count: index + 1).write(to: url)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(TimeInterval(index * 60))],
            ofItemAtPath: url.path
        )
        recentLogs.append(url)
    }
    let unrelatedFile = root.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: unrelatedFile)

    let store = DebugRunLogStore(rootURL: root)
    let snapshot = try store.prune(
        policy: DebugRunLogRetentionPolicy(
            retentionDays: 7,
            maximumFileCount: 10
        ),
        now: now
    )

    #expect(snapshot.fileCount == 10)
    #expect(!fileManager.fileExists(atPath: oldLog.path))
    #expect(!fileManager.fileExists(atPath: recentLogs[0].path))
    #expect(!fileManager.fileExists(atPath: recentLogs[1].path))
    #expect(fileManager.fileExists(atPath: recentLogs[2].path))
    #expect(fileManager.fileExists(atPath: unrelatedFile.path))
}

@Test func debugRunLogStoreReservesCapacityAndBuildsSafeRunFileNames() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    for index in 0..<10 {
        let url = root.appendingPathComponent("existing-\(index).log")
        try Data("log".utf8).write(to: url)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(TimeInterval(index))],
            ofItemAtPath: url.path
        )
    }

    let store = DebugRunLogStore(rootURL: root)
    let nextURL = try store.prepareLogURL(
        containerName: "My Container",
        executablePath: "/Games/My Game.exe",
        policy: DebugRunLogRetentionPolicy(
            retentionDays: 14,
            maximumFileCount: 10
        ),
        now: now,
        runID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
    )

    #expect(try store.snapshot().fileCount == 10)
    #expect(nextURL.lastPathComponent.hasSuffix("-12345678-My_Container-My_Game.log"))
    #expect(fileManager.fileExists(atPath: nextURL.path))
    let permissions = try fileManager.attributesOfItem(atPath: nextURL.path)[.posixPermissions]
        as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func debugRunLogStoreDeletesOnlyStoredLogFiles() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let logFile = root.appendingPathComponent("run.log")
    let unrelatedFile = root.appendingPathComponent("keep.txt")
    try Data("log".utf8).write(to: logFile)
    try Data("keep".utf8).write(to: unrelatedFile)

    let result = try DebugRunLogStore(rootURL: root).removeAllLogs()

    #expect(result.removedFileCount == 1)
    #expect(result.storage == .empty)
    #expect(!fileManager.fileExists(atPath: logFile.path))
    #expect(fileManager.fileExists(atPath: unrelatedFile.path))
}

@Test func debugRunLogStoreKeepsTheFileCapAcrossConcurrentReservations() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let store = DebugRunLogStore(rootURL: root)
    let failures = DebugLogReservationFailureCollector()
    DispatchQueue.concurrentPerform(iterations: 20) { index in
        do {
            _ = try store.prepareLogURL(
                containerName: "Concurrent",
                executablePath: "/Games/Game-\(index).exe",
                policy: DebugRunLogRetentionPolicy(
                    retentionDays: 14,
                    maximumFileCount: 10
                )
            )
        } catch {
            failures.append(error)
        }
    }

    #expect(failures.errors.isEmpty)
    #expect(try store.snapshot().fileCount == 10)
}

private final class DebugLogReservationFailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var errors: [Error] {
        lock.withLock { storage }
    }

    func append(_ error: Error) {
        lock.withLock {
            storage.append(error)
        }
    }
}
