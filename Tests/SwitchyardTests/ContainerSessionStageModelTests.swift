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

private enum CaptureTestError: Error {
    case expected
}

@MainActor
@Test func captureWindowsPromptsForSettingsOnlyWhenScreenRecordingIsUnavailable() async {
    var requestCount = 0
    var shareableContentWasRequested = false
    let service = WineWindowCaptureService(
        screenRecordingPreflight: { false },
        screenRecordingRequest: {
            requestCount += 1
            return false
        },
        shareableContentProvider: {
            shareableContentWasRequested = true
            throw CaptureTestError.expected
        }
    )

    let firstResult = await service.captureWindows(
        ownedBy: [Int32.max]
    )
    let secondResult = await service.captureWindows(
        ownedBy: [Int32.max]
    )

    #expect(firstResult.screenRecordingAccessUnavailable)
    #expect(firstResult.message != nil)
    #expect(secondResult.screenRecordingAccessUnavailable)
    #expect(requestCount == 1)
    #expect(!shareableContentWasRequested)
}

@MainActor
@Test func captureWindowsDoesNotPromptForSettingsForShareableContentErrors() async {
    let service = WineWindowCaptureService(
        screenRecordingPreflight: { true },
        screenRecordingRequest: { false },
        shareableContentProvider: {
            throw CaptureTestError.expected
        }
    )

    let result = await service.captureWindows(
        ownedBy: [Int32.max]
    )

    #expect(!result.screenRecordingAccessUnavailable)
    #expect(result.message == nil)
}
