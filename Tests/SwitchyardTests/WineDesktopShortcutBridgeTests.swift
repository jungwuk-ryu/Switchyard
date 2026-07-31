import AppCore
import Darwin
import Dispatch
import Foundation
import Testing
@testable import Switchyard

private enum DesktopShortcutBridgeTestError: Error {
    case subprocessTimedOut(String)
    case subprocessCleanupTimedOut(String, Int32)
    case invalidMachOFixture
    case injectedCommitFailure
}

private func runCodesign(arguments: [String]) throws -> Int32 {
    let process = Process()
    let completion = DispatchSemaphore(value: 0)
    let start = DispatchTime.now()
    let commandDeadline = start + .seconds(10)
    let terminationDeadline = start + .seconds(11)
    let cleanupDeadline = start + .seconds(12)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in completion.signal() }
    try process.run()

    if completion.wait(timeout: commandDeadline) == .timedOut {
        process.terminate()
        if completion.wait(timeout: terminationDeadline) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            guard completion.wait(timeout: cleanupDeadline)
                == .success else {
                throw DesktopShortcutBridgeTestError
                    .subprocessCleanupTimedOut(
                        arguments.joined(separator: " "),
                        process.processIdentifier
                    )
            }
        }
        throw DesktopShortcutBridgeTestError.subprocessTimedOut(
            arguments.joined(separator: " ")
        )
    }
    return process.terminationStatus
}

@Test func desktopShortcutSubprocessRunnerTimesOutCancelsAndReaps()
    async throws
{
    let timeoutRecorder = DesktopShortcutProcessRecorder()
    do {
        _ = try await WineDesktopShortcutSubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: .milliseconds(50),
            processStarted: timeoutRecorder.record
        )
        Issue.record("Expected subprocess timeout")
    } catch let error as WineDesktopShortcutSubprocessError {
        guard case .timedOut = error else {
            Issue.record("Unexpected subprocess error: \(error)")
            return
        }
    }
    let timedOutProcessID = try #require(timeoutRecorder.processID)
    #expect(processWasReaped(timedOutProcessID))

    let cancellationRecorder = DesktopShortcutProcessRecorder()
    let pending = Task {
        try await WineDesktopShortcutSubprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: .seconds(30),
            processStarted: cancellationRecorder.record
        )
    }
    for _ in 0..<1_000 where cancellationRecorder.processID == nil {
        try await Task.sleep(for: .milliseconds(1))
    }
    let cancelledProcessID = try #require(
        cancellationRecorder.processID
    )
    pending.cancel()
    do {
        _ = try await pending.value
        Issue.record("Expected subprocess cancellation")
    } catch is CancellationError {
        // Expected.
    }
    #expect(processWasReaped(cancelledProcessID))
}

@Test func desktopShortcutSignaturePreflightRejectsOversizedAndWideTrees()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(
            "switchyard-signature-preflight-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? fileManager.removeItem(at: root) }
    let bundle = root.appendingPathComponent(
        "Unsafe.app",
        isDirectory: true
    )
    let contents = bundle.appendingPathComponent(
        "Contents",
        isDirectory: true
    )
    let macOS = contents.appendingPathComponent(
        "MacOS",
        isDirectory: true
    )
    let resources = contents.appendingPathComponent(
        "Resources",
        isDirectory: true
    )
    let signature = contents.appendingPathComponent(
        "_CodeSignature",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: macOS,
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: resources,
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: signature,
        withIntermediateDirectories: true
    )
    try Data("plist".utf8).write(
        to: contents.appendingPathComponent("Info.plist")
    )
    let helper = macOS.appendingPathComponent(
        "switchyard-shortcut-handler"
    )
    try Data([0]).write(to: helper)
    let helperHandle = try FileHandle(forWritingTo: helper)
    try helperHandle.truncate(
        atOffset: UInt64(64 * 1_024 * 1_024 + 1)
    )
    try helperHandle.close()
    let codeResources = signature.appendingPathComponent(
        "CodeResources"
    )
    try Data([0]).write(to: codeResources)

    let cache = WineDesktopShortcutBundleSignatureCache()
    #expect(try await cache.analysis(at: bundle) == nil)
    #expect(
        await cache.analysisExecutionCountForTesting() == 0
    )

    let shrinkHelper = try FileHandle(forWritingTo: helper)
    try shrinkHelper.truncate(atOffset: 1)
    try shrinkHelper.close()
    let resourcesHandle = try FileHandle(
        forWritingTo: codeResources
    )
    try resourcesHandle.truncate(
        atOffset: UInt64(4 * 1_024 * 1_024 + 1)
    )
    try resourcesHandle.close()
    #expect(try await cache.analysis(at: bundle) == nil)
    #expect(
        await cache.analysisExecutionCountForTesting() == 0
    )

    let shrinkResources = try FileHandle(
        forWritingTo: codeResources
    )
    try shrinkResources.truncate(atOffset: 1)
    try shrinkResources.close()
    try Data("sidecar".utf8).write(
        to: bundle.appendingPathComponent("extra")
    )
    #expect(try await cache.analysis(at: bundle) == nil)
    #expect(
        await cache.analysisExecutionCountForTesting() == 0
    )

    try fileManager.removeItem(
        at: bundle.appendingPathComponent("extra")
    )
    let analysisRecorder =
        DesktopShortcutSignatureAnalysisRecorder()
    let coalescingCache =
        WineDesktopShortcutBundleSignatureCache(
            analyzer: {
                analysisRecorder.record()
                Thread.sleep(forTimeInterval: 0.05)
                return $1
            }
        )
    async let firstAnalysis =
        coalescingCache.analysis(at: bundle)
    async let secondAnalysis =
        coalescingCache.analysis(at: bundle)
    let (firstSnapshot, secondSnapshot) =
        try await (firstAnalysis, secondAnalysis)
    #expect(firstSnapshot != nil)
    #expect(firstSnapshot == secondSnapshot)
    #expect(analysisRecorder.executionCount == 1)
    #expect(analysisRecorder.ranOffMainThread)
    #expect(
        await coalescingCache
            .analysisExecutionCountForTesting() == 1
    )
}

@Test func desktopShortcutIconRendererRejectsDecodedImageBombBudgets() {
    #expect(
        WineDesktopShortcutIconRenderer
            .decodedImageBudgetIsSafe(
                width: 4_096,
                height: 4_096,
                frameCount: 1
            )
    )
    #expect(
        !WineDesktopShortcutIconRenderer
            .decodedImageBudgetIsSafe(
                width: 100_000,
                height: 100_000,
                frameCount: 1
            )
    )
    #expect(
        !WineDesktopShortcutIconRenderer
            .decodedImageBudgetIsSafe(
                width: 1,
                height: 1,
                frameCount: 257
            )
    )
    #expect(
        !WineDesktopShortcutIconRenderer
            .decodedImageBudgetIsSafe(
                width: Int.max,
                height: Int.max,
                frameCount: 1
            )
    )
}

@Test func desktopShortcutTransactionJournalKeepsMaxTreeIdentitiesBounded()
    throws
{
    let backups = (0..<16).map { index in
        DesktopShortcutTransactionJournalFixture.Backup(
            originalName: "Original-\(index).app",
            backupName: "backup-\(index)",
            originalIdentity:
                desktopShortcutStableIdentityFixture(
                    inode: UInt64(index + 1)
                )
        )
    }
    let targets = (0..<16).map { index in
        DesktopShortcutTransactionJournalFixture.Target(
            bundleName: "Target-\(index).app",
            shortcutID:
                String(repeating: "0", count: 56)
                + String(format: "%08x", index),
            stableIdentity:
                desktopShortcutStableIdentityFixture(
                    inode: UInt64(index + 10_000)
                )
        )
    }
    let journal = DesktopShortcutTransactionJournalFixture(
        state: "rolledBack",
        transactionID: UUID().uuidString,
        backups: backups,
        targets: targets,
        previousRouteData: Data(
            repeating: 0x41,
            count:
                WineDesktopShortcutPersistenceLimits
                    .maximumRouteIndexByteCount
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(journal)
    #expect(
        encoded.count
            < WineDesktopShortcutPersistenceLimits
                .maximumTransactionJournalByteCount
    )
    #expect(
        try encoder.encode(
            desktopShortcutStableIdentityFixture(inode: 1)
        ).count < 512
    )
}

@MainActor
@Test func desktopShortcutStableIdentityUsesOffMainAggregateBudget()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(
            "switchyard-identity-budget-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? fileManager.removeItem(at: root) }
    let desktop = root.appendingPathComponent(
        "Desktop",
        isDirectory: true
    )
    let bridgeRoot = root.appendingPathComponent(
        "Bridge",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: desktop,
        withIntermediateDirectories: true
    )
    let managedCount =
        WineDesktopShortcutPersistenceLimits
            .maximumTransactionTreeEntryCount
        / WineDesktopShortcutPersistenceLimits
            .maximumBundleTreeEntryCount
        + 1
    for index in 0..<managedCount {
        let shortcutID =
            String(repeating: "0", count: 56)
            + String(format: "%08x", index)
        let contents = desktop.appendingPathComponent(
            "Managed-\(index).app/Contents",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: contents,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier":
                "dev.switchyard.desktop-shortcut."
                + String(shortcutID.prefix(24)),
            "SwitchyardDesktopShortcutID": shortcutID,
            "SwitchyardDesktopShortcutOwner":
                "dev.switchyard",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .binary,
            options: 0
        ).write(
            to: contents.appendingPathComponent(
                "Info.plist"
            )
        )
    }
    let wine = root.appendingPathComponent("wine")
    let runner = root.appendingPathComponent("runner")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: runner.path
    )

    let recorder =
        DesktopShortcutStableIdentityAnalysisRecorder()
    let bridge = WineDesktopShortcutBridge(
        fileManager: fileManager,
        rootURL: bridgeRoot,
        desktopURL: desktop,
        stableIdentityAnalyzer: recorder.analyze
    )
    do {
        _ = try await bridge.refresh(
            containers: [],
            winePath: wine.path,
            runnerPath: runner.path
        )
        Issue.record("Expected aggregate identity limit")
    } catch let error as POSIXError {
        #expect(error.code == .EFBIG)
    }
    #expect(
        recorder.executionCount
            == WineDesktopShortcutPersistenceLimits
                .maximumTransactionTreeEntryCount
            / WineDesktopShortcutPersistenceLimits
                .maximumBundleTreeEntryCount
    )
    #expect(recorder.ranOffMainThread)
    #expect(
        fileManager.fileExists(
            atPath: desktop.appendingPathComponent(
                "Managed-0.app",
                isDirectory: true
            ).path
        )
    )
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )
}

@MainActor
@Test func desktopShortcutStableIdentityPreflightRejectsStaleRefresh()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent(
            "switchyard-identity-stale-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? fileManager.removeItem(at: root) }
    let desktop = root.appendingPathComponent(
        "Desktop",
        isDirectory: true
    )
    let bridgeRoot = root.appendingPathComponent(
        "Bridge",
        isDirectory: true
    )
    let managedBundle = desktop.appendingPathComponent(
        "Managed.app",
        isDirectory: true
    )
    let contents = managedBundle.appendingPathComponent(
        "Contents",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: contents,
        withIntermediateDirectories: true
    )
    let shortcutID = String(repeating: "1", count: 64)
    let info: [String: Any] = [
        "CFBundleIdentifier":
            "dev.switchyard.desktop-shortcut."
            + String(shortcutID.prefix(24)),
        "SwitchyardDesktopShortcutID": shortcutID,
        "SwitchyardDesktopShortcutOwner": "dev.switchyard",
    ]
    try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .binary,
        options: 0
    ).write(
        to: contents.appendingPathComponent("Info.plist")
    )
    let wine = root.appendingPathComponent("wine")
    let runner = root.appendingPathComponent("runner")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: runner.path
    )

    let analyzer =
        DesktopShortcutSuspendingStableIdentityAnalyzer()
    let bridge = WineDesktopShortcutBridge(
        fileManager: fileManager,
        rootURL: bridgeRoot,
        desktopURL: desktop,
        stableIdentityAnalyzer: analyzer.analyze
    )
    let prepared = try bridge.prepareRefresh(
        containers: [],
        winePath: wine.path,
        runnerPath: runner.path
    )
    let refreshTask = Task {
        try await bridge.refresh(
            prepared,
            fileDigests: [:]
        )
    }
    let analysisStarted = await analyzer.waitUntilStarted()
    defer { analyzer.resume() }
    #expect(analysisStarted)
    guard analysisStarted else {
        refreshTask.cancel()
        _ = try? await refreshTask.value
        return
    }
    try Data("#!/bin/sh\n# changed\nexit 0\n".utf8)
        .write(to: wine)
    analyzer.resume()

    do {
        _ = try await refreshTask.value
        Issue.record("Expected stale refresh cancellation")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Unexpected refresh error: \(error)")
    }
    #expect(fileManager.fileExists(atPath: managedBundle.path))
    #expect(
        !fileManager.fileExists(
            atPath: bridgeRoot.appendingPathComponent(
                "routes-v1.json"
            ).path
        )
    )
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )

    let freshPrepared = try bridge.prepareRefresh(
        containers: [],
        winePath: wine.path,
        runnerPath: runner.path
    )
    var currentnessCallCount = 0
    _ = try await bridge.refresh(
        freshPrepared,
        fileDigests: [:],
        isStillCurrent: {
            currentnessCallCount += 1
            return true
        }
    )
    #expect(currentnessCallCount == 2)
    #expect(!fileManager.fileExists(atPath: managedBundle.path))
}

@MainActor
@Test func desktopShortcutTransactionRecoveryRejectsUnsafeJournals()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "switchyard-transaction-recovery-\(UUID().uuidString)",
        isDirectory: true
    )
    let desktop = root.appendingPathComponent(
        "Desktop",
        isDirectory: true
    )
    let bridgeRoot = root.appendingPathComponent(
        "Bridge",
        isDirectory: true
    )
    let wine = root.appendingPathComponent("wine")
    let runner = root.appendingPathComponent("runner")
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
        at: desktop,
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: runner.path
    )
    let bridge = WineDesktopShortcutBridge(
        fileManager: fileManager,
        rootURL: bridgeRoot,
        desktopURL: desktop
    )
    let prepared = try bridge.prepareRefresh(
        containers: [],
        winePath: wine.path,
        runnerPath: runner.path
    )
    try fileManager.createDirectory(
        at: bridgeRoot,
        withIntermediateDirectories: true
    )
    #expect(
        Darwin.chmod(
            bridgeRoot.path,
            mode_t(S_IRWXU)
        ) == 0
    )
    let staleRouteTemporaryURL = bridgeRoot
        .appendingPathComponent(".routes-v1.json.tmp")
    try Data("interrupted route write".utf8).write(
        to: staleRouteTemporaryURL
    )

    let duplicateID = UUID().uuidString
    let duplicateTransaction = desktop.appendingPathComponent(
        ".switchyard-shortcut-transaction-\(duplicateID)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: duplicateTransaction,
        withIntermediateDirectories: false
    )
    #expect(
        Darwin.chmod(
            duplicateTransaction.path,
            mode_t(S_IRWXU)
        ) == 0
    )
    let duplicateJournal =
        DesktopShortcutTransactionJournalFixture(
            state: "preparing",
            transactionID: duplicateID,
            backups: [
                .init(
                    originalName: "Same.app",
                    backupName: "backup-0",
                    originalIdentity:
                        desktopShortcutStableIdentityFixture(
                            inode: 1
                        )
                ),
                .init(
                    originalName: "Same.app",
                    backupName: "backup-1",
                    originalIdentity:
                        desktopShortcutStableIdentityFixture(
                            inode: 2
                        )
                )
            ],
            targets: [],
            previousRouteData: nil
        )
    try JSONEncoder().encode(duplicateJournal).write(
        to: duplicateTransaction.appendingPathComponent(
            "journal-v1.json"
        ),
        options: .atomic
    )
    _ = try await bridge.refresh(
        prepared,
        fileDigests: [:]
    )
    #expect(
        !fileManager.fileExists(
            atPath: staleRouteTemporaryURL.path
        )
    )
    #expect(
        fileManager.fileExists(
            atPath: duplicateTransaction.path
        )
    )
    try fileManager.removeItem(at: duplicateTransaction)

    let protectedBundle = desktop.appendingPathComponent(
        "Protected.app",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: protectedBundle,
        withIntermediateDirectories: false
    )
    try Data("user data".utf8).write(
        to: protectedBundle.appendingPathComponent("keep")
    )
    let substitutionID = UUID().uuidString
    let substitutionTransaction =
        desktop.appendingPathComponent(
            ".switchyard-shortcut-transaction-\(substitutionID)",
            isDirectory: true
        )
    try fileManager.createDirectory(
        at: substitutionTransaction,
        withIntermediateDirectories: false
    )
    #expect(
        Darwin.chmod(
            substitutionTransaction.path,
            mode_t(S_IRWXU)
        ) == 0
    )
    let substitutionJournal =
        DesktopShortcutTransactionJournalFixture(
            state: "preparing",
            transactionID: substitutionID,
            backups: [],
            targets: [
                .init(
                    bundleName:
                        protectedBundle.lastPathComponent,
                    shortcutID: String(repeating: "a", count: 64),
                    stableIdentity:
                        desktopShortcutStableIdentityFixture(
                            inode: UInt64.max
                        )
                )
            ],
            previousRouteData: nil
        )
    try JSONEncoder().encode(substitutionJournal).write(
        to: substitutionTransaction.appendingPathComponent(
            "journal-v1.json"
        ),
        options: .atomic
    )
    do {
        _ = try await bridge.refresh(
            prepared,
            fileDigests: [:]
        )
        Issue.record("Expected ambiguous recovery failure")
    } catch {
        #expect(error is POSIXError)
    }
    #expect(
        fileManager.fileExists(atPath: protectedBundle.path)
    )
}

@Test func desktopShortcutHelperIdentityReaderRejectsUnsafeFiles()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "switchyard-helper-identity-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    let regular = root.appendingPathComponent("regular")
    try fileManager.copyItem(
        at: URL(fileURLWithPath: "/bin/echo"),
        to: regular
    )
    let identity = try #require(
        WineDesktopShortcutHelperIdentityReader.identity(at: regular)
    )
    #expect(identity.byteCount > 0)
    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: regular
        ) == identity
    )

    let symbolicLink = root.appendingPathComponent("symbolic-link")
    try fileManager.createSymbolicLink(
        at: symbolicLink,
        withDestinationURL: regular
    )
    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: symbolicLink
        ) == nil
    )

    let oversized = root.appendingPathComponent("oversized")
    try fileManager.copyItem(
        at: URL(fileURLWithPath: "/bin/echo"),
        to: oversized
    )
    let oversizedHandle = try FileHandle(forWritingTo: oversized)
    try oversizedHandle.truncate(
        atOffset:
            WineDesktopShortcutHelperIdentityReader.maximumByteCount + 1
    )
    try oversizedHandle.close()
    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: oversized
        ) == nil
    )
}

@Test func desktopShortcutHelperIdentityRejectsLoaderSemanticMutations()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "switchyard-helper-macho-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let source = URL(fileURLWithPath: "/bin/echo")
    let expected = try #require(
        WineDesktopShortcutHelperIdentityReader.analysis(at: source)
    )

    for mutation in TestMachOMutation.allCases {
        var data = try Data(contentsOf: source)
        try mutateFirstMachOSlice(&data, mutation: mutation)
        let mutated = root.appendingPathComponent(
            mutation.rawValue
        )
        try data.write(to: mutated)
        if mutation == .codeSignatureDataOffset {
            #expect(
                WineDesktopShortcutHelperIdentityReader.analysis(
                    at: mutated,
                    matching: expected.profile
                )?.identity == nil,
                "Expected \(mutation.rawValue) profile mismatch"
            )
        } else {
            #expect(
                WineDesktopShortcutHelperIdentityReader.identity(
                    at: mutated
                ) == nil,
                "Expected \(mutation.rawValue) to be rejected"
            )
        }
    }

    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: source
        ) == expected.identity
    )
}

@Test func desktopShortcutHelperIdentityRejectsUnsafeFatMetadata()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "switchyard-helper-fat-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    let source = try Data(
        contentsOf: URL(fileURLWithPath: "/bin/echo")
    )
    guard Array(source.prefix(4)) == [0xca, 0xfe, 0xba, 0xbe] else {
        throw DesktopShortcutBridgeTestError.invalidMachOFixture
    }
    let cpuType = try testMachOUInt32(
        source,
        offset: 8,
        byteOrder: .bigEndian
    )
    let cpuSubtype = try testMachOUInt32(
        source,
        offset: 12,
        byteOrder: .bigEndian
    )
    let sourceOffset = Int(
        try testMachOUInt32(
            source,
            offset: 16,
            byteOrder: .bigEndian
        )
    )
    let sourceSize = Int(
        try testMachOUInt32(
            source,
            offset: 20,
            byteOrder: .bigEndian
        )
    )
    guard sourceOffset >= 0,
          sourceSize > 0,
          sourceOffset <= source.count - sourceSize else {
        throw DesktopShortcutBridgeTestError.invalidMachOFixture
    }
    let thinData = source.subdata(
        in: sourceOffset..<(sourceOffset + sourceSize)
    )
    let thinURL = root.appendingPathComponent("thin")
    try thinData.write(to: thinURL)
    let expectedIdentity = try #require(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: thinURL
        )
    )

    let fatSliceOffset = 4 * 1_024
    var fat64 = Data(
        repeating: 0,
        count: fatSliceOffset + thinData.count
    )
    testMachOWriteUInt32(
        0xca_fe_ba_bf,
        to: &fat64,
        offset: 0,
        byteOrder: .bigEndian
    )
    testMachOWriteUInt32(
        1,
        to: &fat64,
        offset: 4,
        byteOrder: .bigEndian
    )
    testMachOWriteUInt32(
        cpuType,
        to: &fat64,
        offset: 8,
        byteOrder: .bigEndian
    )
    testMachOWriteUInt32(
        cpuSubtype,
        to: &fat64,
        offset: 12,
        byteOrder: .bigEndian
    )
    testMachOWriteUInt64(
        UInt64(fatSliceOffset),
        to: &fat64,
        offset: 16,
        byteOrder: .bigEndian
    )
    testMachOWriteUInt64(
        UInt64(thinData.count),
        to: &fat64,
        offset: 24,
        byteOrder: .bigEndian
    )
    testMachOWriteUInt32(
        12,
        to: &fat64,
        offset: 32,
        byteOrder: .bigEndian
    )
    fat64.replaceSubrange(
        fatSliceOffset..<(fatSliceOffset + thinData.count),
        with: thinData
    )
    let validFatURL = root.appendingPathComponent("valid-fat64")
    try fat64.write(to: validFatURL)
    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: validFatURL
        ) == expectedIdentity
    )

    var overlappingTable = fat64
    testMachOWriteUInt64(
        32,
        to: &overlappingTable,
        offset: 16,
        byteOrder: .bigEndian
    )
    let overlappingURL = root.appendingPathComponent(
        "overlapping-table"
    )
    try overlappingTable.write(to: overlappingURL)
    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: overlappingURL
        ) == nil
    )

    var misaligned = fat64
    testMachOWriteUInt32(
        13,
        to: &misaligned,
        offset: 32,
        byteOrder: .bigEndian
    )
    let misalignedURL = root.appendingPathComponent("misaligned")
    try misaligned.write(to: misalignedURL)
    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: misalignedURL
        ) == nil
    )

    var reserved = fat64
    testMachOWriteUInt32(
        1,
        to: &reserved,
        offset: 36,
        byteOrder: .bigEndian
    )
    let reservedURL = root.appendingPathComponent("reserved")
    try reserved.write(to: reservedURL)
    #expect(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: reservedURL
        ) == nil
    )
}

@Test func desktopShortcutHelperIdentityCacheCoalescesOffMainAndInvalidates()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "switchyard-helper-cache-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let helper = root.appendingPathComponent("helper")
    try fileManager.copyItem(
        at: URL(fileURLWithPath: "/bin/echo"),
        to: helper
    )
    let expected = try #require(
        WineDesktopShortcutHelperIdentityReader.analysis(at: helper)
    )
    let threadRecorder = DesktopShortcutThreadRecorder()
    let cache = WineDesktopShortcutHelperIdentityCache {
        url,
        profile in
        threadRecorder.record(isMainThread: Thread.isMainThread)
        Darwin.usleep(50_000)
        return WineDesktopShortcutHelperIdentityReader.analysis(
            at: url,
            matching: profile
        )
    }

    let identities = await withTaskGroup(
        of: WineDesktopShortcutHelperIdentity?.self,
        returning: [WineDesktopShortcutHelperIdentity?].self
    ) { group in
        for _ in 0..<32 {
            group.addTask {
                try? await cache.analysis(
                    at: helper,
                    matching: expected.profile
                )?.identity
            }
        }
        var values: [WineDesktopShortcutHelperIdentity?] = []
        for await value in group {
            values.append(value)
        }
        return values
    }

    #expect(identities.count == 32)
    #expect(identities.allSatisfy { $0 == expected.identity })
    #expect(await cache.analysisExecutionCountForTesting() == 1)
    #expect(!threadRecorder.observedMainThread)

    var mismatchedSlices = expected.profile.slices
    let firstSlice = try #require(mismatchedSlices.first)
    mismatchedSlices[0] = WineDesktopShortcutHelperSliceProfile(
        cpuType: firstSlice.cpuType,
        cpuSubtype: firstSlice.cpuSubtype,
        canonicalByteCount: firstSlice.canonicalByteCount + 1
    )
    let mismatchedProfile = WineDesktopShortcutHelperProfile(
        slices: mismatchedSlices
    )
    let mismatchedAnalysis = try await cache.analysis(
        at: helper,
        matching: mismatchedProfile
    )
    #expect(mismatchedAnalysis?.identity == nil)
    #expect(await cache.analysisExecutionCountForTesting() == 1)

    try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        .write(to: helper, options: .atomic)
    _ = try await cache.analysis(at: helper)
    #expect(await cache.analysisExecutionCountForTesting() == 2)

    let resetCache = WineDesktopShortcutHelperIdentityCache {
        url,
        profile in
        Darwin.usleep(50_000)
        return WineDesktopShortcutHelperIdentityReader.analysis(
            at: url,
            matching: profile
        )
    }
    let pending = Task {
        try await resetCache.analysis(at: helper)
    }
    try await Task.sleep(for: .milliseconds(10))
    await resetCache.removeAll()
    let staleAnalysis = try await pending.value
    #expect(staleAnalysis?.identity == nil)
    _ = try await resetCache.analysis(at: helper)
    #expect(
        await resetCache.analysisExecutionCountForTesting() == 2
    )

    let cancellationRecorder =
        DesktopShortcutAnalysisCancellationRecorder()
    let cancellationCache =
        WineDesktopShortcutHelperIdentityCache {
            _,
            _ in
            cancellationRecorder.recordStarted()
            while !Task.isCancelled {
                Darwin.usleep(1_000)
            }
            cancellationRecorder.recordCancelled()
            return nil
        }
    let cancelledAnalysis = Task {
        try await cancellationCache.analysis(at: helper)
    }
    for _ in 0..<1_000 where !cancellationRecorder.didStart {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(cancellationRecorder.didStart)
    cancelledAnalysis.cancel()
    do {
        _ = try await cancelledAnalysis.value
        Issue.record("Expected helper analysis cancellation")
    } catch is CancellationError {
        // Expected.
    }
    for _ in 0..<1_000
    where !cancellationRecorder.didObserveCancellation {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(cancellationRecorder.didObserveCancellation)
    #expect(
        await cancellationCache.inFlightCountForTesting() == 0
    )
}

@MainActor
@Test func desktopShortcutBridgeMaterializesReusesAndRemovesOwnedBundles()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("switchyard-desktop-bridge-\(UUID().uuidString)", isDirectory: true)
    let prefix = root.appendingPathComponent("Test.container", isDirectory: true)
    let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
    let bridgeRoot = root.appendingPathComponent("Bridge", isDirectory: true)
    let wine = root.appendingPathComponent("wine")
    let runner = root.appendingPathComponent("switchyard-runner")
    let wineDesktop = prefix.appendingPathComponent(
        "drive_c/users/steamuser/Desktop",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    try fileManager.createDirectory(at: wineDesktop, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runner)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)

    let source = wineDesktop.appendingPathComponent("Heartopia.url")
    try Data("[InternetShortcut]\nURL=xdt://launch\n".utf8).write(to: source)
    let manifestURL = WineDesktopShortcutFormat.manifestURL(prefixPath: prefix.path)
    try fileManager.createDirectory(
        at: manifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
    let windowsPath = #"C:\users\steamuser\Desktop\Heartopia.url"#
    let manifest = """
    \(WineDesktopShortcutFormat.manifestHeader)
    url\t\(hex("Heartopia"))\t\(hex(windowsPath))\t
    """
    try Data(manifest.utf8).write(to: manifestURL)

    let unownedCollision = desktop.appendingPathComponent("Heartopia.app", isDirectory: true)
    try fileManager.createDirectory(at: unownedCollision, withIntermediateDirectories: false)
    let fifoBundle = desktop.appendingPathComponent(
        "Blocked Info.app",
        isDirectory: true
    )
    let fifoContents = fifoBundle.appendingPathComponent(
        "Contents",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: fifoContents,
        withIntermediateDirectories: true
    )
    #expect(
        Darwin.mkfifo(
            fifoContents.appendingPathComponent(
                "Info.plist"
            ).path,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0
    )
    let oversizedInfoBundle = desktop.appendingPathComponent(
        "Oversized Info.app",
        isDirectory: true
    )
    let oversizedInfoContents =
        oversizedInfoBundle.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
    try fileManager.createDirectory(
        at: oversizedInfoContents,
        withIntermediateDirectories: true
    )
    try Data(count: 64 * 1_024 + 1).write(
        to: oversizedInfoContents.appendingPathComponent(
            "Info.plist"
        )
    )
    let container = Container(
        name: "Test Container",
        path: prefix.path,
        environmentOverrides: [
            RosettaAVXAdvertisingPolicy.environmentKey: "0"
        ]
    )
    let commitFault = DesktopShortcutCommitFaultInjector()
    let bundleSignatureCache =
        WineDesktopShortcutBundleSignatureCache()
    let bridge = WineDesktopShortcutBridge(
        fileManager: fileManager,
        rootURL: bridgeRoot,
        desktopURL: desktop,
        bundleSignatureCache: bundleSignatureCache,
        commitCheckpoint: commitFault.checkpoint
    )

    let stalePrepared = try bridge.prepareRefresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    do {
        _ = try await bridge.refresh(
            stalePrepared,
            fileDigests: [:],
            isStillCurrent: { false }
        )
        Issue.record("Expected stale shortcut refresh cancellation")
    } catch is CancellationError {
        // Expected: identity work may finish, but no route or bundle commits.
    }
    #expect(
        !fileManager.fileExists(
            atPath: bridgeRoot
                .appendingPathComponent("routes-v1.json").path
        )
    )
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(".switchyard-shortcut-")
            }
    )

    let appearedSource = wineDesktop.appendingPathComponent(
        "Appeared.url"
    )
    let missingSourceMetadata = ContainerBridgeIndexMetadata(
        dependencies: [
            ContainerBridgeDependencyMetadata(
                role: .desktopShortcutManifest,
                path: manifestURL.path,
                fileStamp: WineBridgeFileStamp.read(
                    from: manifestURL
                )
            ),
            ContainerBridgeDependencyMetadata(
                role: .desktopShortcut,
                path: appearedSource.path,
                fileStamp: WineBridgeFileStamp.read(
                    from: appearedSource
                )
            )
        ]
    )
    try Data("[InternetShortcut]\nURL=appeared\n".utf8)
        .write(to: appearedSource)
    let missingSourcePrepared = try bridge.prepareRefresh(
        containers: [container],
        indexedMetadataByContainerID: [
            container.id: missingSourceMetadata
        ],
        winePath: wine.path,
        runnerPath: runner.path
    )
    do {
        _ = try await bridge.refresh(
            missingSourcePrepared,
            fileDigests: [:]
        )
        Issue.record("Expected appeared source cancellation")
    } catch is CancellationError {
        // Scan-time missing dependencies are part of currentness.
    }
    #expect(
        !fileManager.fileExists(
            atPath: bridgeRoot
                .appendingPathComponent("routes-v1.json").path
        )
    )
    try fileManager.removeItem(at: appearedSource)

    let appearedIcon = wineDesktop.appendingPathComponent(
        "Appeared.ico"
    )
    let missingIconMetadata = ContainerBridgeIndexMetadata(
        desktopShortcutEntries: [
            WineDesktopShortcutManifestEntry(
                kind: .url,
                displayName: "Heartopia",
                windowsShortcutPath: windowsPath
            )
        ],
        dependencies: [
            ContainerBridgeDependencyMetadata(
                role: .desktopShortcutManifest,
                path: manifestURL.path,
                fileStamp: WineBridgeFileStamp.read(
                    from: manifestURL
                )
            ),
            ContainerBridgeDependencyMetadata(
                role: .desktopShortcut,
                path: source.path,
                fileStamp: WineBridgeFileStamp.read(
                    from: source
                )
            ),
            ContainerBridgeDependencyMetadata(
                role: .desktopShortcutIcon,
                path: appearedIcon.path,
                fileStamp: WineBridgeFileStamp.read(
                    from: appearedIcon
                )
            )
        ]
    )
    try Data("appeared icon".utf8).write(to: appearedIcon)
    let missingIconPrepared = try bridge.prepareRefresh(
        containers: [container],
        indexedMetadataByContainerID: [
            container.id: missingIconMetadata
        ],
        winePath: wine.path,
        runnerPath: runner.path
    )
    do {
        _ = try await bridge.refresh(
            missingIconPrepared,
            fileDigests: [:]
        )
        Issue.record("Expected appeared icon cancellation")
    } catch is CancellationError {
        // A fallback icon snapshot cannot commit after the icon appears.
    }
    #expect(
        !fileManager.fileExists(
            atPath: bridgeRoot
                .appendingPathComponent("routes-v1.json").path
        )
    )
    try fileManager.removeItem(at: appearedIcon)

    let scannedManifestStamp = WineBridgeFileStamp.read(
        from: manifestURL
    )
    let staleIndexedMetadata = ContainerBridgeIndexMetadata(
        desktopShortcutEntries: [
            WineDesktopShortcutManifestEntry(
                kind: .url,
                displayName: "Heartopia",
                windowsShortcutPath: windowsPath
            )
        ],
        dependencies: [
            ContainerBridgeDependencyMetadata(
                role: .desktopShortcutManifest,
                path: manifestURL.path,
                fileStamp: scannedManifestStamp
            ),
            ContainerBridgeDependencyMetadata(
                role: .desktopShortcut,
                path: source.path,
                fileStamp: WineBridgeFileStamp.read(
                    from: source
                )
            )
        ]
    )
    try Data((manifest + "\n").utf8).write(
        to: manifestURL,
        options: .atomic
    )
    let dependencyStalePrepared = try bridge.prepareRefresh(
        containers: [container],
        indexedMetadataByContainerID: [
            container.id: staleIndexedMetadata
        ],
        winePath: wine.path,
        runnerPath: runner.path
    )
    do {
        _ = try await bridge.refresh(
            dependencyStalePrepared,
            fileDigests: [:]
        )
        Issue.record(
            "Expected changed dependency refresh cancellation"
        )
    } catch is CancellationError {
        // The prepared manifest changed before commit.
    }
    #expect(
        !fileManager.fileExists(
            atPath: bridgeRoot
                .appendingPathComponent("routes-v1.json").path
        )
    )
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(".switchyard-shortcut-")
            }
    )
    try Data(manifest.utf8).write(
        to: manifestURL,
        options: .atomic
    )

    let first = try await bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(first.createdShortcutNames == ["Heartopia"])
    let bundle = desktop.appendingPathComponent(
        "Heartopia — Test Container.app",
        isDirectory: true
    )
    #expect(fileManager.fileExists(atPath: bundle.path))
    #expect(fileManager.fileExists(atPath: unownedCollision.path))
    let info = try #require(Bundle(url: bundle)?.infoDictionary)
    let shortcutID = try #require(info["SwitchyardDesktopShortcutID"] as? String)
    #expect(info["SwitchyardDesktopShortcutOwner"] as? String == "dev.switchyard")
    #expect(info["CFBundleIconFile"] as? String == "Shortcut.icns")
    #expect(shortcutID.count == 64)
    #expect(
        fileManager.fileExists(
            atPath: bundle.appendingPathComponent("Contents/Resources/Shortcut.icns").path
        )
    )
    #expect(
        try runCodesign(
            arguments: ["--verify", "--strict", bundle.path]
        ) == 0
    )

    let routesData = try Data(contentsOf: bridgeRoot.appendingPathComponent("routes-v1.json"))
    let routes = try JSONDecoder().decode(WineDesktopShortcutRouteIndex.self, from: routesData)
    #expect(routes.route(forID: shortcutID)?.windowsShortcutPath == windowsPath)
    #expect(
        routes.route(forID: shortcutID)?.rosettaAVXAdvertisingPreference
            == .disabled
    )

    let second = try await bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(second.createdShortcutNames.isEmpty)
    #expect(second.removedShortcutNames.isEmpty)
    let signatureAnalysisCount =
        await bundleSignatureCache
            .analysisExecutionCountForTesting()
    let routesStampBeforeNoOp =
        WineBridgeFileStamp.read(
            from: bridgeRoot.appendingPathComponent(
                "routes-v1.json"
            )
        )
    commitFault.failBeforeNextCleanup()
    let noOp = try await bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(noOp.createdShortcutNames.isEmpty)
    #expect(noOp.removedShortcutNames.isEmpty)
    #expect(commitFault.hasPendingFault)
    #expect(
        await bundleSignatureCache
            .analysisExecutionCountForTesting()
            == signatureAnalysisCount
    )
    #expect(
        WineBridgeFileStamp.read(
            from: bridgeRoot.appendingPathComponent(
                "routes-v1.json"
            )
        ) == routesStampBeforeNoOp
    )
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )
    commitFault.disable()

    let crashRecoveryPrepared = try bridge.prepareRefresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    let crashTransactionID = UUID().uuidString
    let crashTransaction = desktop.appendingPathComponent(
        ".switchyard-shortcut-transaction-\(crashTransactionID)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: crashTransaction,
        withIntermediateDirectories: false
    )
    #expect(
        Darwin.chmod(
            crashTransaction.path,
            mode_t(S_IRWXU)
        ) == 0
    )
    let crashBackup = crashTransaction.appendingPathComponent(
        "backup-0",
        isDirectory: true
    )
    let crashTargetSnapshot =
        try #require(
            WineDesktopShortcutBundleSignatureVerifier
                .stableIdentity(
                    at: bundle
                )
        )
    let crashOriginalIdentity =
        try #require(
            WineDesktopShortcutBundleSignatureVerifier.stableIdentity(
            at: bundle
        )
        )
    try fileManager.moveItem(at: bundle, to: crashBackup)
    let crashJournal = DesktopShortcutTransactionJournalFixture(
        state: "preparing",
        transactionID: crashTransactionID,
        backups: [
            .init(
                originalName: bundle.lastPathComponent,
                backupName: crashBackup.lastPathComponent,
                originalIdentity: crashOriginalIdentity
            )
        ],
        targets: [
            .init(
                bundleName: bundle.lastPathComponent,
                shortcutID: shortcutID,
                stableIdentity: crashTargetSnapshot
            )
        ],
        previousRouteData: routesData
    )
    let crashJournalURL = crashTransaction
        .appendingPathComponent("journal-v1.json")
    try JSONEncoder().encode(crashJournal).write(
        to: crashJournalURL,
        options: .atomic
    )
    try Data("interrupted journal write".utf8).write(
        to: crashTransaction.appendingPathComponent(
            "journal-v1.json.tmp"
        )
    )
    let crashRouteTemporaryURL = bridgeRoot
        .appendingPathComponent(".routes-v1.json.tmp")
    try Data("interrupted route write".utf8).write(
        to: crashRouteTemporaryURL
    )
    #expect(
        Darwin.chmod(
            crashJournalURL.path,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: wine.path
    )
    do {
        _ = try await bridge.refresh(
            crashRecoveryPrepared,
            fileDigests: [:]
        )
    } catch {
        try? fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wine.path
        )
        throw error
    }
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    #expect(
        !fileManager.fileExists(
            atPath: crashRouteTemporaryURL.path
        )
    )
    #expect(fileManager.fileExists(atPath: bundle.path))
    #expect(!fileManager.fileExists(atPath: crashTransaction.path))
    #expect(
        try Data(
            contentsOf: bridgeRoot.appendingPathComponent(
                "routes-v1.json"
            )
        ) == routesData
    )

    let restoredIdentity = try #require(
        WineDesktopShortcutBundleSignatureVerifier
            .stableIdentity(at: bundle)
    )
    let interruptedRollbackID = UUID().uuidString
    let interruptedRollbackTransaction =
        desktop.appendingPathComponent(
            ".switchyard-shortcut-transaction-\(interruptedRollbackID)",
            isDirectory: true
        )
    try fileManager.createDirectory(
        at: interruptedRollbackTransaction,
        withIntermediateDirectories: false
    )
    #expect(
        Darwin.chmod(
            interruptedRollbackTransaction.path,
            mode_t(S_IRWXU)
        ) == 0
    )
    let interruptedRollbackJournal =
        DesktopShortcutTransactionJournalFixture(
            state: "preparing",
            transactionID: interruptedRollbackID,
            backups: [
                .init(
                    originalName: bundle.lastPathComponent,
                    backupName: "backup-0",
                    originalIdentity: restoredIdentity
                )
            ],
            targets: [
                .init(
                    bundleName: bundle.lastPathComponent,
                    shortcutID: shortcutID,
                    stableIdentity:
                        desktopShortcutStableIdentityFixture(
                            inode: UInt64.max - 1
                        )
                )
            ],
            previousRouteData: routesData
        )
    try JSONEncoder().encode(
        interruptedRollbackJournal
    ).write(
        to: interruptedRollbackTransaction
            .appendingPathComponent("journal-v1.json"),
        options: .atomic
    )
    let recoveredInterruptedRollback =
        try await bridge.refresh(
            containers: [container],
            winePath: wine.path,
            runnerPath: runner.path
        )
    #expect(
        recoveredInterruptedRollback.createdShortcutNames
            .isEmpty
    )
    #expect(
        !fileManager.fileExists(
            atPath: interruptedRollbackTransaction.path
        )
    )
    #expect(
        WineDesktopShortcutBundleSignatureVerifier
            .stableIdentity(at: bundle) == restoredIdentity
    )

    let embeddedHelper = bundle.appendingPathComponent(
        "Contents/MacOS/switchyard-shortcut-handler"
    )
    let signatureResources = bundle.appendingPathComponent(
        "Contents/_CodeSignature/CodeResources"
    )
    var invalidSignatureData = try Data(
        contentsOf: signatureResources
    )
    invalidSignatureData.append(0)
    try invalidSignatureData.write(
        to: signatureResources,
        options: .atomic
    )
    #expect(
        try runCodesign(
            arguments: ["--verify", "--strict", bundle.path]
        ) != 0
    )
    let analysisPathRecorder =
        DesktopShortcutAnalysisPathRecorder()
    let signatureFirstBridge = WineDesktopShortcutBridge(
        fileManager: fileManager,
        rootURL: bridgeRoot,
        desktopURL: desktop,
        helperIdentityCache:
            WineDesktopShortcutHelperIdentityCache(
                analyzer: analysisPathRecorder.analyze
            )
    )
    let signatureRepaired = try await signatureFirstBridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(
        signatureRepaired.createdShortcutNames == ["Heartopia"]
    )
    #expect(
        !analysisPathRecorder.paths.contains(
            embeddedHelper.path
        )
    )

    let alternateExecutable = bundle.appendingPathComponent(
        "Contents/MacOS/evil"
    )
    try fileManager.copyItem(
        at: URL(fileURLWithPath: "/bin/echo"),
        to: alternateExecutable
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: alternateExecutable.path
    )
    let infoURL = bundle.appendingPathComponent(
        "Contents/Info.plist"
    )
    let originalInfoData = try Data(contentsOf: infoURL)
    var alternateInfo = try #require(
        PropertyListSerialization.propertyList(
            from: originalInfoData,
            options: [],
            format: nil
        ) as? [String: Any]
    )
    alternateInfo["CFBundleExecutable"] = "evil"
    alternateInfo["LSEnvironment"] = [
        "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"
    ]
    try PropertyListSerialization.data(
        fromPropertyList: alternateInfo,
        format: .xml,
        options: 0
    ).write(to: infoURL, options: .atomic)
    #expect(
        try runCodesign(
            arguments: [
                "--force",
                "--deep",
                "--sign",
                "-",
                bundle.path
            ]
        ) == 0
    )
    #expect(
        try runCodesign(
            arguments: ["--verify", "--strict", bundle.path]
        ) == 0
    )
    let metadataRepaired = try await bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(
        metadataRepaired.createdShortcutNames == ["Heartopia"]
    )
    #expect(
        !fileManager.fileExists(
            atPath: alternateExecutable.path
        )
    )
    let repairedInfoData = try Data(contentsOf: infoURL)
    let repairedInfo = try #require(
        PropertyListSerialization.propertyList(
            from: repairedInfoData,
            options: [],
            format: nil
        ) as? [String: Any]
    )
    #expect(
        repairedInfo["CFBundleExecutable"] as? String
            == "switchyard-shortcut-handler"
    )
    #expect(repairedInfo["LSEnvironment"] == nil)

    let expectedHelper = try Data(contentsOf: embeddedHelper)
    try fileManager.removeItem(at: embeddedHelper)
    try fileManager.copyItem(
        at: URL(fileURLWithPath: "/bin/echo"),
        to: embeddedHelper
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: embeddedHelper.path
    )
    #expect(
        try runCodesign(
            arguments: ["--force", "--sign", "-", bundle.path]
        ) == 0
    )
    #expect(
        try runCodesign(
            arguments: ["--verify", "--strict", bundle.path]
        ) == 0
    )
    let forgedIdentity = try #require(
        WineDesktopShortcutHelperIdentityReader.identity(
            at: embeddedHelper
        )
    )
    let forgedIdentityData = try JSONEncoder().encode(
        [shortcutID: forgedIdentity]
    )
    try forgedIdentityData.write(
        to: bridgeRoot.appendingPathComponent(
            "generated-helper-identities-v1.json"
        )
    )
    let repaired = try await bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(repaired.createdShortcutNames == ["Heartopia"])
    #expect(repaired.removedShortcutNames.isEmpty)
    #expect(try Data(contentsOf: embeddedHelper) == expectedHelper)
    #expect(
        try runCodesign(
            arguments: ["--verify", "--strict", bundle.path]
        ) == 0
    )

    let unexpectedResource = bundle.appendingPathComponent(
        "Contents/Resources/unexpected"
    )
    try Data("unexpected".utf8).write(to: unexpectedResource)
    #expect(
        try runCodesign(
            arguments: [
                "--force",
                "--deep",
                "--sign",
                "-",
                bundle.path
            ]
        ) == 0
    )
    commitFault.failBeforeNextCleanup()
    do {
        _ = try await bridge.refresh(
            containers: [container],
            winePath: wine.path,
            runnerPath: runner.path
        )
        Issue.record("Expected transaction cleanup failure")
    } catch WineDesktopShortcutBridgeError
        .committedTransactionNeedsCleanup {
        // The committed marker must make the residue recoverable.
    }
    #expect(fileManager.fileExists(atPath: bundle.path))
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .contains {
                $0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )
    let cleanupRetry = try await bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(cleanupRetry.createdShortcutNames.isEmpty)
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )

    let routeDataBeforeFailedCommit = try Data(
        contentsOf: bridgeRoot.appendingPathComponent(
            "routes-v1.json"
        )
    )
    let replacementSource = wineDesktop.appendingPathComponent(
        "Replacement.url"
    )
    try Data(
        "[InternetShortcut]\nURL=xdt://replacement\n".utf8
    ).write(to: replacementSource)
    let replacementWindowsPath =
        #"C:\users\steamuser\Desktop\Replacement.url"#
    let replacementManifest = """
    \(WineDesktopShortcutFormat.manifestHeader)
    url\t\(hex("Replacement"))\t\(hex(replacementWindowsPath))\t
    """
    try Data(replacementManifest.utf8).write(
        to: manifestURL,
        options: .atomic
    )
    commitFault.failAfterNextInstallAndRollbackMarker()
    do {
        _ = try await bridge.refresh(
            containers: [container],
            winePath: wine.path,
            runnerPath: runner.path
        )
        Issue.record("Expected injected commit failure")
    } catch {
        #expect(error is POSIXError)
    }
    #expect(
        try Data(
            contentsOf: bridgeRoot.appendingPathComponent(
                "routes-v1.json"
            )
        ) == routeDataBeforeFailedCommit
    )
    #expect(fileManager.fileExists(atPath: bundle.path))
    #expect(
        !fileManager.fileExists(
            atPath: desktop.appendingPathComponent(
                "Replacement.app",
                isDirectory: true
            ).path
        )
    )
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .contains {
                $0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )
    let rollbackRecoveryPrepared = try bridge.prepareRefresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: wine.path
    )
    _ = try await bridge.refresh(
        rollbackRecoveryPrepared,
        fileDigests: [:]
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    #expect(fileManager.fileExists(atPath: bundle.path))
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )

    let replacementBundle = desktop.appendingPathComponent(
        "Replacement.app",
        isDirectory: true
    )
    commitFault.addSidecarAtNextRoutePublish(
        replacementBundle
    )
    do {
        _ = try await bridge.refresh(
            containers: [container],
            winePath: wine.path,
            runnerPath: runner.path
        )
        Issue.record("Expected sidecar target failure")
    } catch {
        #expect(error is POSIXError)
    }
    let replacementSidecar = replacementBundle
        .appendingPathComponent("keep")
    #expect(
        try Data(contentsOf: replacementSidecar)
            == Data("user sidecar".utf8)
    )
    #expect(
        fileManager.fileExists(
            atPath: replacementBundle.appendingPathComponent(
                "Contents",
                isDirectory: true
            ).path
        )
    )
    try fileManager.removeItem(at: replacementSidecar)
    let sidecarRecoveryPrepared =
        try bridge.prepareRefresh(
            containers: [container],
            winePath: wine.path,
            runnerPath: runner.path
        )
    try fileManager.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: wine.path
    )
    _ = try await bridge.refresh(
        sidecarRecoveryPrepared,
        fileDigests: [:]
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    #expect(fileManager.fileExists(atPath: bundle.path))

    commitFault.substituteTargetAtNextRoutePublish(
        replacementBundle
    )
    do {
        _ = try await bridge.refresh(
            containers: [container],
            winePath: wine.path,
            runnerPath: runner.path
        )
        Issue.record("Expected substituted target failure")
    } catch {
        #expect(error is POSIXError)
    }
    #expect(
        try Data(
            contentsOf: replacementBundle
                .appendingPathComponent("keep")
        ) == Data("user replacement".utf8)
    )
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .contains {
                $0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )
    try fileManager.removeItem(at: replacementBundle)
    let substitutionRecoveryPrepared =
        try bridge.prepareRefresh(
            containers: [container],
            winePath: wine.path,
            runnerPath: runner.path
        )
    try fileManager.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: wine.path
    )
    _ = try await bridge.refresh(
        substitutionRecoveryPrepared,
        fileDigests: [:]
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )
    #expect(fileManager.fileExists(atPath: bundle.path))
    #expect(
        try fileManager.contentsOfDirectory(atPath: desktop.path)
            .allSatisfy {
                !$0.hasPrefix(
                    ".switchyard-shortcut-transaction-"
                )
            }
    )

    commitFault.disable()
    try Data(manifest.utf8).write(
        to: manifestURL,
        options: .atomic
    )
    try fileManager.removeItem(at: replacementSource)

    try fileManager.removeItem(at: source)
    let third = try await bridge.refresh(
        containers: [container],
        winePath: wine.path,
        runnerPath: runner.path
    )
    #expect(third.removedShortcutNames == ["Heartopia — Test Container"])
    #expect(!fileManager.fileExists(atPath: bundle.path))
    #expect(fileManager.fileExists(atPath: unownedCollision.path))
}

private enum TestMachOByteOrder: Equatable {
    case littleEndian
    case bigEndian
}

private enum TestMachOMutation: String, CaseIterable {
    case codeSignatureCommand
    case codeSignatureCommandSize
    case codeSignatureDataOffset
    case linkEditFileOffset
    case linkEditFileSize
    case linkEditVMSize
}

private func mutateFirstMachOSlice(
    _ data: inout Data,
    mutation: TestMachOMutation
) throws {
    guard data.count >= 32 else {
        throw DesktopShortcutBridgeTestError.invalidMachOFixture
    }
    let magic = Array(data.prefix(4))
    let sliceOffset: Int
    switch magic {
    case [0xca, 0xfe, 0xba, 0xbe]:
        sliceOffset = Int(
            try testMachOUInt32(
                data,
                offset: 16,
                byteOrder: .bigEndian
            )
        )
    case [0xbe, 0xba, 0xfe, 0xca]:
        sliceOffset = Int(
            try testMachOUInt32(
                data,
                offset: 16,
                byteOrder: .littleEndian
            )
        )
    case [0xca, 0xfe, 0xba, 0xbf]:
        sliceOffset = Int(
            try testMachOUInt64(
                data,
                offset: 16,
                byteOrder: .bigEndian
            )
        )
    case [0xbf, 0xba, 0xfe, 0xca]:
        sliceOffset = Int(
            try testMachOUInt64(
                data,
                offset: 16,
                byteOrder: .littleEndian
            )
        )
    default:
        sliceOffset = 0
    }

    guard sliceOffset >= 0,
          sliceOffset <= data.count - 32 else {
        throw DesktopShortcutBridgeTestError.invalidMachOFixture
    }
    let sliceMagic = Array(
        data[sliceOffset..<(sliceOffset + 4)]
    )
    let byteOrder: TestMachOByteOrder
    let is64Bit: Bool
    switch sliceMagic {
    case [0xcf, 0xfa, 0xed, 0xfe]:
        byteOrder = .littleEndian
        is64Bit = true
    case [0xfe, 0xed, 0xfa, 0xcf]:
        byteOrder = .bigEndian
        is64Bit = true
    case [0xce, 0xfa, 0xed, 0xfe]:
        byteOrder = .littleEndian
        is64Bit = false
    case [0xfe, 0xed, 0xfa, 0xce]:
        byteOrder = .bigEndian
        is64Bit = false
    default:
        throw DesktopShortcutBridgeTestError.invalidMachOFixture
    }
    let headerSize = is64Bit ? 32 : 28
    let commandCount = Int(
        try testMachOUInt32(
            data,
            offset: sliceOffset + 16,
            byteOrder: byteOrder
        )
    )
    var commandOffset = sliceOffset + headerSize
    var codeSignatureOffset: Int?
    var linkEditOffset: Int?
    for _ in 0..<commandCount {
        let command = try testMachOUInt32(
            data,
            offset: commandOffset,
            byteOrder: byteOrder
        )
        let commandSize = Int(
            try testMachOUInt32(
                data,
                offset: commandOffset + 4,
                byteOrder: byteOrder
            )
        )
        guard commandSize >= 8,
              commandOffset <= data.count - commandSize else {
            throw DesktopShortcutBridgeTestError.invalidMachOFixture
        }
        if command == 0x1d {
            codeSignatureOffset = commandOffset
        }
        if command == (is64Bit ? 0x19 : 0x1) {
            let nameBytes = data[
                (commandOffset + 8)..<(commandOffset + 24)
            ].prefix { $0 != 0 }
            if String(bytes: nameBytes, encoding: .utf8)
                == "__LINKEDIT" {
                linkEditOffset = commandOffset
            }
        }
        commandOffset += commandSize
    }

    switch mutation {
    case .codeSignatureCommand:
        let offset = try #require(codeSignatureOffset)
        testMachOWriteUInt32(
            0x1c,
            to: &data,
            offset: offset,
            byteOrder: byteOrder
        )
    case .codeSignatureCommandSize:
        let offset = try #require(codeSignatureOffset)
        testMachOWriteUInt32(
            20,
            to: &data,
            offset: offset + 4,
            byteOrder: byteOrder
        )
    case .codeSignatureDataOffset:
        let offset = try #require(codeSignatureOffset)
        let dataOffset = try testMachOUInt32(
            data,
            offset: offset + 8,
            byteOrder: byteOrder
        )
        let dataSize = try testMachOUInt32(
            data,
            offset: offset + 12,
            byteOrder: byteOrder
        )
        guard dataSize > 16 else {
            throw DesktopShortcutBridgeTestError.invalidMachOFixture
        }
        testMachOWriteUInt32(
            dataOffset + 16,
            to: &data,
            offset: offset + 8,
            byteOrder: byteOrder
        )
        testMachOWriteUInt32(
            dataSize - 16,
            to: &data,
            offset: offset + 12,
            byteOrder: byteOrder
        )
    case .linkEditFileOffset:
        let offset = try #require(linkEditOffset)
        if is64Bit {
            let fileOffset = try testMachOUInt64(
                data,
                offset: offset + 40,
                byteOrder: byteOrder
            )
            let fileSize = try testMachOUInt64(
                data,
                offset: offset + 48,
                byteOrder: byteOrder
            )
            testMachOWriteUInt64(
                fileOffset + 4 * 1_024,
                to: &data,
                offset: offset + 40,
                byteOrder: byteOrder
            )
            testMachOWriteUInt64(
                fileSize - 4 * 1_024,
                to: &data,
                offset: offset + 48,
                byteOrder: byteOrder
            )
        } else {
            let fileOffset = try testMachOUInt32(
                data,
                offset: offset + 32,
                byteOrder: byteOrder
            )
            let fileSize = try testMachOUInt32(
                data,
                offset: offset + 36,
                byteOrder: byteOrder
            )
            testMachOWriteUInt32(
                fileOffset + 4 * 1_024,
                to: &data,
                offset: offset + 32,
                byteOrder: byteOrder
            )
            testMachOWriteUInt32(
                fileSize - 4 * 1_024,
                to: &data,
                offset: offset + 36,
                byteOrder: byteOrder
            )
        }
    case .linkEditFileSize:
        let offset = try #require(linkEditOffset)
        if is64Bit {
            let value = try testMachOUInt64(
                data,
                offset: offset + 48,
                byteOrder: byteOrder
            )
            testMachOWriteUInt64(
                value - 1,
                to: &data,
                offset: offset + 48,
                byteOrder: byteOrder
            )
        } else {
            let value = try testMachOUInt32(
                data,
                offset: offset + 36,
                byteOrder: byteOrder
            )
            testMachOWriteUInt32(
                value - 1,
                to: &data,
                offset: offset + 36,
                byteOrder: byteOrder
            )
        }
    case .linkEditVMSize:
        let offset = try #require(linkEditOffset)
        if is64Bit {
            let value = try testMachOUInt64(
                data,
                offset: offset + 32,
                byteOrder: byteOrder
            )
            testMachOWriteUInt64(
                value + 16 * 1_024,
                to: &data,
                offset: offset + 32,
                byteOrder: byteOrder
            )
        } else {
            let value = try testMachOUInt32(
                data,
                offset: offset + 28,
                byteOrder: byteOrder
            )
            testMachOWriteUInt32(
                value + 4 * 1_024,
                to: &data,
                offset: offset + 28,
                byteOrder: byteOrder
            )
        }
    }
}

private func testMachOUInt32(
    _ data: Data,
    offset: Int,
    byteOrder: TestMachOByteOrder
) throws -> UInt32 {
    guard offset >= 0, offset <= data.count - 4 else {
        throw DesktopShortcutBridgeTestError.invalidMachOFixture
    }
    switch byteOrder {
    case .littleEndian:
        return (0..<4).reduce(0) {
            $0 | UInt32(data[offset + $1]) << UInt32($1 * 8)
        }
    case .bigEndian:
        return (0..<4).reduce(0) {
            $0 << 8 | UInt32(data[offset + $1])
        }
    }
}

private func testMachOUInt64(
    _ data: Data,
    offset: Int,
    byteOrder: TestMachOByteOrder
) throws -> UInt64 {
    guard offset >= 0, offset <= data.count - 8 else {
        throw DesktopShortcutBridgeTestError.invalidMachOFixture
    }
    switch byteOrder {
    case .littleEndian:
        return (0..<8).reduce(0) {
            $0 | UInt64(data[offset + $1]) << UInt64($1 * 8)
        }
    case .bigEndian:
        return (0..<8).reduce(0) {
            $0 << 8 | UInt64(data[offset + $1])
        }
    }
}

private func testMachOWriteUInt32(
    _ value: UInt32,
    to data: inout Data,
    offset: Int,
    byteOrder: TestMachOByteOrder
) {
    for index in 0..<4 {
        let shift = byteOrder == .littleEndian
            ? index * 8
            : (3 - index) * 8
        data[offset + index] = UInt8(
            truncatingIfNeeded: value >> UInt32(shift)
        )
    }
}

private func testMachOWriteUInt64(
    _ value: UInt64,
    to data: inout Data,
    offset: Int,
    byteOrder: TestMachOByteOrder
) {
    for index in 0..<8 {
        let shift = byteOrder == .littleEndian
            ? index * 8
            : (7 - index) * 8
        data[offset + index] = UInt8(
            truncatingIfNeeded: value >> UInt64(shift)
        )
    }
}

private final class DesktopShortcutThreadRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var didObserveMainThread = false

    var observedMainThread: Bool {
        lock.withLock { didObserveMainThread }
    }

    func record(isMainThread: Bool) {
        lock.withLock {
            didObserveMainThread =
                didObserveMainThread || isMainThread
        }
    }
}

private final class DesktopShortcutProcessRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedProcessID: pid_t?

    var processID: pid_t? {
        lock.withLock { recordedProcessID }
    }

    func record(_ processID: pid_t) {
        lock.withLock {
            recordedProcessID = processID
        }
    }
}

private final class DesktopShortcutAnalysisCancellationRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var started = false
    private var observedCancellation = false

    var didStart: Bool {
        lock.withLock { started }
    }

    var didObserveCancellation: Bool {
        lock.withLock { observedCancellation }
    }

    func recordStarted() {
        lock.withLock {
            started = true
        }
    }

    func recordCancelled() {
        lock.withLock {
            observedCancellation = true
        }
    }
}

private final class DesktopShortcutAnalysisPathRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedPaths: Set<String> = []

    var paths: Set<String> {
        lock.withLock { recordedPaths }
    }

    func analyze(
        _ url: URL,
        _ profile: WineDesktopShortcutHelperProfile?
    ) -> WineDesktopShortcutHelperAnalysis? {
        _ = lock.withLock {
            recordedPaths.insert(url.path)
        }
        return WineDesktopShortcutHelperIdentityReader.analysis(
            at: url,
            matching: profile
        )
    }
}

private final class DesktopShortcutSignatureAnalysisRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0
    private var observedOffMainThread = false

    var executionCount: Int {
        lock.withLock { count }
    }

    var ranOffMainThread: Bool {
        lock.withLock { observedOffMainThread }
    }

    func record() {
        lock.withLock {
            count += 1
            observedOffMainThread =
                observedOffMainThread || !Thread.isMainThread
        }
    }
}

private final class DesktopShortcutStableIdentityAnalysisRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0
    private var observedOffMainThread = false

    var executionCount: Int {
        lock.withLock { count }
    }

    var ranOffMainThread: Bool {
        lock.withLock { observedOffMainThread }
    }

    func analyze(
        _ url: URL,
        _ maximumEntryCount: Int
    ) -> WineDesktopShortcutBundleStableIdentity? {
        let identityNumber = lock.withLock {
            count += 1
            observedOffMainThread =
                observedOffMainThread || !Thread.isMainThread
            return count
        }
        guard maximumEntryCount > 0 else { return nil }
        return desktopShortcutStableIdentityFixture(
            inode: UInt64(identityNumber)
        )
    }
}

private final class DesktopShortcutSuspendingStableIdentityAnalyzer:
    @unchecked Sendable
{
    private let started = DispatchSemaphore(value: 0)
    private let resumeSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasResumed = false
    private var hasStarted = false

    func analyze(
        _ url: URL,
        _ maximumEntryCount: Int
    ) -> WineDesktopShortcutBundleStableIdentity? {
        guard maximumEntryCount > 0 else { return nil }
        let shouldSuspend = lock.withLock {
            guard !hasStarted else { return false }
            hasStarted = true
            return true
        }
        if shouldSuspend {
            started.signal()
            _ = resumeSignal.wait(timeout: .now() + 5)
        }
        return desktopShortcutStableIdentityFixture(inode: 1)
    }

    func waitUntilStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.started.wait(
                        timeout: .now() + 5
                    ) == .success
                )
            }
        }
    }

    func resume() {
        let shouldSignal = lock.withLock {
            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
        if shouldSignal {
            resumeSignal.signal()
        }
    }
}

private struct DesktopShortcutTransactionJournalFixture:
    Codable
{
    struct Backup: Codable {
        let originalName: String
        let backupName: String
        let originalIdentity:
            WineDesktopShortcutBundleStableIdentity
    }

    struct Target: Codable {
        let bundleName: String
        let shortcutID: String
        let stableIdentity:
            WineDesktopShortcutBundleStableIdentity
    }

    let state: String
    let transactionID: String
    let backups: [Backup]
    let targets: [Target]
    let previousRouteData: Data?
}

private func desktopShortcutStableIdentityFixture(
    inode: UInt64
) -> WineDesktopShortcutBundleStableIdentity {
    WineDesktopShortcutBundleStableIdentity(
        rootDevice: 1,
        rootInode: inode,
        rootMode: UInt32(S_IFDIR | S_IRWXU),
        rootLinkCount: 1,
        rootOwnerUserID: UInt32(geteuid()),
        rootOwnerGroupID: UInt32(getegid()),
        treeEntryCount: UInt32(
            WineDesktopShortcutPersistenceLimits
                .maximumBundleTreeEntryCount
        ),
        treeDigest: String(
            repeating: String(
                format: "%02x",
                inode & 0xff
            ),
            count: 32
        )
    )
}

@MainActor
private final class DesktopShortcutCommitFaultInjector {
    private enum Fault {
        case afterInstallThenRollbackMarker
        case rollbackMarker
        case beforeCleanup
        case addSidecar(URL)
        case substituteTarget(URL)
    }

    private var fault: Fault?

    var hasPendingFault: Bool {
        fault != nil
    }

    func failAfterNextInstallAndRollbackMarker() {
        fault = .afterInstallThenRollbackMarker
    }

    func failBeforeNextCleanup() {
        fault = .beforeCleanup
    }

    func substituteTargetAtNextRoutePublish(
        _ targetURL: URL
    ) {
        fault = .substituteTarget(targetURL)
    }

    func addSidecarAtNextRoutePublish(
        _ targetURL: URL
    ) {
        fault = .addSidecar(targetURL)
    }

    func disable() {
        fault = nil
    }

    func checkpoint(
        _ checkpoint: WineDesktopShortcutCommitCheckpoint
    ) throws {
        switch (fault, checkpoint) {
        case (.beforeCleanup, .willCleanupTransaction):
            fault = nil
            throw DesktopShortcutBridgeTestError
                .injectedCommitFailure
        case (.afterInstallThenRollbackMarker, .didInstallBundle):
            fault = .rollbackMarker
            throw DesktopShortcutBridgeTestError
                .injectedCommitFailure
        case (.rollbackMarker, .willMarkRolledBack):
            fault = nil
            throw DesktopShortcutBridgeTestError
                .injectedCommitFailure
        case let (.addSidecar(targetURL), .willPublishRoutes):
            fault = nil
            try Data("user sidecar".utf8).write(
                to: targetURL.appendingPathComponent("keep")
            )
            throw DesktopShortcutBridgeTestError
                .injectedCommitFailure
        case let (.substituteTarget(targetURL), .willPublishRoutes):
            fault = nil
            try FileManager.default.removeItem(at: targetURL)
            try FileManager.default.createDirectory(
                at: targetURL,
                withIntermediateDirectories: false
            )
            try Data("user replacement".utf8).write(
                to: targetURL.appendingPathComponent("keep")
            )
            throw DesktopShortcutBridgeTestError
                .injectedCommitFailure
        default:
            return
        }
    }
}

private func processWasReaped(
    _ processID: pid_t
) -> Bool {
    var status: Int32 = 0
    errno = 0
    return Darwin.waitpid(processID, &status, WNOHANG) == -1
        && errno == ECHILD
}
