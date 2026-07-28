import AppCore
import CoreGraphics
import Foundation
import ScreenCaptureKit
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

@MainActor
@Test func windowPreviewCaptureExcludesAsymmetricWindowShadowPadding() {
    let configuration = WineWindowCaptureService.screenshotConfiguration(
        sourceSize: CGSize(width: 1_280, height: 752)
    )

    #expect(configuration.width == 1_120)
    #expect(configuration.height == 658)
    #expect(configuration.scalesToFit)
    #expect(configuration.preservesAspectRatio)
    #expect(configuration.ignoreShadowsSingleWindow)
    #expect(configuration.ignoreGlobalClipSingleWindow)
}

@Test func runningTaskbarItemPrefersItsWindowsExecutableForIcons() {
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
    #expect(
        items[0].iconExecutablePath
            == "/prefix/drive_c/Games/Heartopia/Heartopia.exe"
    )
    #expect(items[0].applicationIconData == iconData)
}

@Test func taskbarDoesNotRemapGuestExecutableThroughTheZDrive() throws {
    let prefixURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SwitchyardTaskbar-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: prefixURL) }
    let driveCURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
    let dosDevicesURL = prefixURL.appendingPathComponent(
        "dosdevices",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: driveCURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: dosDevicesURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: dosDevicesURL.appendingPathComponent("z:"),
        withDestinationURL: URL(fileURLWithPath: "/", isDirectory: true)
    )
    let guestPath =
        #"C:\Program Files\Rockstar Games\Social Club\SocialClubHelper.exe"#
    let snapshot = WineWindowSnapshot(
        id: 42,
        ownerProcessID: 405,
        title: "Rockstar Games Launcher",
        executablePath: guestPath,
        frame: CGRect(x: 10, y: 10, width: 1_280, height: 752),
        isOnScreen: true,
        image: nil
    )

    let item = try #require(
        SessionStageTaskbarPolicy.makeItems(
            windows: [snapshot],
            programs: [],
            pinnedWindowsPaths: [],
            prefixPath: prefixURL.path,
            selectedWindowID: snapshot.id,
            fallbackName: "Rockstar"
        ).first
    )

    #expect(
        item.iconExecutablePath
            == driveCURL
                .appendingPathComponent(
                    "Program Files/Rockstar Games/Social Club/SocialClubHelper.exe"
                )
                .path
    )
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
        iconExecutablePath: nil,
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
