import CryptoKit
import Foundation
import Testing
@testable import RuntimeCatalog

@Test func gptkComponentConfigurationRequiresEveryReleaseControl() throws {
    let manifestURL = try #require(URL(
        string: "https://components.example.test/releases/gptk-component-release.json"
    ))
    let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation

    let disabled = GPTKComponentChannelConfiguration(
        isEnabled: false,
        channelStatusURL: channelStatusURL(for: manifestURL),
        releaseManifestURL: manifestURL,
        manifestSigningPublicKey: publicKey,
        distributorAuthorityID: "authority:2026-07-24",
        independentLegalApprovalID: "legal:2026-07-24",
        nonCommercialAttestationID: "noncommercial:2026-07-24",
        exportControlsAttestationID: "export:2026-07-24",
        takedownAttestationID: "takedown:2026-07-24"
    )
    #expect(disabled.downloadPolicy == nil)

    var incomplete = disabled
    incomplete.isEnabled = true
    incomplete.independentLegalApprovalID = ""
    #expect(incomplete.downloadPolicy == nil)

    var enabled = incomplete
    enabled.independentLegalApprovalID = "legal:2026-07-24"
    #expect(enabled.downloadPolicy != nil)
}

@Test func gptkComponentManifestAcceptsOnlyTheReviewedGPTK3Identity() throws {
    let manifestURL = try #require(URL(
        string: "https://components.example.test/releases/gptk-component-release.json"
    ))
    let policy = reviewedPolicy(
        manifestURL: manifestURL,
        publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    )
    let release = reviewedRelease(manifestURL: manifestURL)

    try GPTKComponentInstaller.validate(release: release, against: policy)

    var unreviewedVersion = release
    unreviewedVersion.gptkVersion = "4.0"
    #expect(throws: GPTKComponentInstallerError.unreviewedGPTKRelease) {
        try GPTKComponentInstaller.validate(
            release: unreviewedVersion,
            against: policy
        )
    }

    var remotelyDisabled = release
    remotelyDisabled.status = "disabled"
    #expect(throws: GPTKComponentInstallerError.channelDisabled) {
        try GPTKComponentInstaller.validate(
            release: remotelyDisabled,
            against: policy
        )
    }
}

@Test func gptkFrameworkIdentityUsesTheFullSHA256CDHash() {
    let fullHash = Data(repeating: 0xab, count: 32)
    let truncatedHash = Data(repeating: 0xcd, count: 20)
    let values = GPTKComponentInstaller.fullCDHashHexValues(
        from: [
            "cdhashes-full": [fullHash, truncatedHash],
            "cdhashes": [truncatedHash]
        ]
    )

    #expect(values == [String(repeating: "ab", count: 32)])
}

@Test func gptkConsentRejectsAChangedManifestSignature() async throws {
    let manifestURL = try #require(URL(
        string: "https://components.example.test/releases/gptk-component-release.json"
    ))
    let privateKey = Curve25519.Signing.PrivateKey()
    let policy = reviewedPolicy(
        manifestURL: manifestURL,
        publicKey: privateKey.publicKey.rawRepresentation
    )
    let manifestData = try JSONEncoder().encode(
        reviewedRelease(manifestURL: manifestURL)
    )
    let statusURL = channelStatusURL(for: manifestURL)
    let statusData = try channelStatusData(manifestData: manifestData)
    let statusSignature = try privateKey.signature(for: statusData)
    let invalidSignature = Data(repeating: 0, count: 64)
    let responses = [
        statusURL: statusData,
        statusURL.appendingPathExtension("sig"): statusSignature,
        manifestURL: manifestData,
        manifestURL.appendingPathExtension("sig"): invalidSignature
    ]
    let installer = stubInstaller(responses: responses)

    await #expect(
        throws: GPTKComponentInstallerError.invalidManifestSignature
    ) {
        _ = try await installer.prepareConsent(policy: policy)
    }
}

@Test func gptkConsentVerifiesTheSignedManifestBeforeTheExactLicense() async throws {
    let manifestURL = try #require(URL(
        string: "https://components.example.test/releases/gptk-component-release.json"
    ))
    let privateKey = Curve25519.Signing.PrivateKey()
    let policy = reviewedPolicy(
        manifestURL: manifestURL,
        publicKey: privateKey.publicKey.rawRepresentation
    )
    let release = reviewedRelease(manifestURL: manifestURL)
    let manifestData = try JSONEncoder().encode(release)
    let manifestSignature = try privateKey.signature(for: manifestData)
    let statusURL = channelStatusURL(for: manifestURL)
    let statusData = try channelStatusData(manifestData: manifestData)
    let statusSignature = try privateKey.signature(for: statusData)
    let responses = [
        statusURL: statusData,
        statusURL.appendingPathExtension("sig"): statusSignature,
        manifestURL: manifestData,
        manifestURL.appendingPathExtension("sig"): manifestSignature,
        release.license.url: Data("not the reviewed Apple license".utf8)
    ]
    let installer = stubInstaller(responses: responses)

    await #expect(
        throws: GPTKComponentInstallerError.licenseDigestMismatch
    ) {
        _ = try await installer.prepareConsent(policy: policy)
    }
}

@Test func gptkArchiveRejectsEscapingLinksBeforeExtraction() throws {
    let fileManager = FileManager.default
    let testRoot = fileManager.temporaryDirectory.appendingPathComponent(
        "Switchyard-GPTK-Archive-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: testRoot) }
    let componentID = "switchyard-gptk-3-framework"
    let frameworkRoot = testRoot
        .appendingPathComponent(componentID, isDirectory: true)
        .appendingPathComponent(
            "redist/lib/external/D3DMetal.framework",
            isDirectory: true
        )
    try fileManager.createDirectory(
        at: frameworkRoot,
        withIntermediateDirectories: true
    )
    try fileManager.createSymbolicLink(
        atPath: frameworkRoot.appendingPathComponent("Escape").path,
        withDestinationPath: "../../../../../../outside"
    )

    let archiveURL = testRoot.appendingPathComponent("payload.zip")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = testRoot
    zip.arguments = ["-qry", "-y", archiveURL.path, componentID]
    try zip.run()
    zip.waitUntilExit()
    #expect(zip.terminationStatus == 0)

    let installer = stubInstaller(responses: [:])
    #expect(throws: GPTKComponentInstallerError.escapingSymbolicLink) {
        try installer.validateArchiveEntries(
            archiveURL,
            expectedRootName: componentID,
            permittedPaths: ["redist"]
        )
    }
}

private func reviewedPolicy(
    manifestURL: URL,
    publicKey: Data
) -> GPTKComponentChannelPolicy {
    GPTKComponentChannelPolicy(
        channelStatusURL: channelStatusURL(for: manifestURL),
        releaseManifestURL: manifestURL,
        manifestSigningPublicKey: publicKey,
        distributorAuthorityID: "authority:2026-07-24",
        independentLegalApprovalID: "legal:2026-07-24",
        nonCommercialAttestationID: "noncommercial:2026-07-24",
        exportControlsAttestationID: "export:2026-07-24",
        takedownAttestationID: "takedown:2026-07-24"
    )
}

private func channelStatusURL(for manifestURL: URL) -> URL {
    manifestURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("gptk-component-channel.json")
}

private func channelStatusData(manifestData: Data) throws -> Data {
    let digest = SHA256.hash(data: manifestData)
        .map { String(format: "%02x", $0) }
        .joined()
    return try JSONEncoder().encode(
        GPTKComponentChannelStatus(
            schemaVersion: 1,
            status: "enabled",
            releaseManifestSha256: digest
        )
    )
}

private func reviewedRelease(
    manifestURL: URL
) -> GPTKComponentRelease {
    GPTKComponentRelease(
        schemaVersion: 1,
        status: "enabled",
        componentID: "switchyard-gptk-3-framework",
        gptkVersion: "3.0",
        reviewDate: "2026-07-22",
        sourceOuterImageSha256:
            GPTKComponentInstaller.reviewedOuterImageSha256,
        sourceEvaluationImageSha256:
            GPTKComponentInstaller.reviewedEvaluationImageSha256,
        archive: "switchyard-gptk-3-framework.zip",
        archiveSha256: String(repeating: "a", count: 64),
        archiveSize: 1_024,
        contentTreeSha256: String(repeating: "b", count: 64),
        permittedPaths: [
            "redist",
            "License.rtf",
            "Acknowledgements.rtf"
        ],
        appleSigningRequirement:
            GPTKComponentInstaller.reviewedSigningRequirement,
        frameworkBundleIdentifier: "com.apple.D3DMetal",
        frameworkCDHash:
            GPTKComponentInstaller.reviewedFrameworkCDHash,
        license: GPTKComponentLicense(
            identifier: "EA18380",
            path: "License.rtf",
            url: manifestURL
                .deletingLastPathComponent()
                .appendingPathComponent("License.rtf"),
            sha256: GPTKComponentInstaller.reviewedLicenseSha256
        ),
        acknowledgements: GPTKComponentNotice(
            path: "Acknowledgements.rtf",
            sha256:
                GPTKComponentInstaller.reviewedAcknowledgementsSha256
        ),
        frameworkNotice: GPTKComponentNotice(
            path: "redist/lib/external/D3DMetal.framework/Versions/A/Resources/LICENSE",
            sha256:
                GPTKComponentInstaller.reviewedFrameworkNoticeSha256
        )
    )
}

private func stubInstaller(
    responses: [URL: Data]
) -> GPTKComponentInstaller {
    GPTKComponentInstaller(
        fileManager: .default,
        componentCacheRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true),
        dataLoader: { request in
            guard let url = request.url,
                  let data = responses[url],
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                  ) else {
                throw GPTKComponentTestError.unexpectedRequest
            }
            return (data, response)
        },
        downloadLoader: { _ in
            throw GPTKComponentTestError.unexpectedRequest
        }
    )
}

private enum GPTKComponentTestError: Error {
    case unexpectedRequest
}
