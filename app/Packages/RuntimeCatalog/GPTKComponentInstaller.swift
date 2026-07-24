import CryptoKit
import Darwin
import Foundation
import Security

public struct GPTKComponentChannelPolicy: Sendable, Equatable {
    public var channelStatusURL: URL
    public var releaseManifestURL: URL
    public var manifestSigningPublicKey: Data
    public var distributorAuthorityID: String
    public var independentLegalApprovalID: String
    public var nonCommercialAttestationID: String
    public var exportControlsAttestationID: String
    public var takedownAttestationID: String

    public init(
        channelStatusURL: URL,
        releaseManifestURL: URL,
        manifestSigningPublicKey: Data,
        distributorAuthorityID: String,
        independentLegalApprovalID: String,
        nonCommercialAttestationID: String,
        exportControlsAttestationID: String,
        takedownAttestationID: String
    ) {
        self.channelStatusURL = channelStatusURL
        self.releaseManifestURL = releaseManifestURL
        self.manifestSigningPublicKey = manifestSigningPublicKey
        self.distributorAuthorityID = distributorAuthorityID
        self.independentLegalApprovalID = independentLegalApprovalID
        self.nonCommercialAttestationID = nonCommercialAttestationID
        self.exportControlsAttestationID = exportControlsAttestationID
        self.takedownAttestationID = takedownAttestationID
    }
}

public struct GPTKComponentChannelConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    public var channelStatusURL: URL?
    public var releaseManifestURL: URL?
    public var manifestSigningPublicKey: Data?
    public var distributorAuthorityID: String
    public var independentLegalApprovalID: String
    public var nonCommercialAttestationID: String
    public var exportControlsAttestationID: String
    public var takedownAttestationID: String

    public init(
        isEnabled: Bool,
        channelStatusURL: URL?,
        releaseManifestURL: URL?,
        manifestSigningPublicKey: Data?,
        distributorAuthorityID: String,
        independentLegalApprovalID: String,
        nonCommercialAttestationID: String,
        exportControlsAttestationID: String,
        takedownAttestationID: String
    ) {
        self.isEnabled = isEnabled
        self.channelStatusURL = channelStatusURL
        self.releaseManifestURL = releaseManifestURL
        self.manifestSigningPublicKey = manifestSigningPublicKey
        self.distributorAuthorityID = distributorAuthorityID
        self.independentLegalApprovalID = independentLegalApprovalID
        self.nonCommercialAttestationID = nonCommercialAttestationID
        self.exportControlsAttestationID = exportControlsAttestationID
        self.takedownAttestationID = takedownAttestationID
    }

    public var downloadPolicy: GPTKComponentChannelPolicy? {
        guard isEnabled,
              let channelStatusURL,
              channelStatusURL.scheme?.lowercased() == "https",
              channelStatusURL.lastPathComponent
                == "gptk-component-channel.json",
              let releaseManifestURL,
              releaseManifestURL.scheme?.lowercased() == "https",
              releaseManifestURL.lastPathComponent == "gptk-component-release.json",
              channelStatusURL.host?.lowercased()
                == releaseManifestURL.host?.lowercased(),
              let manifestSigningPublicKey,
              manifestSigningPublicKey.count == 32,
              Self.isAttestationID(distributorAuthorityID),
              Self.isAttestationID(independentLegalApprovalID),
              Self.isAttestationID(nonCommercialAttestationID),
              Self.isAttestationID(exportControlsAttestationID),
              Self.isAttestationID(takedownAttestationID) else {
            return nil
        }

        return GPTKComponentChannelPolicy(
            channelStatusURL: channelStatusURL,
            releaseManifestURL: releaseManifestURL,
            manifestSigningPublicKey: manifestSigningPublicKey,
            distributorAuthorityID: distributorAuthorityID,
            independentLegalApprovalID: independentLegalApprovalID,
            nonCommercialAttestationID: nonCommercialAttestationID,
            exportControlsAttestationID: exportControlsAttestationID,
            takedownAttestationID: takedownAttestationID
        )
    }

    public static func load(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> GPTKComponentChannelConfiguration {
        let bundledURL = bundle.url(forResource: "gptk-component", withExtension: "env")
        let developmentURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("config/gptk-component.env", isDirectory: false)
        let sourceURL = bundledURL ?? developmentURL
        let contents = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        let values = Dictionary(
            uniqueKeysWithValues: contents
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> (String, String)? in
                    guard !line.hasPrefix("#"),
                          let separator = line.firstIndex(of: "=") else {
                        return nil
                    }
                    return (
                        String(line[..<separator]),
                        String(line[line.index(after: separator)...])
                    )
                }
        )

        let publicKeyValue = values["SWITCHYARD_GPTK_MANIFEST_SIGNING_PUBLIC_KEY"] ?? ""
        return GPTKComponentChannelConfiguration(
            isEnabled: values["SWITCHYARD_GPTK_CHANNEL_ENABLED"] == "1",
            channelStatusURL: URL(
                string: values["SWITCHYARD_GPTK_CHANNEL_STATUS_URL"] ?? ""
            ),
            releaseManifestURL: URL(
                string: values["SWITCHYARD_GPTK_RELEASE_MANIFEST_URL"] ?? ""
            ),
            manifestSigningPublicKey: Data(base64Encoded: publicKeyValue),
            distributorAuthorityID: Self.resolved(
                values["SWITCHYARD_GPTK_DISTRIBUTOR_AUTHORITY_ID"]
            ),
            independentLegalApprovalID: Self.resolved(
                values["SWITCHYARD_GPTK_INDEPENDENT_LEGAL_APPROVAL_ID"]
            ),
            nonCommercialAttestationID: Self.resolved(
                values["SWITCHYARD_GPTK_NONCOMMERCIAL_ATTESTATION_ID"]
            ),
            exportControlsAttestationID: Self.resolved(
                values["SWITCHYARD_GPTK_EXPORT_CONTROLS_ATTESTATION_ID"]
            ),
            takedownAttestationID: Self.resolved(
                values["SWITCHYARD_GPTK_TAKEDOWN_ATTESTATION_ID"]
            )
        )
    }

    private static func resolved(_ value: String?) -> String {
        guard let value, !value.hasPrefix("__") else { return "" }
        return value
    }

    private static func isAttestationID(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{7,255}$"#,
            options: .regularExpression
        ) != nil
    }
}

public struct GPTKComponentChannelStatus: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var status: String
    public var releaseManifestSha256: String

    public init(
        schemaVersion: Int,
        status: String,
        releaseManifestSha256: String
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.releaseManifestSha256 = releaseManifestSha256
    }
}

public struct GPTKComponentNotice: Codable, Sendable, Equatable {
    public var path: String
    public var sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

public struct GPTKComponentLicense: Codable, Sendable, Equatable {
    public var identifier: String
    public var path: String
    public var url: URL
    public var sha256: String

    public init(identifier: String, path: String, url: URL, sha256: String) {
        self.identifier = identifier
        self.path = path
        self.url = url
        self.sha256 = sha256
    }
}

public struct GPTKComponentRelease: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var status: String
    public var componentID: String
    public var gptkVersion: String
    public var reviewDate: String
    public var sourceOuterImageSha256: String
    public var sourceEvaluationImageSha256: String
    public var archive: String
    public var archiveSha256: String
    public var archiveSize: UInt64
    public var contentTreeSha256: String
    public var permittedPaths: [String]
    public var appleSigningRequirement: String
    public var frameworkBundleIdentifier: String
    public var frameworkCDHash: String
    public var license: GPTKComponentLicense
    public var acknowledgements: GPTKComponentNotice
    public var frameworkNotice: GPTKComponentNotice

    public init(
        schemaVersion: Int,
        status: String,
        componentID: String,
        gptkVersion: String,
        reviewDate: String,
        sourceOuterImageSha256: String,
        sourceEvaluationImageSha256: String,
        archive: String,
        archiveSha256: String,
        archiveSize: UInt64,
        contentTreeSha256: String,
        permittedPaths: [String],
        appleSigningRequirement: String,
        frameworkBundleIdentifier: String,
        frameworkCDHash: String,
        license: GPTKComponentLicense,
        acknowledgements: GPTKComponentNotice,
        frameworkNotice: GPTKComponentNotice
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.componentID = componentID
        self.gptkVersion = gptkVersion
        self.reviewDate = reviewDate
        self.sourceOuterImageSha256 = sourceOuterImageSha256
        self.sourceEvaluationImageSha256 = sourceEvaluationImageSha256
        self.archive = archive
        self.archiveSha256 = archiveSha256
        self.archiveSize = archiveSize
        self.contentTreeSha256 = contentTreeSha256
        self.permittedPaths = permittedPaths
        self.appleSigningRequirement = appleSigningRequirement
        self.frameworkBundleIdentifier = frameworkBundleIdentifier
        self.frameworkCDHash = frameworkCDHash
        self.license = license
        self.acknowledgements = acknowledgements
        self.frameworkNotice = frameworkNotice
    }
}

public struct GPTKComponentConsentDocument: Sendable {
    public let release: GPTKComponentRelease
    public let manifestSha256: String
    public let licenseData: Data

    fileprivate let manifestData: Data

    fileprivate init(
        release: GPTKComponentRelease,
        manifestSha256: String,
        licenseData: Data,
        manifestData: Data
    ) {
        self.release = release
        self.manifestSha256 = manifestSha256
        self.licenseData = licenseData
        self.manifestData = manifestData
    }
}

public struct GPTKComponentInstallResult: Sendable, Equatable {
    public var componentID: String
    public var gptkVersion: String
    public var rootPath: String

    public init(componentID: String, gptkVersion: String, rootPath: String) {
        self.componentID = componentID
        self.gptkVersion = gptkVersion
        self.rootPath = rootPath
    }
}

public struct GPTKComponentInstaller: @unchecked Sendable {
    static let reviewedOuterImageSha256 =
        "ac8f6eeb2b9e5244d4c8eeb5b69b5cec099b560b143a7e5ef413945fc48b0f8f"
    static let reviewedEvaluationImageSha256 =
        "d49395fb07e536804d1da0858590e53f6aa6fab12512e18fd80a74c87f9f063c"
    static let reviewedLicenseSha256 =
        "5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8"
    static let reviewedAcknowledgementsSha256 =
        "6f3aa835f6d0d06f89997d0a346a209e39a8105521fd939e096c5b24dc0cb0a6"
    static let reviewedFrameworkNoticeSha256 =
        "553d0035773ddd1590045f8fdc3a4c6ead31e36336721aeca8421e88ed1c9f80"
    static let reviewedFrameworkCDHash =
        "bc0127bf883aff9aa2e483d3cebdfec6470fab3f15918e3b9aabf61cc14e53c9"
    static let reviewedSigningRequirement =
        #"anchor apple generic and identifier "com.apple.D3DMetal""#

    private static let maximumManifestSize = 128 * 1024
    private static let maximumChannelStatusSize = 16 * 1024
    private static let maximumLicenseSize = 2 * 1024 * 1024
    private static let maximumArchiveSize: UInt64 = 4 * 1024 * 1024 * 1024
    private static let allowedPermittedPaths: Set<String> = [
        "redist",
        "License.rtf",
        "Acknowledgements.rtf"
    ]

    private let fileManager: FileManager
    private let componentCacheRoot: URL
    private let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let downloadLoader: @Sendable (URLRequest) async throws -> (URL, URLResponse)

    public init(
        fileManager: FileManager = .default,
        componentCacheRoot: URL? = nil,
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.componentCacheRoot = componentCacheRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Switchyard", isDirectory: true)
                .appendingPathComponent("Runtimes", isDirectory: true)
                .appendingPathComponent("GPTK", isDirectory: true)
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("Switchyard-GPTK", isDirectory: true)
        dataLoader = { request in
            try await session.data(for: request)
        }
        downloadLoader = { request in
            try await session.download(for: request)
        }
    }

    init(
        fileManager: FileManager,
        componentCacheRoot: URL,
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        downloadLoader: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse)
    ) {
        self.fileManager = fileManager
        self.componentCacheRoot = componentCacheRoot
        self.dataLoader = dataLoader
        self.downloadLoader = downloadLoader
    }

    public func prepareConsent(
        policy: GPTKComponentChannelPolicy
    ) async throws -> GPTKComponentConsentDocument {
        let channelStatus = try await loadChannelStatus(policy: policy)
        let manifestData = try await loadVerifiedData(
            from: policy.releaseManifestURL,
            maximumSize: Self.maximumManifestSize,
            signingPublicKey: policy.manifestSigningPublicKey
        )
        let manifestSha256 = Self.sha256(of: manifestData)
        guard manifestSha256 == channelStatus.releaseManifestSha256 else {
            throw GPTKComponentInstallerError.channelManifestMismatch
        }

        let release: GPTKComponentRelease
        do {
            release = try JSONDecoder().decode(
                GPTKComponentRelease.self,
                from: manifestData
            )
        } catch {
            throw GPTKComponentInstallerError.invalidManifest(
                error.localizedDescription
            )
        }
        try Self.validate(release: release, against: policy)

        let licenseData = try await loadData(
            from: release.license.url,
            maximumSize: Self.maximumLicenseSize
        )
        guard Self.sha256(of: licenseData) == release.license.sha256 else {
            throw GPTKComponentInstallerError.licenseDigestMismatch
        }

        return GPTKComponentConsentDocument(
            release: release,
            manifestSha256: manifestSha256,
            licenseData: licenseData,
            manifestData: manifestData
        )
    }

    public func install(
        policy: GPTKComponentChannelPolicy,
        consent: GPTKComponentConsentDocument
    ) async throws -> GPTKComponentInstallResult {
        try Task.checkCancellation()
        guard Self.sha256(of: consent.manifestData) == consent.manifestSha256 else {
            throw GPTKComponentInstallerError.manifestChangedAfterConsent
        }
        let channelStatus = try await loadChannelStatus(policy: policy)
        guard channelStatus.releaseManifestSha256 == consent.manifestSha256 else {
            throw GPTKComponentInstallerError.channelManifestMismatch
        }
        try Self.validate(release: consent.release, against: policy)
        guard Self.sha256(of: consent.licenseData) == consent.release.license.sha256 else {
            throw GPTKComponentInstallerError.licenseDigestMismatch
        }

        try fileManager.createDirectory(
            at: componentCacheRoot,
            withIntermediateDirectories: true
        )
        let lockURL = componentCacheRoot.appendingPathComponent(
            ".gptk-component-install.lock",
            isDirectory: false
        )
        let lockDescriptor = try acquireInstallLock(at: lockURL)
        defer { releaseInstallLock(lockDescriptor) }
        try removeAbandonedStagingDirectories()

        let release = consent.release
        let archiveURL = policy.releaseManifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(release.archive, isDirectory: false)
        let request = request(for: archiveURL)
        let (downloadedArchive, response) = try await downloadLoader(request)
        try Self.validateHTTPResponse(response)
        try Task.checkCancellation()

        guard try fileSize(at: downloadedArchive) == release.archiveSize else {
            throw GPTKComponentInstallerError.archiveSizeMismatch
        }
        guard try sha256(of: downloadedArchive) == release.archiveSha256 else {
            throw GPTKComponentInstallerError.archiveDigestMismatch
        }

        let stagingRoot = componentCacheRoot.appendingPathComponent(
            ".component-install-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }

        try validateArchiveEntries(
            downloadedArchive,
            expectedRootName: release.componentID,
            permittedPaths: Set(release.permittedPaths)
        )
        try extractArchive(downloadedArchive, to: stagingRoot)
        let extractedRoot = stagingRoot.appendingPathComponent(
            release.componentID,
            isDirectory: true
        )
        try validateExtractedComponent(extractedRoot, release: release)

        let destination = componentCacheRoot.appendingPathComponent(
            "\(release.componentID)-\(release.archiveSha256.prefix(16))",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try validateExtractedComponent(destination, release: release)
                return GPTKComponentInstallResult(
                    componentID: release.componentID,
                    gptkVersion: release.gptkVersion,
                    rootPath: destination.path
                )
            } catch {
                throw GPTKComponentInstallerError.destinationConflict
            }
        }

        try fileManager.moveItem(at: extractedRoot, to: destination)
        return GPTKComponentInstallResult(
            componentID: release.componentID,
            gptkVersion: release.gptkVersion,
            rootPath: destination.path
        )
    }

    public static func validate(
        release: GPTKComponentRelease,
        against policy: GPTKComponentChannelPolicy
    ) throws {
        guard release.schemaVersion == 1 else {
            throw GPTKComponentInstallerError.unsupportedManifestVersion(
                release.schemaVersion
            )
        }
        guard release.status == "enabled" else {
            throw GPTKComponentInstallerError.channelDisabled
        }
        guard policy.channelStatusURL.scheme?.lowercased() == "https",
              policy.channelStatusURL.lastPathComponent
                == "gptk-component-channel.json",
              policy.releaseManifestURL.scheme?.lowercased() == "https",
              policy.releaseManifestURL.lastPathComponent
                == "gptk-component-release.json",
              policy.channelStatusURL.host?.lowercased()
                == policy.releaseManifestURL.host?.lowercased(),
              policy.manifestSigningPublicKey.count == 32,
              isAttestationID(policy.distributorAuthorityID),
              isAttestationID(policy.independentLegalApprovalID),
              isAttestationID(policy.nonCommercialAttestationID),
              isAttestationID(policy.exportControlsAttestationID),
              isAttestationID(policy.takedownAttestationID) else {
            throw GPTKComponentInstallerError.invalidChannelPolicy
        }
        guard isSafeIdentifier(release.componentID) else {
            throw GPTKComponentInstallerError.invalidComponentID
        }
        guard release.gptkVersion == "3.0",
              release.reviewDate == "2026-07-22",
              release.sourceOuterImageSha256 == reviewedOuterImageSha256,
              release.sourceEvaluationImageSha256
                == reviewedEvaluationImageSha256 else {
            throw GPTKComponentInstallerError.unreviewedGPTKRelease
        }
        guard release.archive == URL(fileURLWithPath: release.archive)
            .lastPathComponent,
              !release.archive.hasPrefix("."),
              release.archive.lowercased().hasSuffix(".zip") else {
            throw GPTKComponentInstallerError.invalidArchiveName
        }
        guard release.archiveSize > 0,
              release.archiveSize <= maximumArchiveSize else {
            throw GPTKComponentInstallerError.invalidArchiveSize
        }
        guard isSHA256(release.archiveSha256),
              isSHA256(release.contentTreeSha256) else {
            throw GPTKComponentInstallerError.invalidArchiveDigest
        }
        let permittedPaths = Set(release.permittedPaths)
        guard !permittedPaths.isEmpty,
              permittedPaths.count == release.permittedPaths.count,
              permittedPaths.isSubset(of: allowedPermittedPaths),
              permittedPaths.contains("redist"),
              permittedPaths.contains("License.rtf"),
              permittedPaths.contains("Acknowledgements.rtf") else {
            throw GPTKComponentInstallerError.invalidPermittedPaths
        }
        guard release.appleSigningRequirement == reviewedSigningRequirement,
              release.frameworkBundleIdentifier == "com.apple.D3DMetal",
              release.frameworkCDHash == reviewedFrameworkCDHash else {
            throw GPTKComponentInstallerError.unreviewedSigningIdentity
        }
        guard release.license.identifier == "EA18380",
              release.license.path == "License.rtf",
              release.license.sha256 == reviewedLicenseSha256,
              release.acknowledgements
                == GPTKComponentNotice(
                    path: "Acknowledgements.rtf",
                    sha256: reviewedAcknowledgementsSha256
                ),
              release.frameworkNotice
                == GPTKComponentNotice(
                    path: "redist/lib/external/D3DMetal.framework/Versions/A/Resources/LICENSE",
                    sha256: reviewedFrameworkNoticeSha256
                ) else {
            throw GPTKComponentInstallerError.unreviewedNotices
        }
        let manifestDirectory = policy.releaseManifestURL.deletingLastPathComponent()
        guard release.license.url.scheme?.lowercased() == "https",
              release.license.url.deletingLastPathComponent()
                == manifestDirectory,
              release.license.url.lastPathComponent == "License.rtf" else {
            throw GPTKComponentInstallerError.untrustedLicenseURL
        }
    }

    private func loadChannelStatus(
        policy: GPTKComponentChannelPolicy
    ) async throws -> GPTKComponentChannelStatus {
        let data = try await loadVerifiedData(
            from: policy.channelStatusURL,
            maximumSize: Self.maximumChannelStatusSize,
            signingPublicKey: policy.manifestSigningPublicKey
        )
        let channelStatus: GPTKComponentChannelStatus
        do {
            channelStatus = try JSONDecoder().decode(
                GPTKComponentChannelStatus.self,
                from: data
            )
        } catch {
            throw GPTKComponentInstallerError.invalidChannelStatus(
                error.localizedDescription
            )
        }
        guard channelStatus.schemaVersion == 1,
              Self.isSHA256(channelStatus.releaseManifestSha256) else {
            throw GPTKComponentInstallerError.invalidChannelStatus(
                "unsupported schema or manifest digest"
            )
        }
        guard channelStatus.status == "enabled" else {
            throw GPTKComponentInstallerError.channelDisabled
        }
        return channelStatus
    }

    private func loadVerifiedData(
        from url: URL,
        maximumSize: Int,
        signingPublicKey: Data
    ) async throws -> Data {
        let data = try await loadData(from: url, maximumSize: maximumSize)
        let signaturePayload = try await loadData(
            from: url.appendingPathExtension("sig"),
            maximumSize: 4 * 1024
        )
        let signature = try decodeSignature(signaturePayload)
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: signingPublicKey
            )
        } catch {
            throw GPTKComponentInstallerError.invalidManifestSigningKey
        }
        guard publicKey.isValidSignature(signature, for: data) else {
            throw GPTKComponentInstallerError.invalidManifestSignature
        }
        return data
    }

    private func loadData(
        from url: URL,
        maximumSize: Int
    ) async throws -> Data {
        let (data, response) = try await dataLoader(request(for: url))
        try Self.validateHTTPResponse(response)
        guard data.count <= maximumSize else {
            throw GPTKComponentInstallerError.responseTooLarge
        }
        return data
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        )
        request.setValue("Switchyard", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }

    private func decodeSignature(_ data: Data) throws -> Data {
        if data.count == 64 {
            return data
        }
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let signature = Data(base64Encoded: value),
              signature.count == 64 else {
            throw GPTKComponentInstallerError.invalidManifestSignature
        }
        return signature
    }

    private func validateExtractedComponent(
        _ root: URL,
        release: GPTKComponentRelease
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw GPTKComponentInstallerError.componentRootMissing
        }
        try validateNoEscapingSymbolicLinks(under: root)
        try validatePermittedTree(
            under: root,
            permittedPaths: Set(release.permittedPaths)
        )
        try validateNotice(
            release.license.path,
            sha256: release.license.sha256,
            under: root
        )
        try validateNotice(
            release.acknowledgements.path,
            sha256: release.acknowledgements.sha256,
            under: root
        )
        try validateNotice(
            release.frameworkNotice.path,
            sha256: release.frameworkNotice.sha256,
            under: root
        )
        try validateContentTreeDigest(
            under: root,
            expected: release.contentTreeSha256
        )
        let validation = RuntimeLocator(fileManager: fileManager)
            .validateGPTK(at: root.path)
        guard validation.status == .ok else {
            throw GPTKComponentInstallerError.invalidGPTKPayload(
                validation.message
            )
        }
        try validateReviewedFramework(under: root, release: release)
    }

    private func validateNotice(
        _ relativePath: String,
        sha256 expected: String,
        under root: URL
    ) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              try sha256(of: url) == expected else {
            throw GPTKComponentInstallerError.noticeMissingOrModified(
                relativePath
            )
        }
    }

    private func validateReviewedFramework(
        under root: URL,
        release: GPTKComponentRelease
    ) throws {
        let frameworkURL = root.appendingPathComponent(
            "redist/lib/external/D3DMetal.framework",
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: frameworkURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw GPTKComponentInstallerError.reviewedFrameworkMissing
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            release.appleSigningRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            throw GPTKComponentInstallerError.invalidAppleSigningRequirement
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            frameworkURL as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
        let code,
        SecStaticCodeCheckValidity(
            code,
            SecCSFlags(
                rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
            ),
            requirement
        ) == errSecSuccess else {
            throw GPTKComponentInstallerError.invalidFrameworkSignature
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        information[kSecCodeInfoIdentifier as String] as? String
            == release.frameworkBundleIdentifier,
        Self.fullCDHashHexValues(from: information).contains(
            release.frameworkCDHash
        ) else {
            throw GPTKComponentInstallerError.frameworkIdentityMismatch
        }
    }

    static func fullCDHashHexValues(
        from signingInformation: [String: Any]
    ) -> [String] {
        // kSecCodeInfoCdHashes exposes the traditional truncated 20-byte
        // values. Security also publishes each complete digest under this
        // stable signing-information key.
        guard let hashes = signingInformation["cdhashes-full"] as? [Data] else {
            return []
        }
        return hashes.compactMap { hash in
            guard hash.count == 32 else { return nil }
            return hash.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func validatePermittedTree(
        under root: URL,
        permittedPaths: Set<String>
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw GPTKComponentInstallerError.componentRootMissing
        }

        for case let url as URL in enumerator {
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            guard permittedPaths.contains(where: {
                relativePath == $0 || relativePath.hasPrefix($0 + "/")
            }) else {
                throw GPTKComponentInstallerError.unlistedPayloadPath(
                    relativePath
                )
            }
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isDirectory == true
                || values.isRegularFile == true
                || values.isSymbolicLink == true else {
                throw GPTKComponentInstallerError.unsupportedPayloadEntry(
                    relativePath
                )
            }
        }
    }

    private func validateNoEscapingSymbolicLinks(under root: URL) throws {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw GPTKComponentInstallerError.componentRootMissing
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let target = try fileManager.destinationOfSymbolicLink(
                atPath: url.path
            )
            guard !target.hasPrefix("/") else {
                throw GPTKComponentInstallerError.escapingSymbolicLink
            }
            let resolved = URL(
                fileURLWithPath: target,
                relativeTo: url.deletingLastPathComponent()
            )
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
                throw GPTKComponentInstallerError.escapingSymbolicLink
            }
        }
    }

    private func validateContentTreeDigest(
        under root: URL,
        expected: String
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            throw GPTKComponentInstallerError.componentRootMissing
        }

        var entries: [(path: String, line: String)] = []
        for case let url as URL in enumerator {
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                let target = try fileManager.destinationOfSymbolicLink(
                    atPath: url.path
                )
                entries.append((
                    relativePath,
                    "link ./\(relativePath) \(target)\n"
                ))
            } else if values.isRegularFile == true {
                entries.append((
                    relativePath,
                    "file ./\(relativePath) \(try sha256(of: url))\n"
                ))
            }
        }
        entries.sort {
            $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        let actual = Self.sha256(
            of: Data(entries.map(\.line).joined().utf8)
        )
        guard actual == expected else {
            throw GPTKComponentInstallerError.contentTreeDigestMismatch
        }
    }

    func validateArchiveEntries(
        _ archive: URL,
        expectedRootName: String,
        permittedPaths: Set<String>
    ) throws {
        let listingData = try runArchiveTool(
            "/usr/bin/zipinfo",
            arguments: ["-1", archive.path]
        )
        guard let listing = String(data: listingData, encoding: .utf8) else {
            throw GPTKComponentInstallerError.archiveInspectionFailed(
                "zipinfo returned non-UTF-8 paths"
            )
        }
        let entries = listing
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !entries.isEmpty, entries.count <= 100_000 else {
            throw GPTKComponentInstallerError.archiveInspectionFailed(
                "archive entry count is invalid"
            )
        }
        var normalizedEntries: Set<String> = []
        var containsRoot = false
        for entry in entries {
            guard !entry.hasPrefix("/"),
                  !entry.contains("\\"),
                  entry.unicodeScalars.allSatisfy({
                      $0.value >= 0x20 && $0.value != 0x7f
                  }) else {
                throw GPTKComponentInstallerError.unsafeArchiveEntry(entry)
            }
            let components = entry
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty,
                  !components.contains("."),
                  !components.contains("..") else {
                throw GPTKComponentInstallerError.unsafeArchiveEntry(entry)
            }
            guard components[0] == expectedRootName else {
                throw GPTKComponentInstallerError.unsafeArchiveEntry(entry)
            }
            containsRoot = true

            let collisionKey = entry
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard normalizedEntries.insert(collisionKey).inserted else {
                throw GPTKComponentInstallerError.unsafeArchiveEntry(entry)
            }

            let relativeComponents = Array(components.dropFirst())
            if !relativeComponents.isEmpty {
                let relativePath = relativeComponents.joined(separator: "/")
                guard permittedPaths.contains(where: {
                    relativePath == $0 || relativePath.hasPrefix($0 + "/")
                }) else {
                    throw GPTKComponentInstallerError.unlistedPayloadPath(
                        relativePath
                    )
                }
            }
        }
        guard containsRoot else {
            throw GPTKComponentInstallerError.componentRootMissing
        }

        let longListingData = try runArchiveTool(
            "/usr/bin/zipinfo",
            arguments: ["-l", archive.path]
        )
        guard let longListing = String(
            data: longListingData,
            encoding: .utf8
        ) else {
            throw GPTKComponentInstallerError.archiveInspectionFailed(
                "zipinfo returned an invalid long listing"
            )
        }
        let typeLines = longListing
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                guard line.count >= 10,
                      let first = line.first,
                      ["-", "d", "l"].contains(first) else {
                    return false
                }
                return line.dropFirst().prefix(9).allSatisfy {
                    "rwxstST-".contains($0)
                }
            }
        guard typeLines.count == entries.count else {
            throw GPTKComponentInstallerError.archiveInspectionFailed(
                "archive entry metadata is incomplete"
            )
        }

        var totalUncompressedSize: UInt64 = 0
        let maximumExpandedSize: UInt64 = 8 * 1024 * 1024 * 1024
        for (entry, typeLine) in zip(entries, typeLines) {
            let fields = typeLine.split(
                whereSeparator: \.isWhitespace
            )
            guard fields.count >= 4,
                  let uncompressedSize = UInt64(fields[3]),
                  uncompressedSize <= maximumExpandedSize,
                  totalUncompressedSize
                    <= maximumExpandedSize - uncompressedSize else {
                throw GPTKComponentInstallerError.archiveInspectionFailed(
                    "archive expands beyond the allowed size"
                )
            }
            totalUncompressedSize += uncompressedSize

            switch typeLine.first {
            case "-", "d":
                continue
            case "l":
                let targetData = try runArchiveTool(
                    "/usr/bin/unzip",
                    arguments: ["-p", archive.path, entry]
                )
                guard targetData.count <= 4_096,
                      let target = String(
                        data: targetData,
                        encoding: .utf8
                      ),
                      isSafeArchiveLink(
                        entry: entry,
                        target: target,
                        expectedRootName: expectedRootName
                      ) else {
                    throw GPTKComponentInstallerError.escapingSymbolicLink
                }
            default:
                throw GPTKComponentInstallerError.unsupportedPayloadEntry(
                    entry
                )
            }
        }

        _ = try runArchiveTool(
            "/usr/bin/unzip",
            arguments: ["-tqq", archive.path]
        )
    }

    private func isSafeArchiveLink(
        entry: String,
        target: String,
        expectedRootName: String
    ) -> Bool {
        guard !target.isEmpty,
              !target.hasPrefix("/"),
              !target.contains("\\"),
              !target.contains("\0"),
              !target.contains("\n"),
              !target.contains("\r") else {
            return false
        }
        var resolved = entry
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropLast()
            .map(String.init)
        for component in target.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard resolved.count > 1 else { return false }
                resolved.removeLast()
            default:
                resolved.append(component)
            }
        }
        return resolved.first == expectedRootName
    }

    private func runArchiveTool(
        _ executablePath: String,
        arguments: [String]
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? URL(fileURLWithPath: executablePath).lastPathComponent
            throw GPTKComponentInstallerError.archiveInspectionFailed(message)
        }
        return output
    }

    private func extractArchive(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "ditto failed"
            throw GPTKComponentInstallerError.archiveExtractionFailed(message)
        }
    }

    private func acquireInstallLock(at lockURL: URL) throws -> Int32 {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: lockURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            throw GPTKComponentInstallerError.installAlreadyRunning
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw GPTKComponentInstallerError.installLockFailed(
                String(cString: strerror(errno))
            )
        }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            let errorNumber = errno
            Darwin.close(descriptor)
            if errorNumber == EACCES || errorNumber == EAGAIN {
                throw GPTKComponentInstallerError.installAlreadyRunning
            }
            throw GPTKComponentInstallerError.installLockFailed(
                String(cString: strerror(errorNumber))
            )
        }
        return descriptor
    }

    private func releaseInstallLock(_ descriptor: Int32) {
        var lock = Darwin.flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        Darwin.close(descriptor)
    }

    private func removeAbandonedStagingDirectories() throws {
        guard fileManager.fileExists(atPath: componentCacheRoot.path) else {
            return
        }
        let entries = try fileManager.contentsOfDirectory(
            at: componentCacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for entry in entries
            where entry.lastPathComponent.hasPrefix(".component-install-") {
            try fileManager.removeItem(at: entry)
        }
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size >= 0 else {
            throw GPTKComponentInstallerError.invalidArchiveSize
        }
        return UInt64(size)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw GPTKComponentInstallerError.invalidHTTPResponse
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw GPTKComponentInstallerError.httpFailure(response.statusCode)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isAttestationID(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{7,255}$"#,
            options: .regularExpression
        ) != nil
    }
}

public enum GPTKComponentInstallerError: LocalizedError, Equatable, Sendable {
    case archiveDigestMismatch
    case archiveExtractionFailed(String)
    case archiveInspectionFailed(String)
    case archiveSizeMismatch
    case channelManifestMismatch
    case channelDisabled
    case componentRootMissing
    case contentTreeDigestMismatch
    case destinationConflict
    case escapingSymbolicLink
    case frameworkIdentityMismatch
    case httpFailure(Int)
    case installAlreadyRunning
    case installLockFailed(String)
    case invalidAppleSigningRequirement
    case invalidArchiveDigest
    case invalidArchiveName
    case invalidArchiveSize
    case invalidChannelPolicy
    case invalidChannelStatus(String)
    case invalidComponentID
    case invalidFrameworkSignature
    case invalidGPTKPayload(String)
    case invalidHTTPResponse
    case invalidManifest(String)
    case invalidManifestSignature
    case invalidManifestSigningKey
    case invalidPermittedPaths
    case licenseDigestMismatch
    case manifestChangedAfterConsent
    case noticeMissingOrModified(String)
    case responseTooLarge
    case reviewedFrameworkMissing
    case unlistedPayloadPath(String)
    case unreviewedGPTKRelease
    case unreviewedNotices
    case unreviewedSigningIdentity
    case unsupportedManifestVersion(Int)
    case unsupportedPayloadEntry(String)
    case unsafeArchiveEntry(String)
    case untrustedLicenseURL

    public var errorDescription: String? {
        switch self {
        case .archiveDigestMismatch:
            "The downloaded GPTK component checksum does not match its signed manifest."
        case .archiveExtractionFailed(let message):
            "The GPTK component archive could not be extracted: \(message)"
        case .archiveInspectionFailed(let message):
            "The GPTK component archive could not be inspected safely: \(message)"
        case .archiveSizeMismatch:
            "The downloaded GPTK component size does not match its signed manifest."
        case .channelManifestMismatch:
            "The GPTK channel no longer points to the manifest that was reviewed."
        case .channelDisabled:
            "The GPTK component channel has been disabled remotely."
        case .componentRootMissing:
            "The GPTK component archive does not contain its expected root folder."
        case .contentTreeDigestMismatch:
            "The extracted GPTK component file tree does not match its signed manifest."
        case .destinationConflict:
            "A different GPTK component already exists at the immutable destination."
        case .escapingSymbolicLink:
            "The GPTK component contains a symbolic link outside its installation folder."
        case .frameworkIdentityMismatch:
            "The D3DMetal framework identity does not match the reviewed GPTK 3 framework."
        case .httpFailure(let status):
            "The GPTK component server returned HTTP \(status)."
        case .installAlreadyRunning:
            "Another GPTK component installation is already in progress."
        case .installLockFailed(let message):
            "The GPTK component installation lock could not be acquired: \(message)"
        case .invalidAppleSigningRequirement:
            "The reviewed Apple code-signing requirement could not be created."
        case .invalidArchiveDigest:
            "The GPTK component manifest has an invalid archive digest."
        case .invalidArchiveName:
            "The GPTK component manifest has an unsafe archive name."
        case .invalidArchiveSize:
            "The GPTK component manifest has an invalid archive size."
        case .invalidChannelPolicy:
            "This build does not contain a complete approved GPTK component policy."
        case .invalidChannelStatus(let message):
            "The GPTK component channel status is invalid: \(message)"
        case .invalidComponentID:
            "The GPTK component manifest has an invalid component identifier."
        case .invalidFrameworkSignature:
            "The D3DMetal framework does not satisfy the reviewed Apple signature requirement."
        case .invalidGPTKPayload(let message):
            "The downloaded GPTK component failed runtime validation: \(message)"
        case .invalidHTTPResponse:
            "The GPTK component server returned an invalid response."
        case .invalidManifest(let message):
            "The GPTK component manifest is invalid: \(message)"
        case .invalidManifestSignature:
            "The GPTK component manifest signature is invalid."
        case .invalidManifestSigningKey:
            "This build has an invalid GPTK manifest signing key."
        case .invalidPermittedPaths:
            "The GPTK component manifest contains paths outside the reviewed distribution scope."
        case .licenseDigestMismatch:
            "The Apple license does not match the reviewed GPTK 3 license."
        case .manifestChangedAfterConsent:
            "The GPTK component manifest changed after the license was shown."
        case .noticeMissingOrModified(let path):
            "A required GPTK notice is missing or modified: \(path)"
        case .responseTooLarge:
            "The GPTK component server response is larger than allowed."
        case .reviewedFrameworkMissing:
            "The reviewed D3DMetal framework is missing from the GPTK component."
        case .unlistedPayloadPath(let path):
            "The GPTK component contains an unlisted path: \(path)"
        case .unreviewedGPTKRelease:
            "This GPTK version or source image has not passed Switchyard's release review."
        case .unreviewedNotices:
            "The GPTK component notices do not match the reviewed GPTK 3 notices."
        case .unreviewedSigningIdentity:
            "The GPTK component signing identity does not match the reviewed GPTK 3 framework."
        case .unsupportedManifestVersion(let version):
            "GPTK component manifest version \(version) is not supported."
        case .unsupportedPayloadEntry(let path):
            "The GPTK component contains an unsupported filesystem entry: \(path)"
        case .unsafeArchiveEntry(let path):
            "The GPTK component archive contains an unsafe path: \(path)"
        case .untrustedLicenseURL:
            "The GPTK component manifest points to an untrusted license location."
        }
    }
}
