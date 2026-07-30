import AppCore
import Foundation
import Testing

@Suite("Host GPU Identity")
struct HostGPUIdentityTests {
    @Test("parses and serializes the canonical LF-terminated TSV record")
    func canonicalTSVRoundTrip() throws {
        let canonical =
            "0000106b\t1234abcd\t00000000\t00000000\tApple M4 Pro – 기본 GPU\n"

        let identity = try HostGPUIdentity.parseTSV(canonical)

        #expect(identity.vendorID == 0x0000_106B)
        #expect(identity.deviceID == 0x1234_ABCD)
        #expect(identity.subsystemID == 0)
        #expect(identity.revisionID == 0)
        #expect(identity.description == "Apple M4 Pro – 기본 GPU")
        #expect(identity.canonicalTSV == canonical)
        #expect(identity.canonicalTSVData == Data(canonical.utf8))
        #expect(
            try HostGPUIdentity(tsvData: identity.canonicalTSVData)
                == identity
        )
    }

    @Test("serializer pads lowercase identifiers and emits one LF")
    func serializerIsCanonical() throws {
        let identity = try HostGPUIdentity(
            vendorID: 1,
            deviceID: .max,
            subsystemID: 0xABCD,
            revisionID: 0,
            description: "GPU"
        )

        #expect(
            identity.canonicalTSV
                == "00000001\tffffffff\t0000abcd\t00000000\tGPU\n"
        )
        #expect(identity.canonicalTSV.filter { $0 == "\n" }.count == 1)
        #expect(!identity.canonicalTSV.contains("\r"))
    }

    @Test("parser rejects noncanonical line structure")
    func rejectsNoncanonicalLineStructure() {
        let record =
            "0000106b\t00000001\t00000000\t00000000\tApple GPU"

        #expect(throws: HostGPUIdentityError.invalidLineTermination) {
            try HostGPUIdentity.parseTSV(record)
        }
        #expect(throws: HostGPUIdentityError.invalidLineCount) {
            try HostGPUIdentity.parseTSV(record + "\r\n")
        }
        #expect(throws: HostGPUIdentityError.invalidLineCount) {
            try HostGPUIdentity.parseTSV(record + "\n\n")
        }
        #expect(throws: HostGPUIdentityError.invalidLineCount) {
            try HostGPUIdentity.parseTSV(record + "\n" + record + "\n")
        }
        #expect(throws: HostGPUIdentityError.invalidLineTermination) {
            try HostGPUIdentity.parseTSV(Data())
        }
    }

    @Test("parser requires exactly five fields")
    func rejectsWrongFieldCount() {
        #expect(throws: HostGPUIdentityError.invalidFieldCount) {
            try HostGPUIdentity.parseTSV(
                "0000106b\t00000001\t00000000\tApple GPU\n"
            )
        }
        #expect(throws: HostGPUIdentityError.invalidFieldCount) {
            try HostGPUIdentity.parseTSV(
                "0000106b\t00000001\t00000000\t00000000\tApple\tGPU\n"
            )
        }
        #expect(throws: HostGPUIdentityError.invalidFieldCount) {
            try HostGPUIdentity.parseTSV(
                "0000106b\t00000001\t00000000\t00000000\tApple GPU\t\n"
            )
        }
    }

    @Test("parser requires eight lowercase hexadecimal digits in every ID field")
    func rejectsInvalidHexFields() {
        let validFields = [
            "0000106b",
            "00000001",
            "00000000",
            "00000000",
            "Apple GPU",
        ]

        let malformedValues = [
            "",
            "0000000",
            "000000000",
            "0000000g",
            "0000000A",
            "0x000001",
            "+0000001",
            " 0000001",
        ]
        for fieldIndex in 0..<4 {
            for malformedValue in malformedValues {
                var fields = validFields
                fields[fieldIndex] = malformedValue

                #expect(
                    throws: HostGPUIdentityError.invalidHexField(fieldIndex)
                ) {
                    try HostGPUIdentity.parseTSV(
                        fields.joined(separator: "\t") + "\n"
                    )
                }
            }
        }
    }

    @Test("vendor and device IDs must be nonzero")
    func rejectsZeroVendorAndDeviceIDs() {
        #expect(throws: HostGPUIdentityError.zeroVendorID) {
            try HostGPUIdentity.parseTSV(
                "00000000\t00000001\t00000000\t00000000\tApple GPU\n"
            )
        }
        #expect(throws: HostGPUIdentityError.zeroDeviceID) {
            try HostGPUIdentity.parseTSV(
                "0000106b\t00000000\t00000000\t00000000\tApple GPU\n"
            )
        }
        #expect(throws: HostGPUIdentityError.zeroVendorID) {
            try HostGPUIdentity(
                vendorID: 0,
                deviceID: 1,
                subsystemID: 0,
                revisionID: 0,
                description: "Apple GPU"
            )
        }
        #expect(throws: HostGPUIdentityError.zeroDeviceID) {
            try HostGPUIdentity(
                vendorID: 1,
                deviceID: 0,
                subsystemID: 0,
                revisionID: 0,
                description: "Apple GPU"
            )
        }
    }

    @Test("description enforces UTF-8 byte and control-character boundaries")
    func validatesDescriptionBoundaries() throws {
        let maximumDescription = String(repeating: "é", count: 127) + "a"
        #expect(maximumDescription.utf8.count == 255)

        let accepted = try HostGPUIdentity(
            vendorID: 1,
            deviceID: 1,
            subsystemID: 0,
            revisionID: 0,
            description: maximumDescription
        )
        #expect(
            accepted.canonicalTSVData.count
                == HostGPUIdentity.maximumCanonicalTSVBytes
        )
        #expect(
            try HostGPUIdentity.parseTSV(accepted.canonicalTSVData)
                == accepted
        )

        #expect(throws: HostGPUIdentityError.recordTooLarge) {
            try HostGPUIdentity.parseTSV(
                accepted.canonicalTSVLine + "a\n"
            )
        }
        #expect(throws: HostGPUIdentityError.invalidDescription) {
            try makeIdentity(description: "")
        }
        #expect(throws: HostGPUIdentityError.invalidFieldCount) {
            try HostGPUIdentity.parseTSV(
                "00000001\t00000001\t00000000\t00000000\tApple\tGPU\n"
            )
        }
        #expect(throws: HostGPUIdentityError.invalidLineCount) {
            try HostGPUIdentity.parseTSV(
                "00000001\t00000001\t00000000\t00000000\tApple\rGPU\n"
            )
        }
        #expect(throws: HostGPUIdentityError.invalidLineCount) {
            try HostGPUIdentity.parseTSV(
                "00000001\t00000001\t00000000\t00000000\tApple\nGPU\n"
            )
        }

        let explicitlyRejectedDescriptions = [
            "GPU\u{0000}",
            "GPU\tname",
            "GPU\rname",
            "GPU\nname",
            "GPU\u{007F}",
            "GPU\u{0085}",
            "GPU\u{2028}",
            "GPU\u{2029}",
        ]
        for description in explicitlyRejectedDescriptions {
            #expect(throws: HostGPUIdentityError.invalidDescription) {
                try makeIdentity(description: description)
            }
        }

        for codePoint in UInt32(0)...UInt32(0x1F) {
            let scalar = try #require(Unicode.Scalar(codePoint))
            #expect(throws: HostGPUIdentityError.invalidDescription) {
                try makeIdentity(description: "GPU" + String(scalar))
            }
        }
    }

    @Test("parser rejects invalid UTF-8")
    func rejectsInvalidUTF8() {
        var data = Data(
            "00000001\t00000001\t00000000\t00000000\tGPU".utf8
        )
        data.append(0xFF)
        data.append(0x0A)

        #expect(throws: HostGPUIdentityError.invalidUTF8) {
            try HostGPUIdentity.parseTSV(data)
        }
    }

    @Test("Codable cannot reconstruct an invalid identity")
    func codablePreservesValidation() throws {
        let identity = try makeIdentity(description: "Apple GPU")
        let roundTripped = try JSONDecoder().decode(
            HostGPUIdentity.self,
            from: JSONEncoder().encode(identity)
        )
        #expect(roundTripped == identity)

        let invalidJSON = Data(
            """
            {
              "vendorID": 0,
              "deviceID": 1,
              "subsystemID": 0,
              "revisionID": 0,
              "description": "Apple GPU"
            }
            """.utf8
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HostGPUIdentity.self, from: invalidJSON)
        }
    }
}

@Suite("GPTK GPU Identity Evidence")
struct GPTKGPUIdentityEvidenceTests {
    @Test("snapshot retains every host, runtime, and file cache-key input")
    func snapshotRoundTripsThroughCommandPlanJSON() throws {
        let snapshot = try makeSnapshot()
        let plan = CommandPlan(
            executable: "/usr/bin/true",
            arguments: ["--launch"],
            environment: ["WINEPREFIX": "/private/tmp/prefix"],
            workingDirectory: "/private/tmp",
            logSource: "GPU identity test",
            liveLogPath: "/private/tmp/live.log",
            debugLogPath: "/private/tmp/debug.log",
            terminateExistingPrefixSession: true,
            containerDisplayMode: .retina,
            keepLoggingWhilePrefixIsActive: true,
            forwardCapturedOutput: false,
            gptkGPUIdentitySnapshot: snapshot
        )

        let encoded = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(CommandPlan.self, from: encoded)

        #expect(decoded == plan)
        #expect(decoded.gptkGPUIdentitySnapshot == snapshot)
        #expect(
            decoded.gptkGPUIdentitySnapshot?.cacheKey.defaultGPURegistryID
                == 0xFEDC_BA98_7654_3210
        )
        #expect(
            decoded.gptkGPUIdentitySnapshot?.cacheKey.runtime.helper.sha256
                == String(repeating: "a", count: 64)
        )
        #expect(
            decoded.gptkGPUIdentitySnapshot?.cacheKey.runtime.policy.sha256
                == String(repeating: "b", count: 64)
        )
        #expect(Set([snapshot]).contains(snapshot))
    }

    @Test("CommandPlan decodes older JSON without a snapshot")
    func commandPlanDecodesLegacyJSON() throws {
        let legacyJSON = Data(
            """
            {
              "executable": "/usr/bin/true",
              "arguments": [],
              "environment": {},
              "logSource": "legacy"
            }
            """.utf8
        )

        let plan = try JSONDecoder().decode(CommandPlan.self, from: legacyJSON)

        #expect(plan.gptkGPUIdentitySnapshot == nil)

        let encoded = try JSONEncoder().encode(plan)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["gptkGPUIdentitySnapshot"] == nil)
    }

    @Test("file evidence validates canonical paths and lowercase SHA-256")
    func fileEvidenceValidation() {
        #expect(
            throws: RuntimeGPUIdentityEvidenceError.invalidCanonicalPath
        ) {
            try makeFileEvidence(
                path: "relative/helper",
                sha256: String(repeating: "a", count: 64)
            )
        }
        #expect(
            throws: RuntimeGPUIdentityEvidenceError.invalidCanonicalPath
        ) {
            try makeFileEvidence(
                path: "/private/runtime/../helper",
                sha256: String(repeating: "a", count: 64)
            )
        }
        #expect(throws: RuntimeGPUIdentityEvidenceError.invalidSHA256) {
            try makeFileEvidence(
                path: "/private/runtime/helper",
                sha256: String(repeating: "a", count: 63)
            )
        }
        #expect(throws: RuntimeGPUIdentityEvidenceError.invalidSHA256) {
            try makeFileEvidence(
                path: "/private/runtime/helper",
                sha256: String(repeating: "A", count: 64)
            )
        }
    }

    @Test("runtime evidence and cache keys reject empty identity inputs")
    func cacheKeyValidation() throws {
        let helper = try makeFileEvidence(
            path: "/private/runtime/helper",
            sha256: String(repeating: "a", count: 64)
        )
        let policy = try makeFileEvidence(
            path: "/private/runtime/policy",
            sha256: String(repeating: "b", count: 64)
        )

        #expect(throws: RuntimeGPUIdentityEvidenceError.invalidRuntimeID) {
            try RuntimeGPUIdentityEvidence(
                runtimeID: "",
                runtimeRoot: "/private/runtime",
                runtimeContentFingerprint: "runtime-content-a",
                helper: helper,
                policy: policy
            )
        }

        let runtime = try RuntimeGPUIdentityEvidence(
            runtimeID: "runtime-a",
            runtimeRoot: "/private/runtime",
            runtimeContentFingerprint: "runtime-content-a",
            helper: helper,
            policy: policy
        )
        #expect(
            throws: RuntimeGPUIdentityEvidenceError.invalidOperatingSystemBuild
        ) {
            try GPTKGPUIdentityCacheKey(
                operatingSystemBuild: "",
                defaultGPURegistryID: 1,
                runtime: runtime
            )
        }
        #expect(
            throws: RuntimeGPUIdentityEvidenceError.zeroDefaultGPURegistryID
        ) {
            try GPTKGPUIdentityCacheKey(
                operatingSystemBuild: "24G90",
                defaultGPURegistryID: 0,
                runtime: runtime
            )
        }
    }
}

private func makeIdentity(description: String) throws -> HostGPUIdentity {
    try HostGPUIdentity(
        vendorID: 0x106B,
        deviceID: 1,
        subsystemID: 0,
        revisionID: 0,
        description: description
    )
}

private func makeFileEvidence(
    path: String,
    sha256: String,
    inode: UInt64 = 2
) throws -> RuntimeGPUIdentityFileEvidence {
    try RuntimeGPUIdentityFileEvidence(
        canonicalPath: path,
        device: 1,
        inode: inode,
        size: 4_096,
        modificationTimeNanoseconds: 1_721_234_567_890_123_456,
        mode: 0o100755,
        sha256: sha256
    )
}

private func makeSnapshot() throws -> GPTKGPUIdentitySnapshot {
    let helper = try makeFileEvidence(
        path: "/private/runtime/libexec/gptk-gpu-identity",
        sha256: String(repeating: "a", count: 64)
    )
    let policy = try makeFileEvidence(
        path: "/private/runtime/share/gptk-gpu-policy.json",
        sha256: String(repeating: "b", count: 64),
        inode: 3
    )
    let runtime = try RuntimeGPUIdentityEvidence(
        runtimeID: "switchyard-runtime-0.4.2",
        runtimeRoot: "/private/runtime",
        runtimeContentFingerprint: "runtime-content-fingerprint",
        helper: helper,
        policy: policy
    )
    let cacheKey = try GPTKGPUIdentityCacheKey(
        operatingSystemBuild: "24G90",
        defaultGPURegistryID: 0xFEDC_BA98_7654_3210,
        runtime: runtime
    )
    let identity = try HostGPUIdentity(
        vendorID: 0x106B,
        deviceID: 0x0000_0001,
        subsystemID: 0,
        revisionID: 0,
        description: "Apple M4 Pro"
    )
    return GPTKGPUIdentitySnapshot(cacheKey: cacheKey, identity: identity)
}
