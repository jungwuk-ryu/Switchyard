public enum RosettaAVXAdvertisingPreference: String, Codable, Equatable, Sendable {
    case automatic
    case enabled
    case disabled

    public init(environmentValue: String?) {
        switch environmentValue {
        case nil:
            self = .automatic
        case "1":
            self = .enabled
        default:
            self = .disabled
        }
    }

    public var explicitEnvironmentValue: String? {
        switch self {
        case .automatic:
            nil
        case .enabled:
            "1"
        case .disabled:
            "0"
        }
    }
}

public struct RosettaAVXAdvertisingPolicy: Equatable, Sendable {
    public static let environmentKey = "ROSETTA_ADVERTISE_AVX"
    public static let minimumMacOSMajorVersion = 15

    public let isAppleSiliconHost: Bool
    public let macOSMajorVersion: Int

    public init(isAppleSiliconHost: Bool, macOSMajorVersion: Int) {
        self.isAppleSiliconHost = isAppleSiliconHost
        self.macOSMajorVersion = macOSMajorVersion
    }

    public var isSupported: Bool {
        isAppleSiliconHost && macOSMajorVersion >= Self.minimumMacOSMajorVersion
    }

    public func preference(in environment: [String: String]) -> RosettaAVXAdvertisingPreference {
        RosettaAVXAdvertisingPreference(
            environmentValue: environment[Self.environmentKey]
        )
    }

    public static func explicitPreference(
        in environment: [String: String]
    ) -> RosettaAVXAdvertisingPreference? {
        guard let value = environment[Self.environmentKey] else {
            return nil
        }
        return RosettaAVXAdvertisingPreference(environmentValue: value)
    }

    public func isEnabled(in environment: [String: String]) -> Bool {
        isSupported && preference(in: environment) != .disabled
    }

    public func applying(
        _ isEnabled: Bool,
        to environment: [String: String]
    ) -> [String: String] {
        var updated = environment
        updated[Self.environmentKey] = isEnabled ? "1" : "0"
        return updated
    }

    public func resolving(
        _ environment: [String: String],
        preference explicitPreference: RosettaAVXAdvertisingPreference? = nil
    ) -> [String: String] {
        let effectivePreference = explicitPreference ?? preference(in: environment)
        var resolved = environment
        resolved[Self.environmentKey] =
            isSupported && effectivePreference != .disabled ? "1" : "0"
        return resolved
    }
}
