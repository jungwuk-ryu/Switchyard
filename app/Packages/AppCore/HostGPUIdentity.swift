import Foundation

public enum HostGPUIdentityError: Error, Equatable, Hashable, Sendable {
    case invalidUTF8
    case invalidLineTermination
    case invalidLineCount
    case recordTooLarge
    case invalidFieldCount
    case invalidHexField(Int)
    case zeroVendorID
    case zeroDeviceID
    case invalidDescription
}

/// A validated host GPU identity in the format consumed by the GPTK policy.
public struct HostGPUIdentity: Codable, Equatable, Hashable, Sendable {
    public static let maximumDescriptionUTF8Bytes = 255
    public static let maximumCanonicalTSVBytes =
        (4 * 8) + 4 + maximumDescriptionUTF8Bytes + 1

    public let vendorID: UInt32
    public let deviceID: UInt32
    public let subsystemID: UInt32
    public let revisionID: UInt32
    public let description: String

    public init(
        vendorID: UInt32,
        deviceID: UInt32,
        subsystemID: UInt32,
        revisionID: UInt32,
        description: String
    ) throws {
        guard vendorID != 0 else {
            throw HostGPUIdentityError.zeroVendorID
        }
        guard deviceID != 0 else {
            throw HostGPUIdentityError.zeroDeviceID
        }
        guard Self.isValidDescription(description) else {
            throw HostGPUIdentityError.invalidDescription
        }

        self.vendorID = vendorID
        self.deviceID = deviceID
        self.subsystemID = subsystemID
        self.revisionID = revisionID
        self.description = description
    }

    /// Parses one canonical, LF-terminated TSV record.
    public init(tsvData: Data) throws {
        self = try Self.parseTSV(tsvData)
    }

    /// Parses one canonical, LF-terminated TSV record.
    public static func parseTSV(_ data: Data) throws -> Self {
        guard data.count <= maximumCanonicalTSVBytes else {
            throw HostGPUIdentityError.recordTooLarge
        }
        guard data.last == 0x0A else {
            throw HostGPUIdentityError.invalidLineTermination
        }

        let lineBytes = data.dropLast()
        guard !lineBytes.contains(0x0A), !lineBytes.contains(0x0D) else {
            throw HostGPUIdentityError.invalidLineCount
        }
        guard let line = String(data: Data(lineBytes), encoding: .utf8) else {
            throw HostGPUIdentityError.invalidUTF8
        }

        let fields = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        )
        guard fields.count == 5 else {
            throw HostGPUIdentityError.invalidFieldCount
        }

        let identifiers = try fields.prefix(4).enumerated().map { index, field in
            try parseIdentifier(field, fieldIndex: index)
        }

        return try Self(
            vendorID: identifiers[0],
            deviceID: identifiers[1],
            subsystemID: identifiers[2],
            revisionID: identifiers[3],
            description: String(fields[4])
        )
    }

    public static func parseTSV(_ contents: String) throws -> Self {
        try parseTSV(Data(contents.utf8))
    }

    /// Canonical TSV without its record terminator.
    public var canonicalTSVLine: String {
        [
            Self.canonicalHex(vendorID),
            Self.canonicalHex(deviceID),
            Self.canonicalHex(subsystemID),
            Self.canonicalHex(revisionID),
            description,
        ].joined(separator: "\t")
    }

    /// Canonical TSV containing exactly one LF-terminated record.
    public var canonicalTSV: String {
        canonicalTSVLine + "\n"
    }

    public var canonicalTSVData: Data {
        Data(canonicalTSV.utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case vendorID
        case deviceID
        case subsystemID
        case revisionID
        case description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                vendorID: container.decode(UInt32.self, forKey: .vendorID),
                deviceID: container.decode(UInt32.self, forKey: .deviceID),
                subsystemID: container.decode(UInt32.self, forKey: .subsystemID),
                revisionID: container.decode(UInt32.self, forKey: .revisionID),
                description: container.decode(String.self, forKey: .description)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid host GPU identity.",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendorID, forKey: .vendorID)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(subsystemID, forKey: .subsystemID)
        try container.encode(revisionID, forKey: .revisionID)
        try container.encode(description, forKey: .description)
    }

    private static func parseIdentifier(
        _ field: Substring,
        fieldIndex: Int
    ) throws -> UInt32 {
        let bytes = field.utf8
        guard bytes.count == 8,
              bytes.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }),
              let value = UInt32(field, radix: 16) else {
            throw HostGPUIdentityError.invalidHexField(fieldIndex)
        }
        return value
    }

    private static func canonicalHex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }

    private static func isValidDescription(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumDescriptionUTF8Bytes else {
            return false
        }

        return value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            return !(codePoint <= 0x1F
                || codePoint == 0x7F
                || codePoint == 0x85
                || codePoint == 0x2028
                || codePoint == 0x2029)
        }
    }
}

public enum RuntimeGPUIdentityEvidenceError: Error, Equatable, Hashable, Sendable {
    case invalidCanonicalPath
    case invalidSHA256
    case invalidRuntimeID
    case invalidRuntimeRoot
    case invalidRuntimeContentFingerprint
    case invalidOperatingSystemBuild
    case zeroDefaultGPURegistryID
}

/// Immutable file identity used both for cache invalidation and launch-time revalidation.
public struct RuntimeGPUIdentityFileEvidence: Codable, Equatable, Hashable, Sendable {
    public let canonicalPath: String
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modificationTimeNanoseconds: Int64
    public let mode: UInt32
    public let sha256: String

    public init(
        canonicalPath: String,
        device: UInt64,
        inode: UInt64,
        size: UInt64,
        modificationTimeNanoseconds: Int64,
        mode: UInt32,
        sha256: String
    ) throws {
        guard GPUIdentityValueValidation.isCanonicalAbsolutePath(canonicalPath) else {
            throw RuntimeGPUIdentityEvidenceError.invalidCanonicalPath
        }
        guard GPUIdentityValueValidation.isLowercaseSHA256(sha256) else {
            throw RuntimeGPUIdentityEvidenceError.invalidSHA256
        }

        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.mode = mode
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalPath
        case device
        case inode
        case size
        case modificationTimeNanoseconds
        case mode
        case sha256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                canonicalPath: container.decode(String.self, forKey: .canonicalPath),
                device: container.decode(UInt64.self, forKey: .device),
                inode: container.decode(UInt64.self, forKey: .inode),
                size: container.decode(UInt64.self, forKey: .size),
                modificationTimeNanoseconds: container.decode(
                    Int64.self,
                    forKey: .modificationTimeNanoseconds
                ),
                mode: container.decode(UInt32.self, forKey: .mode),
                sha256: container.decode(String.self, forKey: .sha256)
            )
        } catch {
            throw GPUIdentityValueValidation.decodingError(
                decoder: decoder,
                description: "Invalid runtime GPU identity file evidence.",
                underlyingError: error
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalPath, forKey: .canonicalPath)
        try container.encode(device, forKey: .device)
        try container.encode(inode, forKey: .inode)
        try container.encode(size, forKey: .size)
        try container.encode(
            modificationTimeNanoseconds,
            forKey: .modificationTimeNanoseconds
        )
        try container.encode(mode, forKey: .mode)
        try container.encode(sha256, forKey: .sha256)
    }
}

/// Runtime inputs that can change the GPTK GPU identity helper's result.
public struct RuntimeGPUIdentityEvidence: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: String
    public let runtimeRoot: String
    public let runtimeContentFingerprint: String
    public let helper: RuntimeGPUIdentityFileEvidence
    public let policy: RuntimeGPUIdentityFileEvidence

    public init(
        runtimeID: String,
        runtimeRoot: String,
        runtimeContentFingerprint: String,
        helper: RuntimeGPUIdentityFileEvidence,
        policy: RuntimeGPUIdentityFileEvidence
    ) throws {
        guard GPUIdentityValueValidation.isControlFreeNonempty(runtimeID) else {
            throw RuntimeGPUIdentityEvidenceError.invalidRuntimeID
        }
        guard GPUIdentityValueValidation.isCanonicalAbsolutePath(runtimeRoot) else {
            throw RuntimeGPUIdentityEvidenceError.invalidRuntimeRoot
        }
        guard GPUIdentityValueValidation.isControlFreeNonempty(
            runtimeContentFingerprint
        ) else {
            throw RuntimeGPUIdentityEvidenceError.invalidRuntimeContentFingerprint
        }

        self.runtimeID = runtimeID
        self.runtimeRoot = runtimeRoot
        self.runtimeContentFingerprint = runtimeContentFingerprint
        self.helper = helper
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeID
        case runtimeRoot
        case runtimeContentFingerprint
        case helper
        case policy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                runtimeID: container.decode(String.self, forKey: .runtimeID),
                runtimeRoot: container.decode(String.self, forKey: .runtimeRoot),
                runtimeContentFingerprint: container.decode(
                    String.self,
                    forKey: .runtimeContentFingerprint
                ),
                helper: container.decode(
                    RuntimeGPUIdentityFileEvidence.self,
                    forKey: .helper
                ),
                policy: container.decode(
                    RuntimeGPUIdentityFileEvidence.self,
                    forKey: .policy
                )
            )
        } catch {
            throw GPUIdentityValueValidation.decodingError(
                decoder: decoder,
                description: "Invalid runtime GPU identity evidence.",
                underlyingError: error
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeID, forKey: .runtimeID)
        try container.encode(runtimeRoot, forKey: .runtimeRoot)
        try container.encode(
            runtimeContentFingerprint,
            forKey: .runtimeContentFingerprint
        )
        try container.encode(helper, forKey: .helper)
        try container.encode(policy, forKey: .policy)
    }
}

public struct GPTKGPUIdentityCacheKey: Codable, Equatable, Hashable, Sendable {
    public let operatingSystemBuild: String
    public let defaultGPURegistryID: UInt64
    public let runtime: RuntimeGPUIdentityEvidence

    public init(
        operatingSystemBuild: String,
        defaultGPURegistryID: UInt64,
        runtime: RuntimeGPUIdentityEvidence
    ) throws {
        guard GPUIdentityValueValidation.isControlFreeNonempty(
            operatingSystemBuild
        ) else {
            throw RuntimeGPUIdentityEvidenceError.invalidOperatingSystemBuild
        }
        guard defaultGPURegistryID != 0 else {
            throw RuntimeGPUIdentityEvidenceError.zeroDefaultGPURegistryID
        }

        self.operatingSystemBuild = operatingSystemBuild
        self.defaultGPURegistryID = defaultGPURegistryID
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case operatingSystemBuild
        case defaultGPURegistryID
        case runtime
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                operatingSystemBuild: container.decode(
                    String.self,
                    forKey: .operatingSystemBuild
                ),
                defaultGPURegistryID: container.decode(
                    UInt64.self,
                    forKey: .defaultGPURegistryID
                ),
                runtime: container.decode(
                    RuntimeGPUIdentityEvidence.self,
                    forKey: .runtime
                )
            )
        } catch {
            throw GPUIdentityValueValidation.decodingError(
                decoder: decoder,
                description: "Invalid GPTK GPU identity cache key.",
                underlyingError: error
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operatingSystemBuild, forKey: .operatingSystemBuild)
        try container.encode(defaultGPURegistryID, forKey: .defaultGPURegistryID)
        try container.encode(runtime, forKey: .runtime)
    }
}

public struct GPTKGPUIdentitySnapshot: Codable, Equatable, Hashable, Sendable {
    public let cacheKey: GPTKGPUIdentityCacheKey
    public let identity: HostGPUIdentity

    public init(
        cacheKey: GPTKGPUIdentityCacheKey,
        identity: HostGPUIdentity
    ) {
        self.cacheKey = cacheKey
        self.identity = identity
    }
}

private enum GPUIdentityValueValidation {
    static func isControlFreeNonempty(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            let codePoint = scalar.value
            return codePoint > 0x1F
                && codePoint != 0x7F
                && codePoint != 0x85
                && codePoint != 0x2028
                && codePoint != 0x2029
        }
    }

    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path != "/",
              path.first == "/",
              isControlFreeNonempty(path) else {
            return false
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    static func decodingError(
        decoder: any Decoder,
        description: String,
        underlyingError: any Error
    ) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: description,
                underlyingError: underlyingError
            )
        )
    }
}
