import AppCore
import Foundation
import Testing
@testable import Switchyard

@MainActor
@Test func logStoreReturnsOnlyTheRequestedContainersRecentRows() {
    let firstContainerID = UUID()
    let secondContainerID = UUID()
    let store = LogStore(
        lines: [
            LogLine(
                containerID: firstContainerID,
                level: "warning",
                source: "first",
                message: "newest"
            ),
            LogLine(
                containerID: secondContainerID,
                level: "info",
                source: "second",
                message: "other"
            ),
            LogLine(
                containerID: firstContainerID,
                level: "info",
                source: "first",
                message: "older"
            ),
        ]
    )

    #expect(
        store.recent(for: firstContainerID, limit: 1).map(\.message)
            == ["newest"]
    )
    #expect(store.recent(for: firstContainerID, limit: 0).isEmpty)
}
