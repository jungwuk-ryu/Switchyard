import AppCore
import Foundation

enum ContainerAdvancedEnvironmentOption: CaseIterable {
    case d3dMetalStatistics
    case forceDirectXRaytracing
    case advertiseRosettaAVX
    case legacyAddressSpace
    case wineDiagnostics

    var environmentKey: String {
        switch self {
        case .d3dMetalStatistics:
            "D3DM_SHOW_HUD_STATS"
        case .forceDirectXRaytracing:
            "D3DM_SUPPORT_DXR"
        case .advertiseRosettaAVX:
            "ROSETTA_ADVERTISE_AVX"
        case .legacyAddressSpace:
            "WINE_LARGE_ADDRESS_AWARE"
        case .wineDiagnostics:
            "WINEDEBUG"
        }
    }

    var enabledValue: String {
        switch self {
        case .d3dMetalStatistics, .forceDirectXRaytracing, .advertiseRosettaAVX:
            "1"
        case .legacyAddressSpace:
            "0"
        case .wineDiagnostics:
            "-all,+timestamp,err+all,warn+all"
        }
    }

    func isEnabled(in overrides: [String: String]) -> Bool {
        overrides[environmentKey] == enabledValue
    }

    func applying(
        _ isEnabled: Bool,
        to overrides: [String: String]
    ) -> [String: String] {
        var updated = overrides
        if isEnabled {
            updated[environmentKey] = enabledValue
        } else if updated[environmentKey] == enabledValue {
            updated.removeValue(forKey: environmentKey)
        }
        return updated
    }
}

struct D3DMetalAdvancedSettingCapabilities: Equatable, Sendable {
    let majorVersion: Int?

    var supportsD3DMetalSettings: Bool {
        majorVersion != nil
    }

    var supportsFrameRateLimit: Bool {
        guard let majorVersion else { return false }
        return majorVersion >= 4
    }

    static func inspect(gptkRootPath: String) -> Self {
        let rootURL = URL(fileURLWithPath: gptkRootPath, isDirectory: true)
        let candidates = [
            rootURL
                .appendingPathComponent("redist/lib/external", isDirectory: true)
                .appendingPathComponent("D3DMetal.framework", isDirectory: true),
            rootURL
                .appendingPathComponent("lib/external", isDirectory: true)
                .appendingPathComponent("D3DMetal.framework", isDirectory: true),
            rootURL.appendingPathComponent("D3DMetal.framework", isDirectory: true)
        ]

        for frameworkURL in candidates {
            let versionURL = frameworkURL
                .appendingPathComponent("Versions/A/Resources", isDirectory: true)
                .appendingPathComponent("version.plist")
            guard let data = try? Data(contentsOf: versionURL),
                  let propertyList = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ),
                  let values = propertyList as? [String: Any],
                  let version = values["CFBundleShortVersionString"] as? String,
                  let majorVersion = parseMajorVersion(version) else {
                continue
            }
            return Self(majorVersion: majorVersion)
        }

        return Self(majorVersion: nil)
    }

    private static func parseMajorVersion(_ version: String) -> Int? {
        let digits = version.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

enum D3DMetalFrameRateLimitPolicy {
    static let environmentKey = "D3DM_MAX_FPS"
    static let presetValues = ["30", "60", "90", "120", "144"]

    static func isValidPreset(_ value: String) -> Bool {
        presetValues.contains(value)
    }
}
