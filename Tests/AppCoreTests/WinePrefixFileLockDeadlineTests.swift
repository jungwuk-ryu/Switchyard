import AppCore
import Foundation
import Testing

@Suite("Wine prefix file lock deadlines")
struct WinePrefixFileLockDeadlineTests {
    @Test("A contended lock stops waiting at its deadline")
    func timesOutWhileExclusiveLockIsHeld() throws {
        try withTemporaryPrefix { prefixURL in
            let heldLock = try WinePrefixFileLock(
                prefixPath: prefixURL.path,
                mode: .exclusive
            )
            defer { heldLock.unlock() }

            let clock = ContinuousClock()
            let startedAt = clock.now
            #expect(throws: WinePrefixFileLockAcquisitionError.timedOut) {
                try WinePrefixFileLock(
                    prefixPath: prefixURL.path,
                    mode: .shared,
                    acquisitionTimeout: .milliseconds(80)
                )
            }
            let elapsed = startedAt.duration(to: clock.now)
            #expect(elapsed >= .milliseconds(60))
            #expect(elapsed < .seconds(1))
        }
    }

    @Test("Cancellation stops a contended lock wait before its deadline")
    func cancelsWhileExclusiveLockIsHeld() throws {
        try withTemporaryPrefix { prefixURL in
            let heldLock = try WinePrefixFileLock(
                prefixPath: prefixURL.path,
                mode: .exclusive
            )
            defer { heldLock.unlock() }

            #expect(throws: WinePrefixFileLockAcquisitionError.cancelled) {
                try WinePrefixFileLock(
                    prefixPath: prefixURL.path,
                    mode: .shared,
                    acquisitionTimeout: .seconds(5),
                    cancellationCheck: { true }
                )
            }
        }
    }

    @Test("A bounded lock retains normal shared-lock semantics")
    func acquiresCompatibleSharedLock() throws {
        try withTemporaryPrefix { prefixURL in
            let firstLock = try WinePrefixFileLock(
                prefixPath: prefixURL.path,
                mode: .shared
            )
            defer { firstLock.unlock() }

            let secondLock = try WinePrefixFileLock(
                prefixPath: prefixURL.path,
                mode: .shared,
                acquisitionTimeout: .milliseconds(50)
            )
            secondLock.unlock()
        }
    }

    @Test("A negative acquisition timeout is rejected")
    func rejectsNegativeTimeout() throws {
        try withTemporaryPrefix { prefixURL in
            #expect(throws: POSIXError.self) {
                try WinePrefixFileLock(
                    prefixPath: prefixURL.path,
                    mode: .shared,
                    acquisitionTimeout: .milliseconds(-1)
                )
            }
        }
    }

    private func withTemporaryPrefix(
        _ body: (URL) throws -> Void
    ) throws {
        let prefixURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "switchyard-prefix-lock-deadline-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: prefixURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: prefixURL) }
        try body(prefixURL)
    }
}
