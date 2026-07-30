import Foundation
@testable import Switchyard
import Testing

@Test func onlyActiveWineServerStateReportsWineServerRunning() {
    #expect(WineServerState.active.isWineServerRunning)
    #expect(!WineServerState.checking.isWineServerRunning)
    #expect(!WineServerState.orphaned.isWineServerRunning)
    #expect(!WineServerState.inactive.isWineServerRunning)
    #expect(!WineServerState.unavailable.isWineServerRunning)
}

@Test func sessionSnapshotPublishesOnlyMeaningfulChanges() {
    let original = ContainerSessionSnapshot(
        wineServerState: .active,
        processes: [
            WindowsProcessSnapshot(
                executablePath: "C:\\Game.exe",
                processID: 7
            )
        ],
        hostProcessIDs: [41],
        refreshedAt: Date(timeIntervalSince1970: 1),
        message: nil
    )
    var timestampOnly = original
    timestampOnly.refreshedAt = Date(timeIntervalSince1970: 2)
    var changedHostProcesses = timestampOnly
    changedHostProcesses.hostProcessIDs = [42]

    #expect(original.hasSamePublishedMeaning(as: timestampOnly))
    #expect(!original.hasSamePublishedMeaning(as: changedHostProcesses))
}

@Test func sessionSnapshotDisambiguatesDuplicateLegacyProcessPaths() {
    let processes = [
        WindowsProcessSnapshot(executablePath: #"C:\Games\Example\game.exe"#),
        WindowsProcessSnapshot(executablePath: #"C:\Tools\helper.exe"#),
        WindowsProcessSnapshot(executablePath: #"c:\games\example\GAME.EXE"#),
    ]
    let first = ContainerSessionSnapshot(
        wineServerState: .active,
        processes: processes
    )
    let repeated = ContainerSessionSnapshot(
        wineServerState: .active,
        processes: processes
    )

    #expect(Set(first.processes.map(\.id)).count == first.processes.count)
    #expect(first.processes.map(\.id) == repeated.processes.map(\.id))
    #expect(first.processes[0].id != first.processes[2].id)
    #expect(first.processes == processes)
}

@Test func sessionSnapshotKeepsPIDProcessIdentityUnchanged() {
    let snapshot = ContainerSessionSnapshot(
        wineServerState: .active,
        processes: [
            WindowsProcessSnapshot(
                executablePath: #"C:\Games\Example\game.exe"#,
                processID: 100
            ),
            WindowsProcessSnapshot(
                executablePath: #"C:\Games\Example\game.exe"#,
                processID: 200
            ),
        ]
    )

    #expect(snapshot.processes.map(\.id) == ["pid:100", "pid:200"])
}
