import AppCore
import Foundation
import Testing

@Suite("GPTK GPU Identity Transport")
struct GPTKGPUIdentityTransportTests {
    @Test("round-trips one bounded canonical TSV identity")
    func canonicalRoundTrip() throws {
        let snapshot = try transportSnapshot()

        let encoded = try GPTKGPUIdentityTransport.encode(snapshot)
        let decoded = try GPTKGPUIdentityTransport.decodeIdentity(
            encoded
        )

        #expect(decoded == snapshot.identity)
        #expect(
            Data(base64Encoded: encoded)
                == snapshot.identity.canonicalTSVData
        )
        #expect(
            encoded.utf8.count <=
                GPTKGPUIdentityTransport
                    .maximumEncodedIdentityUTF8Bytes
        )
    }

    @Test("rejects oversized and malformed private values")
    func rejectsInvalidTransportValues() throws {
        let oversized = String(
            repeating: "A",
            count:
                GPTKGPUIdentityTransport
                    .maximumEncodedIdentityUTF8Bytes + 1
        )
        #expect(
            throws:
                GPTKGPUIdentityTransportError
                    .encodedIdentityTooLarge
        ) {
            try GPTKGPUIdentityTransport.decodeIdentity(oversized)
        }
        #expect(throws: GPTKGPUIdentityTransportError.invalidBase64) {
            try GPTKGPUIdentityTransport.decodeIdentity("not base64")
        }

        let invalidRecord = Data("invalid\n".utf8)
            .base64EncodedString()
        #expect(
            throws:
                GPTKGPUIdentityTransportError.invalidIdentity(
                    .invalidFieldCount
                )
        ) {
            try GPTKGPUIdentityTransport.decodeIdentity(invalidRecord)
        }

        let canonical = try transportSnapshot()
            .identity.canonicalTSVData
        let multiline = (canonical + canonical)
            .base64EncodedString()
        #expect(
            throws:
                GPTKGPUIdentityTransportError.invalidIdentity(
                    .invalidLineCount
                )
        ) {
            try GPTKGPUIdentityTransport.decodeIdentity(multiline)
        }
    }

    @Test("sanitizes inherited and future private transport keys")
    func sanitizesTransportKeys() {
        let environment = [
            "PATH": "/usr/bin",
            GPTKGPUIdentityTransport.helperEnvironmentKey:
                "/tmp/untrusted-helper",
            GPTKGPUIdentityTransport.cachedIdentityEnvironmentKey:
                "untrusted",
            GPTKGPUIdentityTransport.privateEnvironmentKeyPrefix
                + "FUTURE_V2": "untrusted",
        ]

        #expect(
            GPTKGPUIdentityTransport.sanitized(environment)
                == ["PATH": "/usr/bin"]
        )
    }
}

@Suite("Runtime GPU Identity Content Fingerprint")
struct RuntimeGPUIdentityContentFingerprintTests {
    @Test("RuntimeBuild and plan environment use one deterministic contract")
    func buildAndEnvironmentMatch() throws {
        let runtime = transportRuntime()
        let environment = transportRuntimeEnvironment(runtime: runtime)

        let buildFingerprint =
            try RuntimeGPUIdentityContentFingerprint.make(for: runtime)
        let environmentFingerprint =
            try RuntimeGPUIdentityContentFingerprint.make(
                environment: environment,
                wineExecutablePath: runtime.winePath
            )
        var relocatedRuntime = runtime
        relocatedRuntime.winePath =
            "/private/relocated-runtime/bin/wine"
        let relocatedFingerprint =
            try RuntimeGPUIdentityContentFingerprint.make(
                for: relocatedRuntime
            )

        #expect(buildFingerprint == environmentFingerprint)
        #expect(buildFingerprint == relocatedFingerprint)
        #expect(buildFingerprint.utf8.count == 64)
        #expect(
            buildFingerprint.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x61...0x66).contains($0)
            }
        )
    }

    @Test("every immutable runtime identity field changes the fingerprint")
    func isolatesRuntimeIdentityFields() throws {
        let base = try RuntimeGPUIdentityContentFingerprint.make(
            runtimeID: "runtime-a",
            patchsetID: "patchset-a",
            sourceRevision: String(repeating: "a", count: 40),
            wineExecutableRelativePath: "bin/wine"
        )
        let changed = [
            try RuntimeGPUIdentityContentFingerprint.make(
                runtimeID: "runtime-b",
                patchsetID: "patchset-a",
                sourceRevision: String(repeating: "a", count: 40),
                wineExecutableRelativePath: "bin/wine"
            ),
            try RuntimeGPUIdentityContentFingerprint.make(
                runtimeID: "runtime-a",
                patchsetID: "patchset-b",
                sourceRevision: String(repeating: "a", count: 40),
                wineExecutableRelativePath: "bin/wine"
            ),
            try RuntimeGPUIdentityContentFingerprint.make(
                runtimeID: "runtime-a",
                patchsetID: "patchset-a",
                sourceRevision: String(repeating: "b", count: 40),
                wineExecutableRelativePath: "bin/wine"
            ),
            try RuntimeGPUIdentityContentFingerprint.make(
                runtimeID: "runtime-a",
                patchsetID: "patchset-a",
                sourceRevision: String(repeating: "a", count: 40),
                wineExecutableRelativePath: "bin/wine64"
            ),
        ]

        #expect(Set(changed).count == changed.count)
        #expect(changed.allSatisfy { $0 != base })
    }

    @Test("requires a pinned lowercase source revision")
    func rejectsMutableSourceIdentity() {
        #expect(
            throws:
                RuntimeGPUIdentityContentFingerprintError
                    .invalidSourceRevision
        ) {
            try RuntimeGPUIdentityContentFingerprint.make(
                runtimeID: "runtime-a",
                patchsetID: "patchset-a",
                sourceRevision: "main",
                wineExecutableRelativePath: "bin/wine"
            )
        }
        #expect(
            throws:
                RuntimeGPUIdentityContentFingerprintError
                    .invalidSourceRevision
        ) {
            try RuntimeGPUIdentityContentFingerprint.make(
                runtimeID: "runtime-a",
                patchsetID: "patchset-a",
                sourceRevision: String(repeating: "A", count: 40),
                wineExecutableRelativePath: "bin/wine"
            )
        }
        #expect(
            throws:
                RuntimeGPUIdentityContentFingerprintError
                    .invalidWineExecutable
        ) {
            try RuntimeGPUIdentityContentFingerprint.make(
                runtimeID: "runtime-a",
                patchsetID: "patchset-a",
                sourceRevision: String(repeating: "a", count: 40),
                wineExecutableRelativePath: "bin/untrusted"
            )
        }
    }
}

private func transportRuntime() -> RuntimeBuild {
    RuntimeBuild(
        id: "runtime-a",
        winePath: "/private/runtime-a/bin/wine",
        patchsetID: "patchset-a",
        sourceRevision: String(repeating: "a", count: 40)
    )
}

private func transportRuntimeEnvironment(
    runtime: RuntimeBuild
) -> [String: String] {
    [
        RuntimeGPUIdentityContentFingerprint.runtimeIDEnvironmentKey:
            runtime.id,
        RuntimeGPUIdentityContentFingerprint.patchsetIDEnvironmentKey:
            runtime.patchsetID,
        RuntimeGPUIdentityContentFingerprint.sourceRevisionEnvironmentKey:
            runtime.sourceRevision,
    ]
}

private func transportSnapshot() throws -> GPTKGPUIdentitySnapshot {
    let runtime = transportRuntime()
    let runtimeEvidence = try RuntimeGPUIdentityEvidence(
        runtimeID: runtime.id,
        runtimeRoot: "/private/runtime-a",
        runtimeContentFingerprint:
            RuntimeGPUIdentityContentFingerprint.make(for: runtime),
        helper: try RuntimeGPUIdentityFileEvidence(
            canonicalPath:
                "/private/runtime-a/libexec/switchyard-host-gpu-info",
            device: 1,
            inode: 2,
            size: 4_096,
            modificationTimeNanoseconds: 1_000,
            mode: 0o100755,
            sha256: String(repeating: "a", count: 64)
        ),
        policy: try RuntimeGPUIdentityFileEvidence(
            canonicalPath:
                "/private/runtime-a/share/switchyard/gpu_capability_policy.sh",
            device: 1,
            inode: 3,
            size: 1_024,
            modificationTimeNanoseconds: 2_000,
            mode: 0o100644,
            sha256: String(repeating: "b", count: 64)
        )
    )
    return GPTKGPUIdentitySnapshot(
        cacheKey: try GPTKGPUIdentityCacheKey(
            operatingSystemBuild: "24G90",
            defaultGPURegistryID: 0x100,
            runtime: runtimeEvidence
        ),
        identity: try HostGPUIdentity(
            vendorID: 0x106B,
            deviceID: 1,
            subsystemID: 0,
            revisionID: 0,
            description: "Apple GPU"
        )
    )
}
