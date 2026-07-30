import Foundation
import Testing
@testable import AppCore

@Test func rosettaAVXAdvertisingUsesTheSupportedHostMatrix() {
    let cases: [(isAppleSilicon: Bool, macOSMajorVersion: Int, isSupported: Bool)] = [
        (true, 14, false),
        (true, 15, true),
        (true, 26, true),
        (false, 14, false),
        (false, 15, false),
        (false, 26, false)
    ]

    for item in cases {
        let policy = RosettaAVXAdvertisingPolicy(
            isAppleSiliconHost: item.isAppleSilicon,
            macOSMajorVersion: item.macOSMajorVersion
        )
        #expect(policy.isSupported == item.isSupported)
    }
}

@Test func rosettaAVXAdvertisingDefaultsOnAndPreservesExplicitOff() {
    let policy = RosettaAVXAdvertisingPolicy(
        isAppleSiliconHost: true,
        macOSMajorVersion: 15
    )
    let original = ["CUSTOM_SETTING": "keep-me"]

    #expect(policy.isEnabled(in: original))
    let automatic = policy.resolving(original)
    #expect(automatic["CUSTOM_SETTING"] == "keep-me")
    #expect(
        automatic[RosettaAVXAdvertisingPolicy.environmentKey] == "1"
    )

    let disabled = policy.applying(false, to: original)
    #expect(
        disabled[RosettaAVXAdvertisingPolicy.environmentKey] == "0"
    )
    #expect(!policy.isEnabled(in: disabled))
    #expect(
        policy.resolving(disabled)[RosettaAVXAdvertisingPolicy.environmentKey]
            == "0"
    )

    let enabled = policy.applying(true, to: disabled)
    #expect(policy.isEnabled(in: enabled))
    #expect(
        enabled[RosettaAVXAdvertisingPolicy.environmentKey] == "1"
    )
}

@Test func rosettaAVXAdvertisingFailsClosedOnUnsupportedHostsAndUnknownValues() {
    let unsupportedPolicy = RosettaAVXAdvertisingPolicy(
        isAppleSiliconHost: true,
        macOSMajorVersion: 14
    )
    let explicitlyEnabled = [
        RosettaAVXAdvertisingPolicy.environmentKey: "1"
    ]

    #expect(!unsupportedPolicy.isEnabled(in: explicitlyEnabled))
    #expect(
        unsupportedPolicy.resolving(explicitlyEnabled)[
            RosettaAVXAdvertisingPolicy.environmentKey
        ] == "0"
    )

    let supportedPolicy = RosettaAVXAdvertisingPolicy(
        isAppleSiliconHost: true,
        macOSMajorVersion: 15
    )
    let unknownValue = [
        RosettaAVXAdvertisingPolicy.environmentKey: "unexpected"
    ]
    #expect(!supportedPolicy.isEnabled(in: unknownValue))
    #expect(
        supportedPolicy.resolving(unknownValue)[
            RosettaAVXAdvertisingPolicy.environmentKey
        ] == "0"
    )
}

@Test func legacyRoutesDecodeWithAutomaticRosettaAVXAdvertising() throws {
    let routeData = Data(
        """
        {
          "id": "\(String(repeating: "a", count: 64))",
          "containerID": "00000000-0000-0000-0000-000000000001",
          "prefixPath": "/tmp/Test.container",
          "winePath": "/opt/wine/bin/wine",
          "runnerPath": "/Applications/Switchyard.app/Contents/Helpers/switchyard-runner",
          "windowsShortcutPath": "C:\\\\users\\\\steamuser\\\\Desktop\\\\Game.lnk"
        }
        """.utf8
    )

    let route = try JSONDecoder().decode(
        WineDesktopShortcutRoute.self,
        from: routeData
    )
    #expect(route.rosettaAVXAdvertisingPreference == nil)
}
