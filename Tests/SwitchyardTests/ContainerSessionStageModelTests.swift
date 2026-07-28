import AppCore
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

private func window(
    id: CGWindowID,
    title: String,
    executablePath: String? = nil,
    frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
) -> WineWindowSnapshot {
    WineWindowSnapshot(
        id: id,
        ownerProcessID: 1,
        title: title,
        executablePath: executablePath,
        frame: frame,
        isOnScreen: true,
        image: nil
    )
}

@Test func sessionStageUsesWindowsExecutableNameWhenWineTitleIsGeneric() {
    let snapshot = window(
        id: 10,
        title: "wine",
        executablePath: #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#,
        frame: CGRect(x: 0, y: 0, width: 500, height: 500)
    )

    let presentation = SessionStageWindowPresentation.make(
        window: snapshot,
        programName: nil,
        fallbackName: "Fallback",
        position: 3,
        total: 6
    )

    #expect(snapshot.meaningfulTitle == nil)
    #expect(snapshot.executableDisplayName == "Battle.net")
    #expect(presentation.title == "Battle.net")
    #expect(presentation.detail == "#3/6 · 500 × 500")
}

@Test func sessionStageKeepsUsefulWindowTitleAsSecondaryIdentity() {
    let snapshot = window(
        id: 10,
        title: "Log In",
        executablePath: #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#
    )

    let presentation = SessionStageWindowPresentation.make(
        window: snapshot,
        programName: "Battle.net",
        fallbackName: "Fallback",
        position: 1,
        total: 2
    )

    #expect(presentation.title == "Battle.net")
    #expect(presentation.detail == "Log In · #1/2 · 800 × 600")
}

@Test func sessionStageMatchesHostExecutablePathBeforeDuplicateBasenames() {
    let prefixPath = "/tmp/SwitchyardTestPrefix"
    let targetPath = prefixPath + "/drive_c/Games/Target/Launcher.exe"
    let target = InstalledProgram(
        name: "Target Launcher",
        executablePath: targetPath,
        installDirectory: prefixPath + "/drive_c/Games/Target",
        source: .programFiles
    )
    let other = InstalledProgram(
        name: "Other Launcher",
        executablePath: prefixPath + "/drive_c/Games/Other/Launcher.exe",
        installDirectory: prefixPath + "/drive_c/Games/Other",
        source: .programFiles
    )
    let snapshot = window(
        id: 10,
        title: "wine",
        executablePath: targetPath
    )

    let match = SessionStageWindowProgramMatcher.match(
        window: snapshot,
        programs: [other, target],
        prefixPath: prefixPath
    )

    #expect(match == target)
}

@Test func sessionStageGridUsesPredictableLayoutsAcrossWindowCounts() {
    let sixWide = SessionStageWindowGridMetrics.make(
        windowCount: 6,
        availableSize: CGSize(width: 1_400, height: 700)
    )
    let sixCompact = SessionStageWindowGridMetrics.make(
        windowCount: 6,
        availableSize: CGSize(width: 800, height: 700)
    )
    let twelveWide = SessionStageWindowGridMetrics.make(
        windowCount: 12,
        availableSize: CGSize(width: 1_400, height: 700)
    )
    let twelveCompact = SessionStageWindowGridMetrics.make(
        windowCount: 12,
        availableSize: CGSize(width: 1_000, height: 700)
    )

    #expect((sixWide.columns, sixWide.rows) == (3, 2))
    #expect((sixCompact.columns, sixCompact.rows) == (2, 3))
    #expect((twelveWide.columns, twelveWide.rows) == (4, 3))
    #expect((twelveCompact.columns, twelveCompact.rows) == (3, 4))
}

@MainActor
@Test func wineWindowCaptureDecodesWindowsProcessArguments() {
    let arguments = [
        #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#,
        "--type=renderer",
        "--lang=en-US",
    ]
    var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
    bytes.append(contentsOf: "/path/to/wine".utf8)
    bytes.append(contentsOf: [0, 0, 0])
    for argument in arguments {
        bytes.append(contentsOf: argument.utf8)
        bytes.append(0)
    }

    #expect(
        WineWindowCaptureService.decodeProcessArguments(fromKernelBytes: bytes)
            == arguments
    )
}

@MainActor
@Test func wineWindowActivationDisambiguatesGenericTitlesByFrame() {
    let snapshotFrame = CGRect(x: 400, y: 180, width: 700, height: 520)
    let nearbyScore = WineWindowCaptureService.windowMatchScore(
        snapshotTitle: "",
        snapshotFrame: snapshotFrame,
        candidateTitle: "wine",
        candidateFrame: CGRect(x: 402, y: 182, width: 700, height: 520)
    )
    let distantScore = WineWindowCaptureService.windowMatchScore(
        snapshotTitle: "",
        snapshotFrame: snapshotFrame,
        candidateTitle: "wine",
        candidateFrame: CGRect(x: 1_400, y: 180, width: 500, height: 500)
    )

    #expect(nearbyScore < distantScore)
    #expect(
        WineWindowCaptureService.windowMatchIsCredible(
            snapshotTitle: "",
            snapshotFrame: snapshotFrame,
            candidateTitle: "wine",
            candidateFrame: CGRect(x: 402, y: 182, width: 700, height: 520)
        )
    )
    #expect(
        !WineWindowCaptureService.windowMatchIsCredible(
            snapshotTitle: "",
            snapshotFrame: snapshotFrame,
            candidateTitle: "wine",
            candidateFrame: CGRect(x: 1_400, y: 180, width: 500, height: 500)
        )
    )
    #expect(
        WineWindowCaptureService.windowMatchIsCredible(
            snapshotTitle: "Sign In",
            snapshotFrame: snapshotFrame,
            candidateTitle: "Sign In",
            candidateFrame: nil
        )
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
