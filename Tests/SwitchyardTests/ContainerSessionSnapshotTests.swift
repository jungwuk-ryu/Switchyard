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
