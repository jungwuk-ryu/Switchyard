import AppCore
import CoreGraphics
import Foundation
import Testing
@testable import Switchyard

@Test func sessionStagePreviewCentersLandscapeImagesWithoutCropping() {
    let frame = SessionStageWindowPreviewLayout.fittedFrame(
        sourceSize: CGSize(width: 1_600, height: 900),
        availableSize: CGSize(width: 400, height: 400)
    )

    #expect(frame == CGRect(x: 0, y: 87.5, width: 400, height: 225))
}

@Test func sessionStagePreviewCentersPortraitImagesWithoutCropping() {
    let frame = SessionStageWindowPreviewLayout.fittedFrame(
        sourceSize: CGSize(width: 900, height: 1_600),
        availableSize: CGSize(width: 400, height: 240)
    )

    #expect(frame == CGRect(x: 132.5, y: 0, width: 135, height: 240))
}

@Test func sessionStagePreviewRejectsInvalidGeometry() {
    #expect(
        SessionStageWindowPreviewLayout.fittedFrame(
            sourceSize: .zero,
            availableSize: CGSize(width: 400, height: 240)
        ) == .zero
    )
    #expect(
        SessionStageWindowPreviewLayout.fittedFrame(
            sourceSize: CGSize(width: 400, height: 240),
            availableSize: CGSize(width: CGFloat.infinity, height: 240)
        ) == .zero
    )
}

@Test func runningTaskbarItemUsesCapturedDockIconForSyntheticPrograms() {
    let iconData = Data([0x53, 0x59])
    let snapshot = WineWindowSnapshot(
        id: 41,
        ownerProcessID: 404,
        title: "Heartopia",
        executablePath: #"C:\Games\Heartopia\Heartopia.exe"#,
        frame: CGRect(x: 10, y: 10, width: 1_280, height: 752),
        isOnScreen: true,
        image: nil,
        applicationIconData: iconData
    )

    let items = SessionStageTaskbarPolicy.makeItems(
        windows: [snapshot],
        programs: [],
        pinnedWindowsPaths: [],
        prefixPath: "/prefix",
        selectedWindowID: snapshot.id,
        fallbackName: "Steam"
    )

    #expect(items.count == 1)
    #expect(items[0].program?.presentationName == "Heartopia")
    #expect(items[0].applicationIconData == iconData)
}

@Test func taskbarIconFallsThroughWindowsUntilCapturedIconIsAvailable() {
    let iconData = Data([0x49, 0x43, 0x4f, 0x4e])
    let windows = [
        WineWindowSnapshot(
            id: 1,
            ownerProcessID: 100,
            title: "First",
            executablePath: #"C:\Game.exe"#,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true,
            image: nil
        ),
        WineWindowSnapshot(
            id: 2,
            ownerProcessID: 100,
            title: "Second",
            executablePath: #"C:\Game.exe"#,
            frame: CGRect(x: 20, y: 20, width: 800, height: 600),
            isOnScreen: true,
            image: nil,
            applicationIconData: iconData
        ),
    ]
    let item = SessionStageTaskbarItem(
        id: "running",
        title: "Game",
        program: nil,
        windows: windows,
        isPinned: false,
        isRunning: true,
        isActive: true
    )

    #expect(item.applicationIconData == iconData)
}

@MainActor
@Test func wineApplicationIconCacheRefreshesAfterWineChangesItsDockIcon() {
    let genericExecIcon = Data([0x45, 0x58, 0x45])
    let heartopiaIcon = Data([0x48, 0x45, 0x41, 0x52, 0x54])
    var currentIcon = genericExecIcon
    var currentDate = Date(timeIntervalSince1970: 100)
    var providerCallCount = 0
    let service = WineWindowCaptureService(
        applicationIconDataProvider: { _ in
            providerCallCount += 1
            return currentIcon
        },
        applicationIconCacheLifetime: 4,
        now: { currentDate }
    )

    #expect(service.applicationIconData(processID: 42) == genericExecIcon)

    currentIcon = heartopiaIcon
    currentDate.addTimeInterval(3)
    #expect(service.applicationIconData(processID: 42) == genericExecIcon)
    #expect(providerCallCount == 1)

    currentDate.addTimeInterval(2)
    #expect(service.applicationIconData(processID: 42) == heartopiaIcon)
    #expect(providerCallCount == 2)
}
