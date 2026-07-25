import AppCore
import Darwin
import Foundation
import Testing
@testable import Switchyard

@Test func liveLogJournalStoreProtectsRetainsAndResetsContainerJournal() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = LiveLogJournalStore(rootURL: root)
    let containerID = UUID()
    let journalURL = try store.prepareJournal(for: containerID, reset: true)
    let generationURL = URL(
        fileURLWithPath: journalURL.path
            + LiveLogJournalFormat.resetGenerationSuffix
    )
    let initialGeneration = try Data(contentsOf: generationURL)
    try Data("retained\n".utf8).write(to: journalURL)

    _ = try store.prepareJournal(for: containerID, reset: false)
    #expect(try String(contentsOf: journalURL, encoding: .utf8) == "retained\n")
    #expect(try Data(contentsOf: generationURL) == initialGeneration)

    _ = try store.prepareJournal(for: containerID, reset: true)
    #expect((try Data(contentsOf: journalURL)).isEmpty)
    let resetGeneration = try Data(contentsOf: generationURL)
    #expect(resetGeneration.count == LiveLogJournalFormat.resetGenerationByteCount)
    #expect(resetGeneration != initialGeneration)

    let journalPermissions = try FileManager.default.attributesOfItem(
        atPath: journalURL.path
    )[.posixPermissions] as? NSNumber
    let generationPermissions = try FileManager.default.attributesOfItem(
        atPath: generationURL.path
    )[.posixPermissions] as? NSNumber
    let directoryPermissions = try FileManager.default.attributesOfItem(
        atPath: root.path
    )[.posixPermissions] as? NSNumber
    #expect(journalPermissions?.intValue == 0o600)
    #expect(generationPermissions?.intValue == 0o600)
    #expect(directoryPermissions?.intValue == 0o700)

    try store.removeJournal(for: containerID)
    #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    #expect(!FileManager.default.fileExists(atPath: generationURL.path))
}

@Test func liveLogViewActivityLeaseUsesAnAccountOnlyAdvisoryLock() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let lease = LiveLogViewActivityLease(rootURL: root)
    try lease.setActive(true)
    _ = try LiveLogJournalStore(rootURL: root).prepareJournal(
        for: UUID(),
        reset: true
    )

    let observerDescriptor = Darwin.open(
        lease.lockURL.path,
        O_RDONLY | O_NOFOLLOW
    )
    try #require(observerDescriptor >= 0)
    defer { Darwin.close(observerDescriptor) }

    #expect(flock(observerDescriptor, LOCK_SH | LOCK_NB) != 0)

    try lease.setActive(false)
    #expect(flock(observerDescriptor, LOCK_SH | LOCK_NB) == 0)
    flock(observerDescriptor, LOCK_UN)

    let lockPermissions = try FileManager.default.attributesOfItem(
        atPath: lease.lockURL.path
    )[.posixPermissions] as? NSNumber
    let directoryPermissions = try FileManager.default.attributesOfItem(
        atPath: root.path
    )[.posixPermissions] as? NSNumber
    #expect(lockPermissions?.intValue == 0o600)
    #expect(directoryPermissions?.intValue == 0o700)
}

@Test func liveLogJournalMonitorReplaysAndFollowsAfterTruncation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = LiveLogJournalStore(rootURL: root)
    let containerID = UUID()
    let journalURL = try store.prepareJournal(for: containerID, reset: true)
    try appendJournalLine(
        LogLine(
            level: "info",
            source: "Steam",
            message: "replayed-" + String(repeating: "x", count: 512)
        ),
        to: journalURL
    )

    let collector = LiveLogJournalCollector()
    let monitor = LiveLogJournalMonitor()
    try monitor.start(
        containerID: containerID,
        source: "Steam",
        journalURL: journalURL,
        replayLimit: 5_000,
        onLogs: collector.append
    )
    defer { monitor.stopAll() }

    try await waitForJournalMessages(count: 1, collector: collector)
    try appendJournalLine(
        LogLine(level: "warning", source: "Steam", message: "followed"),
        to: journalURL
    )
    try await waitForJournalMessages(count: 2, collector: collector)
    try store.clearJournal(for: containerID)
    try appendJournalLine(
        LogLine(level: "error", source: "Steam", message: "after-truncation"),
        to: journalURL
    )
    try await waitForJournalMessages(count: 3, collector: collector)

    let lines = collector.lines
    #expect(lines.map(\.message).suffix(2) == ["followed", "after-truncation"])
    #expect(lines.allSatisfy { $0.containerID == containerID })
}

@Test func liveLogJournalMonitorBoundsRelaunchReplay() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = LiveLogJournalStore(rootURL: root)
    let containerID = UUID()
    let journalURL = try store.prepareJournal(for: containerID, reset: true)
    for index in 0..<10 {
        try appendJournalLine(
            LogLine(level: "info", source: "Steam", message: "line-\(index)"),
            to: journalURL
        )
    }

    let collector = LiveLogJournalCollector()
    let monitor = LiveLogJournalMonitor()
    try monitor.start(
        containerID: containerID,
        source: "Steam",
        journalURL: journalURL,
        replayLimit: 3,
        onLogs: collector.append
    )
    defer { monitor.stopAll() }

    #expect(collector.lines.map(\.message) == ["line-7", "line-8", "line-9"])
}

@Test func liveLogJournalMonitorSuppressesPendingDeliveryAfterStop() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = LiveLogJournalStore(rootURL: root)
    let containerID = UUID()
    let journalURL = try store.prepareJournal(for: containerID, reset: true)
    let collector = LiveLogJournalCollector()
    let monitor = LiveLogJournalMonitor(deliveryInterval: 1)
    try monitor.start(
        containerID: containerID,
        source: "Steam",
        journalURL: journalURL,
        replayLimit: 5_000,
        onLogs: collector.append
    )

    try appendJournalLine(
        LogLine(level: "info", source: "Steam", message: "pending-clear"),
        to: journalURL
    )
    for _ in 0..<100 {
        if monitor.pendingLineCount(containerID: containerID) > 0 {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(monitor.pendingLineCount(containerID: containerID) == 1)

    monitor.stop(containerID: containerID, deliverPending: false)
    try await Task.sleep(for: .milliseconds(1_100))
    #expect(collector.lines.isEmpty)
}

@Test func liveLogJournalMonitorDefersWorkUntilActivatedAndCatchesUp() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = LiveLogJournalStore(rootURL: root)
    let containerID = UUID()
    let journalURL = try store.prepareJournal(for: containerID, reset: true)
    try appendJournalLine(
        LogLine(level: "info", source: "Steam", message: "before-monitor"),
        to: journalURL
    )

    let collector = LiveLogJournalCollector()
    let monitor = LiveLogJournalMonitor(
        deliveryInterval: 0,
        isActive: false
    )
    try monitor.start(
        containerID: containerID,
        source: "Steam",
        journalURL: journalURL,
        replayLimit: 5_000,
        onLogs: collector.append
    )
    defer { monitor.stopAll() }

    try appendJournalLine(
        LogLine(level: "warning", source: "Steam", message: "while-inactive"),
        to: journalURL
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(collector.lines.isEmpty)

    monitor.setActive(true)
    try await waitForJournalMessages(count: 2, collector: collector)
    #expect(collector.lines.map(\.message) == ["before-monitor", "while-inactive"])

    monitor.setActive(false)
    try appendJournalLine(
        LogLine(level: "error", source: "Steam", message: "while-paused"),
        to: journalURL
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(collector.lines.count == 2)

    monitor.setActive(true)
    try await waitForJournalMessages(count: 3, collector: collector)
    #expect(collector.lines.map(\.message).last == "while-paused")
}

private func appendJournalLine(_ line: LogLine, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    var data = try JSONEncoder().encode(line)
    data.append(0x0A)
    try handle.write(contentsOf: data)
}

private func waitForJournalMessages(
    count: Int,
    collector: LiveLogJournalCollector
) async throws {
    for _ in 0..<100 {
        if collector.lines.count >= count {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(collector.lines.count >= count)
}

private final class LiveLogJournalCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogLine] = []

    var lines: [LogLine] {
        lock.withLock { storage }
    }

    func append(_ lines: [LogLine]) {
        lock.withLock {
            storage.append(contentsOf: lines)
        }
    }
}
