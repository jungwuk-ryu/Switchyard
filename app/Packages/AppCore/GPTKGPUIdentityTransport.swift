import CryptoKit
import Foundation

public enum GPTKGPUIdentityTransportError:
    Error,
    Equatable,
    Sendable
{
    case encodedIdentityTooLarge
    case invalidBase64
    case noncanonicalBase64
    case invalidIdentity(HostGPUIdentityError)
}

/// Private runner-to-runtime transport for one already validated GPU identity.
///
/// The public helper key is removed from inherited and plan environments before
/// every launch. Keys under `privateEnvironmentKeyPrefix` are runner-internal
/// and must never be accepted from a caller.
public enum GPTKGPUIdentityTransport {
    public static let gptkRootEnvironmentKey =
        "SWITCHYARD_GPTK_PATH"
    public static let helperEnvironmentKey =
        "SWITCHYARD_GPU_INFO_HELPER"
    public static let privateEnvironmentKeyPrefix =
        "SWITCHYARD_INTERNAL_GPU_IDENTITY_"
    public static let cachedIdentityEnvironmentKey =
        privateEnvironmentKeyPrefix + "TSV_BASE64_V1"
    public static let maximumEncodedIdentityUTF8Bytes =
        ((HostGPUIdentity.maximumCanonicalTSVBytes + 2) / 3) * 4

    public static func isPrivateEnvironmentKey(_ key: String) -> Bool {
        key.hasPrefix(privateEnvironmentKeyPrefix)
    }

    public static func sanitized(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.filter { key, _ in
            key != helperEnvironmentKey
                && !isPrivateEnvironmentKey(key)
        }
    }

    public static func encode(
        _ snapshot: GPTKGPUIdentitySnapshot
    ) throws -> String {
        let encoded = snapshot.identity.canonicalTSVData
            .base64EncodedString()
        guard encoded.utf8.count <= maximumEncodedIdentityUTF8Bytes else {
            throw GPTKGPUIdentityTransportError
                .encodedIdentityTooLarge
        }
        return encoded
    }

    public static func decodeIdentity(
        _ encoded: String
    ) throws -> HostGPUIdentity {
        guard encoded.utf8.count <= maximumEncodedIdentityUTF8Bytes else {
            throw GPTKGPUIdentityTransportError
                .encodedIdentityTooLarge
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw GPTKGPUIdentityTransportError.invalidBase64
        }
        guard data.count <= HostGPUIdentity.maximumCanonicalTSVBytes else {
            throw GPTKGPUIdentityTransportError
                .encodedIdentityTooLarge
        }
        guard data.base64EncodedString() == encoded else {
            throw GPTKGPUIdentityTransportError.noncanonicalBase64
        }

        do {
            let identity = try HostGPUIdentity(tsvData: data)
            guard identity.canonicalTSVData == data else {
                throw GPTKGPUIdentityTransportError
                    .noncanonicalBase64
            }
            return identity
        } catch let error as GPTKGPUIdentityTransportError {
            throw error
        } catch let error as HostGPUIdentityError {
            throw GPTKGPUIdentityTransportError
                .invalidIdentity(error)
        }
    }
}

public enum RuntimeGPUIdentityContentFingerprintError:
    Error,
    Equatable,
    Sendable
{
    case missingEnvironmentValue(String)
    case invalidRuntimeID
    case invalidPatchsetID
    case invalidSourceRevision
    case invalidWineExecutable
}

/// Deterministic identity for immutable Switchyard Wine runtime content.
///
/// Version 1 hashes length-prefixed UTF-8 values for the runtime ID, patchset
/// ID, pinned lowercase Git source revision, and approved Wine executable
/// relative path under a domain separator. Installation roots are deliberately
/// excluded so identical verified runtime content has the same identity after
/// relocation.
public enum RuntimeGPUIdentityContentFingerprint {
    public static let runtimeIDEnvironmentKey =
        "SWITCHYARD_WINE_BUILD_ID"
    public static let patchsetIDEnvironmentKey =
        "SWITCHYARD_PATCHSET_ID"
    public static let sourceRevisionEnvironmentKey =
        "SWITCHYARD_WINE_SOURCE_REVISION"
    public static let allowedWineExecutableRelativePaths: Set<String> = [
        "bin/switchyard-wine",
        "bin/wine",
        "bin/wine64",
    ]

    private static let domain = Data(
        "switchyard-runtime-gpu-content-v1".utf8
    )
    private static let maximumIdentityUTF8Bytes = 256

    public static func make(
        for runtime: RuntimeBuild
    ) throws -> String {
        try make(
            runtimeID: runtime.id,
            patchsetID: runtime.patchsetID,
            sourceRevision: runtime.sourceRevision,
            wineExecutableRelativePath:
                try wineExecutableRelativePath(
                    for: runtime.winePath
                )
        )
    }

    public static func make(
        environment: [String: String],
        wineExecutablePath: String
    ) throws -> String {
        guard let runtimeID = environment[runtimeIDEnvironmentKey] else {
            throw RuntimeGPUIdentityContentFingerprintError
                .missingEnvironmentValue(runtimeIDEnvironmentKey)
        }
        guard let patchsetID = environment[patchsetIDEnvironmentKey] else {
            throw RuntimeGPUIdentityContentFingerprintError
                .missingEnvironmentValue(patchsetIDEnvironmentKey)
        }
        guard let sourceRevision =
                environment[sourceRevisionEnvironmentKey] else {
            throw RuntimeGPUIdentityContentFingerprintError
                .missingEnvironmentValue(sourceRevisionEnvironmentKey)
        }
        return try make(
            runtimeID: runtimeID,
            patchsetID: patchsetID,
            sourceRevision: sourceRevision,
            wineExecutableRelativePath:
                try wineExecutableRelativePath(
                    for: wineExecutablePath
                )
        )
    }

    public static func make(
        runtimeID: String,
        patchsetID: String,
        sourceRevision: String,
        wineExecutableRelativePath: String
    ) throws -> String {
        guard isBoundedControlFree(runtimeID) else {
            throw RuntimeGPUIdentityContentFingerprintError
                .invalidRuntimeID
        }
        guard isBoundedControlFree(patchsetID) else {
            throw RuntimeGPUIdentityContentFingerprintError
                .invalidPatchsetID
        }
        guard isPinnedSourceRevision(sourceRevision) else {
            throw RuntimeGPUIdentityContentFingerprintError
                .invalidSourceRevision
        }
        guard allowedWineExecutableRelativePaths.contains(
            wineExecutableRelativePath
        ) else {
            throw RuntimeGPUIdentityContentFingerprintError
                .invalidWineExecutable
        }

        var hasher = SHA256()
        hasher.update(data: domain)
        update(&hasher, with: runtimeID)
        update(&hasher, with: patchsetID)
        update(&hasher, with: sourceRevision)
        update(&hasher, with: wineExecutableRelativePath)
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func update(
        _ hasher: inout SHA256,
        with value: String
    ) {
        let bytes = Data(value.utf8)
        var bigEndianCount = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &bigEndianCount) {
            hasher.update(data: Data($0))
        }
        hasher.update(data: bytes)
    }

    private static func isBoundedControlFree(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumIdentityUTF8Bytes
            && value.unicodeScalars.allSatisfy {
                $0.value > 0x1F
                    && $0.value != 0x7F
                    && $0.value != 0x85
                    && $0.value != 0x2028
                    && $0.value != 0x2029
            }
    }

    private static func isPinnedSourceRevision(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x61...0x66).contains($0)
            }
    }

    private static func wineExecutableRelativePath(
        for path: String
    ) throws -> String {
        guard path.first == "/",
              !path.unicodeScalars.contains(where: {
                  $0.value <= 0x1F || $0.value == 0x7F
              }) else {
            throw RuntimeGPUIdentityContentFingerprintError
                .invalidWineExecutable
        }
        let executableURL = URL(fileURLWithPath: path)
            .standardizedFileURL
        let directoryURL = executableURL.deletingLastPathComponent()
        let relativePath =
            "\(directoryURL.lastPathComponent)/\(executableURL.lastPathComponent)"
        guard allowedWineExecutableRelativePaths.contains(relativePath) else {
            throw RuntimeGPUIdentityContentFingerprintError
                .invalidWineExecutable
        }
        return relativePath
    }
}
