import AppCore
import Foundation
import Testing
@testable import Switchyard

@Test func advancedEnvironmentOptionsUseAllowedRuntimeKeys() {
    for option in ContainerAdvancedEnvironmentOption.allCases {
        #expect(EnvironmentOverridePolicy.isAllowedKey(option.environmentKey))
    }
    #expect(
        EnvironmentOverridePolicy.isAllowedKey(
            RosettaAVXAdvertisingPolicy.environmentKey
        )
    )
    #expect(
        EnvironmentOverridePolicy.isAllowedKey(
            D3DMetalFrameRateLimitPolicy.environmentKey
        )
    )
    #expect(
        D3DMetalFrameRateLimitPolicy.presetValues.allSatisfy {
            Int($0).map { $0 > 0 } == true
                && D3DMetalFrameRateLimitPolicy.isValidPreset($0)
        }
    )
    #expect(!D3DMetalFrameRateLimitPolicy.isValidPreset("0"))
    #expect(!D3DMetalFrameRateLimitPolicy.isValidPreset("uncapped"))
}

@Test func advancedEnvironmentOptionChangesOnlyItsOwnedValue() {
    let original = [
        "CUSTOM_SETTING": "keep-me",
        "D3DM_SUPPORT_DXR": "custom"
    ]
    let option = ContainerAdvancedEnvironmentOption.forceDirectXRaytracing

    #expect(option.applying(false, to: original) == original)

    let enabled = option.applying(true, to: original)
    #expect(enabled["CUSTOM_SETTING"] == "keep-me")
    #expect(enabled["D3DM_SUPPORT_DXR"] == "1")

    let disabled = option.applying(false, to: enabled)
    #expect(disabled == ["CUSTOM_SETTING": "keep-me"])
}

@Test func d3dMetalCapabilitiesReadFrameworkVersion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let resources = root
        .appendingPathComponent("redist/lib/external", isDirectory: true)
        .appendingPathComponent("D3DMetal.framework/Versions/A/Resources", isDirectory: true)
    try FileManager.default.createDirectory(
        at: resources,
        withIntermediateDirectories: true
    )
    let versionData = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": "4.0b1"],
        format: .xml,
        options: 0
    )
    try versionData.write(to: resources.appendingPathComponent("version.plist"))

    let capabilities = D3DMetalAdvancedSettingCapabilities.inspect(
        gptkRootPath: root.path
    )

    #expect(capabilities.majorVersion == 4)
    #expect(capabilities.supportsD3DMetalSettings)
    #expect(capabilities.supportsFrameRateLimit)
}

@Test func unknownD3dMetalVersionDoesNotEnableVersionedOptions() {
    let capabilities = D3DMetalAdvancedSettingCapabilities.inspect(
        gptkRootPath: "/path/that/does/not/exist"
    )

    #expect(capabilities.majorVersion == nil)
    #expect(!capabilities.supportsD3DMetalSettings)
    #expect(!capabilities.supportsFrameRateLimit)
}
