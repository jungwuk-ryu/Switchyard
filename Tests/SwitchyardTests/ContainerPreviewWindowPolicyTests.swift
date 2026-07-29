import CoreGraphics
import Testing
@testable import Switchyard

@Test func containerPreviewWindowPolicySkipsWineInfrastructureWindows() throws {
    let image = try makePreviewPolicyTestImage()
    let wineConfigurationWindow = WineWindowSnapshot(
        id: 10,
        ownerProcessID: 101,
        title: "Wine",
        executablePath: #"C:\windows\system32\wineboot.exe"#,
        frame: CGRect(x: 20, y: 20, width: 480, height: 260),
        isOnScreen: true,
        image: image
    )
    let applicationWindow = WineWindowSnapshot(
        id: 20,
        ownerProcessID: 202,
        title: "Battle.net",
        executablePath: #"C:\Program Files (x86)\Battle.net\Battle.net.exe"#,
        frame: CGRect(x: 40, y: 40, width: 1_080, height: 720),
        isOnScreen: true,
        image: image
    )

    let preferredWindow = ContainerPreviewWindowPolicy.preferredWindow(
        in: [wineConfigurationWindow, applicationWindow],
        selectedWindowID: wineConfigurationWindow.id
    )
    #expect(preferredWindow?.id == applicationWindow.id)
}

@Test func containerPreviewWindowPolicyPrefersSelectedApplicationWindow() throws {
    let image = try makePreviewPolicyTestImage()
    let firstWindow = WineWindowSnapshot(
        id: 30,
        ownerProcessID: 303,
        title: "Launcher",
        executablePath: #"C:\Games\Launcher.exe"#,
        frame: CGRect(x: 20, y: 20, width: 800, height: 500),
        isOnScreen: true,
        image: image
    )
    let selectedWindow = WineWindowSnapshot(
        id: 40,
        ownerProcessID: 303,
        title: "",
        executablePath: #"C:\Games\Game.exe"#,
        frame: CGRect(x: 60, y: 60, width: 1_280, height: 720),
        isOnScreen: true,
        image: image
    )

    let preferredWindow = ContainerPreviewWindowPolicy.preferredWindow(
        in: [firstWindow, selectedWindow],
        selectedWindowID: selectedWindow.id
    )
    #expect(preferredWindow?.id == selectedWindow.id)
}

@Test func containerPreviewWindowPolicyRequestsAnUncapturedApplicationWindow() throws {
    let image = try makePreviewPolicyTestImage()
    let capturedInfrastructureWindow = WineWindowSnapshot(
        id: 50,
        ownerProcessID: 505,
        title: "Wine",
        executablePath: #"C:\windows\system32\winecfg.exe"#,
        frame: CGRect(x: 20, y: 20, width: 480, height: 260),
        isOnScreen: true,
        image: image
    )
    let uncapturedApplicationWindow = WineWindowSnapshot(
        id: 60,
        ownerProcessID: 606,
        title: "Launcher",
        executablePath: #"C:\Games\Launcher.exe"#,
        frame: CGRect(x: 40, y: 40, width: 1_080, height: 720),
        isOnScreen: true,
        image: nil
    )

    let windows = [
        capturedInfrastructureWindow,
        uncapturedApplicationWindow,
    ]
    #expect(
        ContainerPreviewWindowPolicy.preferredWindow(in: windows) == nil
    )
    #expect(
        ContainerPreviewWindowPolicy.preferredWindowCandidate(in: windows)?.id
            == uncapturedApplicationWindow.id
    )
}

private func makePreviewPolicyTestImage() throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 8,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        throw ContainerPreviewWindowPolicyTestError.imageUnavailable
    }
    return image
}

private enum ContainerPreviewWindowPolicyTestError: Error {
    case imageUnavailable
}
