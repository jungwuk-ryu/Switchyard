import CoreGraphics
import Testing
@testable import Switchyard

@MainActor
@Test func sessionStageKeepsExistingWindowOrderAndAppendsNewWindows() {
    let previous = [
        window(id: 10, title: "First"),
        window(id: 20, title: "Second"),
        window(id: 30, title: "Closed")
    ]
    let refreshed = [
        window(id: 40, title: "New"),
        window(id: 20, title: "Second Updated"),
        window(id: 10, title: "First Updated")
    ]

    let ordered = ContainerSessionStageModel.windowsKeepingStableOrder(
        previous: previous,
        refreshed: refreshed
    )

    #expect(ordered.map(\.id) == [10, 20, 40])
    #expect(ordered.map(\.title) == ["First Updated", "Second Updated", "New"])
}

private func window(id: CGWindowID, title: String) -> WineWindowSnapshot {
    WineWindowSnapshot(
        id: id,
        ownerProcessID: 1,
        title: title,
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        isOnScreen: true,
        image: nil
    )
}
