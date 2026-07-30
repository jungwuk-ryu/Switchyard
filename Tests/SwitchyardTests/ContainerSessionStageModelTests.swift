import AppCore
import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import Switchyard

@Test func sessionStageUsesTheConfiguredDefaultProgramInsteadOfCatalogOrder() throws {
    let first = installedProgram(name: "First", path: "/prefix/drive_c/First.exe")
    let configured = installedProgram(name: "Configured", path: "/prefix/drive_c/Configured.exe")

    let resolution = SessionStageDefaultProgramResolver.resolve(
        configuredExecutablePath: configured.executablePath,
        programs: [first, configured]
    )

    #expect(resolution.program == configured)
    #expect(!resolution.requiresDefaultReselection)
}

@Test func sessionStageDoesNotFallBackWhenTheConfiguredDefaultIsMissing() {
    let unrelated = installedProgram(name: "Unrelated", path: "/prefix/drive_c/Unrelated.exe")

    let resolution = SessionStageDefaultProgramResolver.resolve(
        configuredExecutablePath: "/prefix/drive_c/Missing.exe",
        programs: [unrelated]
    )

    #expect(resolution.program == nil)
    #expect(resolution.requiresDefaultReselection)
}

@Test func sessionStageUsesTheFirstProgramOnlyWhenNoDefaultIsConfigured() throws {
    let first = installedProgram(name: "First", path: "/prefix/drive_c/First.exe")
    let second = installedProgram(name: "Second", path: "/prefix/drive_c/Second.exe")

    for configuredExecutablePath in [nil, "", " \n\t"] as [String?] {
        let resolution = SessionStageDefaultProgramResolver.resolve(
            configuredExecutablePath: configuredExecutablePath,
            programs: [first, second]
        )

        #expect(resolution.program == first)
        #expect(!resolution.requiresDefaultReselection)
    }
}

@Test func sessionStageRequestsAProgramWhenNoDefaultOrCatalogEntryExists() {
    let resolution = SessionStageDefaultProgramResolver.resolve(
        configuredExecutablePath: nil,
        programs: []
    )

    #expect(resolution.program == nil)
    #expect(!resolution.requiresDefaultReselection)
}

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

@Test func sessionStageWindowLayoutKeepsIdentityAcrossReorderAndRemoval() {
    let first = window(id: 10, title: "First", ownerProcessID: 101)
    let second = window(id: 20, title: "Second", ownerProcessID: 202)

    let original = SessionStageWindowGridLayout.items(for: [first, second])
    let reordered = SessionStageWindowGridLayout.items(for: [second, first])
    let afterRemoval = SessionStageWindowGridLayout.items(for: [second])

    #expect(original.map(\.id) == [reordered[1].id, reordered[0].id])
    #expect(original[1].id == afterRemoval[0].id)
    #expect(original[1].layoutIndex == 1)
    #expect(afterRemoval[0].layoutIndex == 0)
    #expect(original[0].id != afterRemoval[0].id)
}

@Test func sessionStageWindowIdentityRejectsReusedWindowIDFromAnotherProcess() {
    let original = window(id: 10, title: "Original", ownerProcessID: 101)
    let reused = window(id: 10, title: "Replacement", ownerProcessID: 202)
    let identity = SessionStageWindowIdentity(window: original)

    #expect(identity.matches(original))
    #expect(!identity.matches(reused))
}

@MainActor
@Test func sessionStageTreatsReusedWindowIDAsNewWindowForOrdering() {
    let original = window(id: 10, title: "Original", ownerProcessID: 101)
    let existing = window(id: 20, title: "Existing", ownerProcessID: 303)
    let reused = window(id: 10, title: "Replacement", ownerProcessID: 202)

    let ordered = ContainerSessionStageModel.windowsKeepingStableOrder(
        previous: [original, existing],
        refreshed: [reused, existing]
    )

    #expect(ordered.map(\.ownerProcessID) == [303, 202])
    #expect(ordered.map(\.title) == ["Existing", "Replacement"])
}

@Test func sessionStageWindowStateRejectsReusedWindowIDFromAnotherProcess() throws {
    let original = window(id: 10, title: "Original", ownerProcessID: 101)
    let reused = window(id: 10, title: "Replacement", ownerProcessID: 202)
    let reusedItem = try #require(
        SessionStageWindowGridLayout.items(for: [reused]).first
    )
    let selectedIdentity = SessionStageWindowIdentity(window: original)
    let closingIdentities: Set<SessionStageWindowIdentity> = [selectedIdentity]

    #expect(reusedItem.id != selectedIdentity)
    #expect(!selectedIdentity.matches(reused))
    #expect(!closingIdentities.contains(reusedItem.id))
}

@MainActor
@Test func sessionStageSelectionFallsBackWhenSelectedWindowIDIsReused() {
    let original = window(id: 10, title: "Original", ownerProcessID: 101)
    let fallback = window(id: 20, title: "Fallback", ownerProcessID: 303)
    let reused = window(id: 10, title: "Replacement", ownerProcessID: 202)

    let selected = ContainerSessionStageModel.selectedWindowIdentity(
        previous: SessionStageWindowIdentity(window: original),
        selectedWindowID: original.id,
        windows: [fallback, reused]
    )

    #expect(selected == SessionStageWindowIdentity(window: fallback))
    #expect(selected != SessionStageWindowIdentity(window: reused))
}

@MainActor
@Test func sessionStageClosingStateDropsReusedWindowIDFromAnotherProcess() {
    let original = window(id: 10, title: "Original", ownerProcessID: 101)
    let reused = window(id: 10, title: "Replacement", ownerProcessID: 202)
    let closing = Set([SessionStageWindowIdentity(window: original)])

    let pruned = ContainerSessionStageModel.closingWindowIdentities(
        closing,
        stillPresentIn: [reused]
    )

    #expect(pruned.isEmpty)
}

private func window(
    id: CGWindowID,
    title: String,
    executablePath: String? = nil,
    frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
    ownerProcessID: pid_t = 1
) -> WineWindowSnapshot {
    WineWindowSnapshot(
        id: id,
        ownerProcessID: ownerProcessID,
        title: title,
        executablePath: executablePath,
        frame: frame,
        isOnScreen: true,
        image: nil
    )
}

private func installedProgram(name: String, path: String) -> InstalledProgram {
    InstalledProgram(
        name: name,
        executablePath: path,
        installDirectory: URL(fileURLWithPath: path).deletingLastPathComponent().path,
        source: .programFiles
    )
}

@Test func sessionTaskbarGroupsOnlyRunningWindowsByExactGuestPath() throws {
    let prefixPath = "/tmp/SwitchyardTaskbarPrefix"
    let firstProgram = InstalledProgram(
        name: "First Game",
        executablePath: prefixPath + "/drive_c/Games/First/game.exe",
        installDirectory: prefixPath + "/drive_c/Games/First",
        source: .programFiles
    )
    let secondProgram = InstalledProgram(
        name: "Second Game",
        executablePath: prefixPath + "/drive_c/Games/Second/game.exe",
        installDirectory: prefixPath + "/drive_c/Games/Second",
        source: .programFiles
    )
    let notRunning = InstalledProgram(
        name: "Not Running",
        executablePath: prefixPath + "/drive_c/Games/Idle/idle.exe",
        installDirectory: prefixPath + "/drive_c/Games/Idle",
        source: .programFiles
    )
    let windows = [
        window(
            id: 1,
            title: "First Game",
            executablePath: firstProgram.executablePath,
            ownerProcessID: 101
        ),
        window(
            id: 2,
            title: "First Game Settings",
            executablePath: #"C:\Games\First\game.exe"#,
            ownerProcessID: 202
        ),
        window(
            id: 3,
            title: "Second Game",
            executablePath: secondProgram.executablePath,
            ownerProcessID: 303
        ),
    ]

    let items = SessionStageTaskbarPolicy.makeItems(
        windows: windows,
        programs: [firstProgram, secondProgram, notRunning],
        pinnedWindowsPaths: [
            #"C:\Games\Second\game.exe"#,
            #"C:\Games\First\game.exe"#,
        ],
        prefixPath: prefixPath,
        selectedWindowIdentity: SessionStageWindowIdentity(window: windows[1]),
        fallbackName: "Games"
    )

    #expect(items.map(\.title) == ["Second Game", "First Game"])
    #expect(items.map(\.windows.count) == [1, 2])
    #expect(items.allSatisfy { $0.isPinned })
    #expect(items.allSatisfy { $0.isRunning })
    #expect(items.map(\.isActive) == [false, true])
    #expect(!items.contains(where: { $0.title == "Not Running" }))
}

@Test func sessionTaskbarDoesNotMarkReusedWindowIDActive() {
    let original = window(id: 10, title: "Original", ownerProcessID: 101)
    let reused = window(id: 10, title: "Replacement", ownerProcessID: 202)

    let items = SessionStageTaskbarPolicy.makeItems(
        windows: [reused],
        programs: [],
        pinnedWindowsPaths: [],
        prefixPath: "/tmp/SwitchyardTaskbarPrefix",
        selectedWindowIdentity: SessionStageWindowIdentity(window: original),
        fallbackName: "Games"
    )

    #expect(items.count == 1)
    #expect(!items[0].isActive)
}

@Test func sessionTaskbarKeepsPinnedAppsWithoutInventingRunningState() {
    let prefixPath = "/tmp/SwitchyardTaskbarPrefix"
    let program = InstalledProgram(
        name: "Pinned Launcher",
        executablePath: prefixPath + "/drive_c/Apps/Launcher.exe",
        installDirectory: prefixPath + "/drive_c/Apps",
        source: .programFiles
    )

    let items = SessionStageTaskbarPolicy.makeItems(
        windows: [],
        programs: [program],
        pinnedWindowsPaths: [#"C:\Apps\Launcher.exe"#],
        prefixPath: prefixPath,
        selectedWindowIdentity: nil,
        fallbackName: "Games"
    )

    #expect(items.count == 1)
    #expect(items[0].program == program)
    #expect(items[0].isPinned)
    #expect(!items[0].isRunning)
    #expect(items[0].windows.isEmpty)
}

@Test func sessionTaskbarKeepsUnknownCDriveAppsPinnableAcrossSessions() {
    let prefixPath = "/prefix"
    let runningWindow = WineWindowSnapshot(
        id: 41,
        ownerProcessID: 404,
        title: "Heartopia",
        executablePath: #"C:\Games\Heartopia\Heartopia.exe"#,
        frame: CGRect(x: 10, y: 10, width: 1_280, height: 752),
        isOnScreen: true,
        image: nil
    )

    let runningItems = SessionStageTaskbarPolicy.makeItems(
        windows: [runningWindow],
        programs: [],
        pinnedWindowsPaths: [#"C:\Games\Heartopia\Heartopia.exe"#],
        prefixPath: prefixPath,
        selectedWindowIdentity: SessionStageWindowIdentity(window: runningWindow),
        fallbackName: "Steam"
    )
    #expect(runningItems.count == 1)
    #expect(runningItems[0].isPinned)
    #expect(runningItems[0].isRunning)
    #expect(runningItems[0].program?.executablePath == "/prefix/drive_c/Games/Heartopia/Heartopia.exe")
    #expect(runningItems[0].title == "Heartopia")

    let stoppedItems = SessionStageTaskbarPolicy.makeItems(
        windows: [],
        programs: [],
        pinnedWindowsPaths: [#"C:\Games\Heartopia\Heartopia.exe"#],
        prefixPath: prefixPath,
        selectedWindowIdentity: nil,
        fallbackName: "Steam"
    )
    #expect(stoppedItems.count == 1)
    #expect(stoppedItems[0].isPinned)
    #expect(!stoppedItems[0].isRunning)
    #expect(stoppedItems[0].program?.presentationName == "Heartopia")
}

@Test func sessionTaskbarUsesOwnerProcessAsFallbackWithoutMergingAppsByTitle() {
    let windows = [
        window(id: 1, title: "Same", ownerProcessID: 101),
        window(id: 2, title: "Same", ownerProcessID: 101),
        window(id: 3, title: "Same", ownerProcessID: 202),
    ]

    let items = SessionStageTaskbarPolicy.makeItems(
        windows: windows,
        programs: [],
        pinnedWindowsPaths: [],
        prefixPath: "/tmp/SwitchyardTaskbarPrefix",
        selectedWindowIdentity: nil,
        fallbackName: "Games"
    )

    #expect(items.count == 2)
    #expect(items.map(\.windows.count) == [2, 1])
    #expect(items.allSatisfy { $0.isRunning })
    #expect(items.allSatisfy { !$0.isPinned })
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

@MainActor
@Test func wineWindowFilterKeepsOnlyUserFacingDockWindows() {
    #expect(
        WineWindowCaptureService.isUserFacingWindow(
            isDockProcess: true,
            title: "Heartopia",
            isOnScreen: false
        )
    )
    #expect(
        WineWindowCaptureService.isUserFacingWindow(
            isDockProcess: true,
            title: "wine",
            isOnScreen: true
        )
    )
    #expect(
        !WineWindowCaptureService.isUserFacingWindow(
            isDockProcess: true,
            title: "wine",
            isOnScreen: false
        )
    )
    #expect(
        !WineWindowCaptureService.isUserFacingWindow(
            isDockProcess: true,
            title: "xdt",
            isOnScreen: false
        )
    )
    #expect(
        !WineWindowCaptureService.isUserFacingWindow(
            isDockProcess: false,
            title: "Heartopia",
            isOnScreen: true
        )
    )
}

@MainActor
@Test func wineWindowCloseResolvesOneFreshAccessibilityWindow() async {
    let controller = WineWindowAccessibilityControllerSpy()
    controller.candidates = [
        WineAccessibilityWindowCandidate(
            identifier: 10,
            title: "Heartopia",
            frame: CGRect(x: 900, y: 500, width: 400, height: 300)
        ),
        WineAccessibilityWindowCandidate(
            identifier: 20,
            title: "Heartopia",
            frame: CGRect(x: 2, y: 3, width: 800, height: 600)
        ),
    ]
    let service = WineWindowCaptureService(
        dockProcessIsVisible: { $0 == 1 },
        accessibilityController: controller
    )

    let result = await service.close(
        window(
            id: 1,
            title: "Heartopia",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    )

    #expect(result == .requested)
    #expect(controller.queriedProcessIDs == [1])
    #expect(controller.closedCandidateIDs == [20])
}

@MainActor
@Test func wineWindowCloseRejectsAmbiguousAndWeakMatches() async {
    let snapshot = window(
        id: 1,
        title: "wine",
        frame: CGRect(x: 100, y: 100, width: 500, height: 500)
    )
    let controller = WineWindowAccessibilityControllerSpy()
    let service = WineWindowCaptureService(
        dockProcessIsVisible: { _ in true },
        accessibilityController: controller
    )

    controller.candidates = [
        WineAccessibilityWindowCandidate(
            identifier: 1,
            title: "wine",
            frame: snapshot.frame
        ),
        WineAccessibilityWindowCandidate(
            identifier: 2,
            title: "wine",
            frame: snapshot.frame
        ),
    ]
    #expect(
        WineWindowCaptureService.resolveWindowMatch(
            snapshotTitle: snapshot.title,
            snapshotFrame: snapshot.frame,
            candidates: controller.candidates,
            purpose: .activation
        ) == .matched(identifier: 1)
    )
    #expect(await service.close(snapshot) == .ambiguousWindow)
    #expect(controller.closedCandidateIDs.isEmpty)

    controller.candidates = [
        WineAccessibilityWindowCandidate(
            identifier: 3,
            title: "Other",
            frame: CGRect(x: 2_000, y: 2_000, width: 200, height: 100)
        ),
    ]
    #expect(await service.close(snapshot) == .staleWindow)
    #expect(controller.closedCandidateIDs.isEmpty)
}

@MainActor
@Test func wineWindowCloseReportsPermissionAndUnsupportedCloseButton() async {
    let controller = WineWindowAccessibilityControllerSpy()
    let service = WineWindowCaptureService(
        dockProcessIsVisible: { _ in true },
        accessibilityController: controller
    )
    let snapshot = window(id: 1, title: "Sign In")

    controller.isProcessTrusted = false
    #expect(await service.close(snapshot) == .accessibilityPermissionRequired)
    #expect(controller.queriedProcessIDs.isEmpty)
    #expect(controller.trustRequestCount == 1)

    controller.isProcessTrusted = true
    controller.candidates = [
        WineAccessibilityWindowCandidate(
            identifier: 1,
            title: "Sign In",
            frame: snapshot.frame
        ),
    ]
    controller.closeResult = .closeUnsupported
    #expect(await service.close(snapshot) == .closeUnsupported)
    #expect(controller.closedCandidateIDs == [1])
}

private enum CaptureTestError: Error {
    case expected
}

@MainActor
@Test func captureWindowsSkipsNonDockProcessesBeforeRequestingCapture() async {
    var preflightCount = 0
    var shareableContentWasRequested = false
    let service = WineWindowCaptureService(
        screenRecordingPreflight: {
            preflightCount += 1
            return true
        },
        screenRecordingRequest: { false },
        shareableContentProvider: {
            shareableContentWasRequested = true
            throw CaptureTestError.expected
        },
        dockProcessIsVisible: { _ in false }
    )

    let result = await service.captureWindows(ownedBy: [Int32.max])

    #expect(result.windows.isEmpty)
    #expect(!result.screenRecordingAccessUnavailable)
    #expect(preflightCount == 0)
    #expect(!shareableContentWasRequested)
}

@MainActor
@Test func captureWindowsDoesNotPromptWhileCheckingScreenRecordingAccess() async {
    var requestCount = 0
    var shareableContentWasRequested = false
    let promptGate = ScreenRecordingPermissionPromptGate()
    let service = WineWindowCaptureService(
        screenRecordingPreflight: { false },
        screenRecordingRequest: {
            requestCount += 1
            return false
        },
        screenRecordingPermissionPromptGate: promptGate,
        shareableContentProvider: {
            shareableContentWasRequested = true
            throw CaptureTestError.expected
        },
        dockProcessIsVisible: { _ in true }
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
    #expect(requestCount == 0)
    #expect(!shareableContentWasRequested)
}

@MainActor
@Test func explicitScreenRecordingActionSharesPromptGateAcrossStageModels() {
    var requestCount = 0
    var settingsOpenCount = 0
    let promptGate = ScreenRecordingPermissionPromptGate()

    func makeService() -> WineWindowCaptureService {
        WineWindowCaptureService(
            screenRecordingPreflight: { false },
            screenRecordingRequest: {
                requestCount += 1
                return false
            },
            screenRecordingPermissionPromptGate: promptGate,
            screenRecordingSettingsOpener: {
                settingsOpenCount += 1
            },
            shareableContentProvider: {
                throw CaptureTestError.expected
            },
            dockProcessIsVisible: { _ in true }
        )
    }

    makeService().requestScreenRecordingAccess()
    makeService().requestScreenRecordingAccess()

    #expect(requestCount == 1)
    #expect(settingsOpenCount == 2)
}

@MainActor
@Test func explicitScreenRecordingActionDoesNothingWhenAccessIsAvailable() {
    var requestCount = 0
    var settingsOpenCount = 0
    let service = WineWindowCaptureService(
        screenRecordingPreflight: { true },
        screenRecordingRequest: {
            requestCount += 1
            return true
        },
        screenRecordingPermissionPromptGate:
            ScreenRecordingPermissionPromptGate(),
        screenRecordingSettingsOpener: {
            settingsOpenCount += 1
        },
        dockProcessIsVisible: { _ in true }
    )

    service.requestScreenRecordingAccess()

    #expect(requestCount == 0)
    #expect(settingsOpenCount == 0)
}

@MainActor
@Test func captureWindowsDoesNotPromptForSettingsForShareableContentErrors() async {
    let service = WineWindowCaptureService(
        screenRecordingPreflight: { true },
        screenRecordingRequest: { false },
        shareableContentProvider: {
            throw CaptureTestError.expected
        },
        dockProcessIsVisible: { _ in true }
    )

    let result = await service.captureWindows(
        ownedBy: [Int32.max]
    )

    #expect(!result.screenRecordingAccessUnavailable)
    #expect(result.message == nil)
}

private final class WineWindowAccessibilityControllerSpy:
    WineWindowAccessibilityControlling, @unchecked Sendable
{
    var isProcessTrusted = true
    var candidates: [WineAccessibilityWindowCandidate] = []
    var closeResult: WineWindowCloseResult = .requested
    private(set) var queriedProcessIDs: [pid_t] = []
    private(set) var raisedCandidateIDs: [Int] = []
    private(set) var closedCandidateIDs: [Int] = []
    private(set) var trustRequestCount = 0

    func requestProcessTrust() {
        trustRequestCount += 1
    }

    func windows(for processID: pid_t) -> [WineAccessibilityWindowCandidate]? {
        queriedProcessIDs.append(processID)
        return candidates
    }

    func raise(_ candidate: WineAccessibilityWindowCandidate) {
        raisedCandidateIDs.append(candidate.identifier)
    }

    func close(
        _ candidate: WineAccessibilityWindowCandidate
    ) -> WineWindowCloseResult {
        closedCandidateIDs.append(candidate.identifier)
        return closeResult
    }
}
