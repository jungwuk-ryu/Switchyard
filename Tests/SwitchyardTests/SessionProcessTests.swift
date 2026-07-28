import AppCore
import Foundation
import RuntimeCatalog
import Testing
@testable import Switchyard

@Test func windowsProcessSnapshotsKeepDuplicateExecutablesDistinctByProcessID() {
    let first = WindowsProcessSnapshot(
        executablePath: #"C:\Games\Example\game.exe"#,
        processID: 100
    )
    let second = WindowsProcessSnapshot(
        executablePath: #"C:\Games\Example\game.exe"#,
        processID: 200
    )

    #expect(first.id != second.id)
    #expect(first.name == "game.exe")
    #expect(second.name == "game.exe")
}

@Test func runnerClientDecodesDetailedAndLegacyProcessPayloads() throws {
    let detailedData = Data(
        #"[{"executablePath":"C:\\Games\\Example\\game.exe","processID":42}]"#.utf8
    )
    let legacyData = Data(
        #"["C:\\Games\\Example\\game.exe"]"#.utf8
    )

    #expect(
        try SwitchyardRunnerClient.decodeRunningWindowsProcesses(
            from: detailedData
        ) == [
            RunningWindowsProcess(
                executablePath: #"C:\Games\Example\game.exe"#,
                processID: 42
            )
        ]
    )
    #expect(
        try SwitchyardRunnerClient.decodeRunningWindowsProcesses(
            from: legacyData
        ) == [
            RunningWindowsProcess(
                executablePath: #"C:\Games\Example\game.exe"#,
                processID: nil
            )
        ]
    )
}

@Test func sessionInspectorUsesContextualPrimaryActions() {
    #expect(
        SessionInspectorPrimaryAction.resolve(
            wineServerState: .active,
            isStartingSession: false
        ) == .endSession
    )
    #expect(
        SessionInspectorPrimaryAction.resolve(
            wineServerState: .orphaned,
            isStartingSession: false
        ) == .cleanUp
    )
    #expect(
        SessionInspectorPrimaryAction.resolve(
            wineServerState: .inactive,
            isStartingSession: false
        ) == .run
    )
    #expect(
        SessionInspectorPrimaryAction.resolve(
            wineServerState: .unavailable,
            isStartingSession: false
        ) == .retry
    )
    #expect(
        SessionInspectorPrimaryAction.resolve(
            wineServerState: .inactive,
            isStartingSession: true
        ) == .starting
    )
}

@Test func sessionRuntimeResolverKeepsUsingTheRuntimeThatStartedTheSession() {
    let current = RuntimeBuild(
        id: "runtime-new",
        winePath: "/runtimes/new/bin/wine",
        patchsetID: "switchyard-wine-new",
        sourceRevision: "new"
    )
    let previous = RuntimeBuild(
        id: "runtime-old",
        winePath: "/runtimes/old/bin/wine",
        patchsetID: "switchyard-wine-old",
        sourceRevision: "old"
    )
    let installation = ManagedRuntimeInstallation(
        id: "runtime-old-installation",
        rootURL: URL(fileURLWithPath: "/runtimes/old"),
        runtime: previous,
        installedAt: Date(),
        isCompleteWoW64: true,
        isCleanSource: true
    )
    let record = ContainerRuntimeRecord(
        runtimeID: previous.id,
        patchsetID: previous.patchsetID,
        sourceRevision: previous.sourceRevision
    )

    #expect(
        SessionRuntimeResolver.runtime(
            currentRuntime: current,
            installedRuntimes: [installation],
            lastRuntime: record,
            isLaunching: false
        ) == previous
    )
    #expect(
        SessionRuntimeResolver.runtime(
            currentRuntime: current,
            installedRuntimes: [installation],
            lastRuntime: record,
            isLaunching: true
        ) == current
    )
}
