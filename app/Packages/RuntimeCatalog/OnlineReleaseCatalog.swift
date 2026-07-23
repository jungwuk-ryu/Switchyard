import Foundation

public struct PublishedGitHubRelease: Sendable, Equatable {
    public var tagName: String
    public var webURL: URL
    public var publishedAt: Date

    public init(tagName: String, webURL: URL, publishedAt: Date) {
        self.tagName = tagName
        self.webURL = webURL
        self.publishedAt = publishedAt
    }
}

public struct SwitchyardReleaseSnapshot: Sendable, Equatable {
    public var appRelease: PublishedGitHubRelease
    public var runtimeRelease: PublishedGitHubRelease
    public var runtimeManifest: PublishedRuntimeRelease

    public init(
        appRelease: PublishedGitHubRelease,
        runtimeRelease: PublishedGitHubRelease,
        runtimeManifest: PublishedRuntimeRelease
    ) {
        self.appRelease = appRelease
        self.runtimeRelease = runtimeRelease
        self.runtimeManifest = runtimeManifest
    }
}

public struct OfficialRuntimeRelease: Identifiable, Sendable, Equatable {
    public var release: PublishedGitHubRelease
    public var manifestURL: URL
    public var manifest: PublishedRuntimeRelease

    public var id: String {
        "\(manifest.runtimeID)-\(manifest.archiveSha256)"
    }

    public var managedInstallationID: String {
        PublishedRuntimeInstaller.managedInstallationID(
            runtimeID: manifest.runtimeID,
            archiveSha256: manifest.archiveSha256
        )
    }

    public init(
        release: PublishedGitHubRelease,
        manifestURL: URL,
        manifest: PublishedRuntimeRelease
    ) {
        self.release = release
        self.manifestURL = manifestURL
        self.manifest = manifest
    }

    public func installationPolicy(
        trustedDeveloperTeamID: String
    ) throws -> PublishedRuntimePolicy {
        guard !trustedDeveloperTeamID.isEmpty,
              manifest.developerTeamID == trustedDeveloperTeamID else {
            throw OfficialRuntimeReleaseError.untrustedDeveloperTeam
        }
        let policy = PublishedRuntimePolicy(
            sourceRevision: manifest.sourceRevision,
            releaseManifestURL: manifestURL,
            developerTeamID: trustedDeveloperTeamID,
            archiveSha256: manifest.archiveSha256,
            archiveSize: manifest.archiveSize,
            notarizationID: manifest.notarizationID
        )
        try PublishedRuntimeInstaller.validate(release: manifest, against: policy)
        return policy
    }
}

public enum OfficialRuntimeReleaseError: LocalizedError, Equatable, Sendable {
    case untrustedDeveloperTeam

    public var errorDescription: String? {
        switch self {
        case .untrustedDeveloperTeam:
            String(
                localized: "This app build does not trust the Developer ID team that signed the runtime.",
                bundle: SwitchyardStrings.bundle
            )
        }
    }
}

/// Numeric release versions used by Switchyard's `vMAJOR.MINOR.PATCH` tags.
/// Pre-release and build suffixes do not affect the comparison because GitHub's
/// latest-release endpoint already excludes pre-releases.
public struct ReleaseVersion: Comparable, Sendable {
    private let components: [Int]

    public init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }
        normalized = String(normalized.split(separator: "+", maxSplits: 1).first ?? "")
        normalized = String(normalized.split(separator: "-", maxSplits: 1).first ?? "")

        let rawComponents = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(rawComponents.count)
        for component in rawComponents {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let number = Int(component) else {
                return nil
            }
            parsed.append(number)
        }
        while parsed.count > 1, parsed.last == 0 {
            parsed.removeLast()
        }
        components = parsed
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

public struct OnlineReleaseCatalog: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let appReleaseURL = URL(
        string: "https://api.github.com/repos/jungwuk-ryu/Switchyard/releases/latest"
    )!
    private static let runtimeReleaseURL = URL(
        string: "https://api.github.com/repos/jungwuk-ryu/switchyard-wine/releases/latest"
    )!
    private static let runtimeReleasesURL = URL(
        string: "https://api.github.com/repos/jungwuk-ryu/switchyard-wine/releases?per_page=20"
    )!
    private static let runtimeManifestAssetName = "switchyard-runtime-release.json"
    private static let maximumReleaseResponseSize = 2 * 1024 * 1024
    private static let maximumManifestSize = 64 * 1024

    private let dataLoader: DataLoader

    public init(session: URLSession = .shared) {
        dataLoader = { request in
            try await session.data(for: request)
        }
    }

    init(dataLoader: @escaping DataLoader) {
        self.dataLoader = dataLoader
    }

    public func latestReleases() async throws -> SwitchyardReleaseSnapshot {
        async let appResponse = latestRelease(at: Self.appReleaseURL)
        async let runtimeResponse = latestRelease(at: Self.runtimeReleaseURL)
        let (app, runtime) = try await (appResponse, runtimeResponse)

        guard Self.isTrustedReleaseURL(
            app.webURL,
            pathPrefix: "/jungwuk-ryu/Switchyard/releases/"
        ), Self.isTrustedReleaseURL(
            runtime.webURL,
            pathPrefix: "/jungwuk-ryu/switchyard-wine/releases/"
        ) else {
            throw OnlineReleaseCatalogError.untrustedReleaseURL
        }

        guard let appSummary = app.summary,
              let runtimeSummary = runtime.summary else {
            throw OnlineReleaseCatalogError.invalidReleaseResponse(
                String(
                    localized: "A published release is missing its publication date.",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        guard let manifestURL = runtime.assets.first(where: {
            $0.name == Self.runtimeManifestAssetName
        })?.downloadURL else {
            throw OnlineReleaseCatalogError.runtimeManifestMissing
        }
        guard Self.isTrustedRuntimeManifestURL(manifestURL) else {
            throw OnlineReleaseCatalogError.untrustedRuntimeManifestURL
        }

        let manifest = try await runtimeManifest(at: manifestURL)
        return SwitchyardReleaseSnapshot(
            appRelease: appSummary,
            runtimeRelease: runtimeSummary,
            runtimeManifest: manifest
        )
    }

    public func officialRuntimeReleases() async throws -> [OfficialRuntimeRelease] {
        let releases = try await releaseList(at: Self.runtimeReleasesURL)
        let candidates = try releases.compactMap {
            try officialRuntimeCandidate(from: $0)
        }

        let loaded = await withTaskGroup(
            of: (Int, OfficialRuntimeRelease?).self
        ) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    do {
                        let manifest = try await runtimeManifest(
                            at: candidate.manifestURL
                        )
                        return (
                            index,
                            OfficialRuntimeRelease(
                                release: candidate.release,
                                manifestURL: candidate.manifestURL,
                                manifest: manifest
                            )
                        )
                    } catch {
                        return (index, nil)
                    }
                }
            }

            var loaded: [(Int, OfficialRuntimeRelease?)] = []
            for await release in group {
                loaded.append(release)
            }
            return loaded
                .sorted { $0.0 < $1.0 }
                .compactMap(\.1)
        }
        guard !loaded.isEmpty || candidates.isEmpty else {
            throw OnlineReleaseCatalogError.invalidRuntimeManifest(
                String(
                    localized: "No published runtime manifest could be loaded.",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        return loaded
    }

    private func latestRelease(at url: URL) async throws -> GitHubReleaseResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Switchyard", forHTTPHeaderField: "User-Agent")

        let data = try await responseData(for: request, maximumSize: Self.maximumReleaseResponseSize)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GitHubReleaseResponse.self, from: data)
        } catch {
            throw OnlineReleaseCatalogError.invalidReleaseResponse(error.localizedDescription)
        }
    }

    private func releaseList(at url: URL) async throws -> [GitHubReleaseResponse] {
        let request = githubRequest(for: url)
        let data = try await responseData(
            for: request,
            maximumSize: Self.maximumReleaseResponseSize
        )
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([GitHubReleaseResponse].self, from: data)
        } catch {
            throw OnlineReleaseCatalogError.invalidReleaseResponse(
                error.localizedDescription
            )
        }
    }

    private func officialRuntimeCandidate(
        from response: GitHubReleaseResponse
    ) throws -> (release: PublishedGitHubRelease, manifestURL: URL)? {
        guard response.draft != true, response.prerelease != true else {
            return nil
        }
        guard Self.isTrustedReleaseURL(
            response.webURL,
            pathPrefix: "/jungwuk-ryu/switchyard-wine/releases/"
        ) else {
            throw OnlineReleaseCatalogError.untrustedReleaseURL
        }
        guard let summary = response.summary else {
            throw OnlineReleaseCatalogError.invalidReleaseResponse(
                String(
                    localized: "A published release is missing its publication date.",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        guard let manifestURL = response.assets.first(where: {
            $0.name == Self.runtimeManifestAssetName
        })?.downloadURL else {
            return nil
        }
        guard Self.isTrustedRuntimeManifestURL(manifestURL) else {
            throw OnlineReleaseCatalogError.untrustedRuntimeManifestURL
        }
        return (summary, manifestURL)
    }

    private func githubRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Switchyard", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func runtimeManifest(at url: URL) async throws -> PublishedRuntimeRelease {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Switchyard", forHTTPHeaderField: "User-Agent")

        let data = try await responseData(for: request, maximumSize: Self.maximumManifestSize)
        let release: PublishedRuntimeRelease
        do {
            release = try JSONDecoder().decode(PublishedRuntimeRelease.self, from: data)
        } catch {
            throw OnlineReleaseCatalogError.invalidRuntimeManifest(error.localizedDescription)
        }
        guard Self.isPlausibleRuntimeManifest(release) else {
            throw OnlineReleaseCatalogError.invalidRuntimeManifest(
                String(
                    localized: "The release metadata is incomplete.",
                    bundle: SwitchyardStrings.bundle
                )
            )
        }
        return release
    }

    private func responseData(for request: URLRequest, maximumSize: Int) async throws -> Data {
        let (data, response) = try await dataLoader(request)
        guard let response = response as? HTTPURLResponse else {
            throw OnlineReleaseCatalogError.invalidHTTPResponse
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw OnlineReleaseCatalogError.httpFailure(response.statusCode)
        }
        guard data.count <= maximumSize else {
            throw OnlineReleaseCatalogError.responseTooLarge
        }
        return data
    }

    private static func isTrustedReleaseURL(_ url: URL, pathPrefix: String) -> Bool {
        url.scheme == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix(pathPrefix)
    }

    private static func isTrustedRuntimeManifestURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix(
                "/jungwuk-ryu/switchyard-wine/releases/download/"
            )
            && url.lastPathComponent == runtimeManifestAssetName
    }

    private static func isPlausibleRuntimeManifest(_ release: PublishedRuntimeRelease) -> Bool {
        release.schemaVersion == 1
            && release.sourceRevision.count == 40
            && release.sourceRevision.allSatisfy(\.isHexDigit)
            && release.archiveSha256.count == 64
            && release.archiveSha256.allSatisfy(\.isHexDigit)
            && release.archiveSize > 0
            && release.platform == "macos"
            && release.hostArchitecture == "x86_64"
            && Set(release.peArchitectures).isSuperset(of: ["i386", "x86_64"])
            && release.notarizationStatus == "Accepted"
            && !release.notarizationID.isEmpty
    }
}

private struct GitHubReleaseResponse: Decodable, Sendable {
    var tagName: String
    var webURL: URL
    var publishedAt: Date?
    var assets: [GitHubReleaseAsset]
    var draft: Bool?
    var prerelease: Bool?

    var summary: PublishedGitHubRelease? {
        publishedAt.map {
            PublishedGitHubRelease(tagName: tagName, webURL: webURL, publishedAt: $0)
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case webURL = "html_url"
        case publishedAt = "published_at"
        case assets
        case draft
        case prerelease
    }
}

private struct GitHubReleaseAsset: Decodable, Sendable {
    var name: String
    var downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

public enum OnlineReleaseCatalogError: LocalizedError, Equatable, Sendable {
    case invalidHTTPResponse
    case httpFailure(Int)
    case responseTooLarge
    case invalidReleaseResponse(String)
    case untrustedReleaseURL
    case runtimeManifestMissing
    case untrustedRuntimeManifestURL
    case invalidRuntimeManifest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return String(localized: "GitHub returned an invalid response.", bundle: SwitchyardStrings.bundle)
        case .httpFailure(let statusCode):
            return String(localized: "GitHub returned HTTP \(statusCode).", bundle: SwitchyardStrings.bundle)
        case .responseTooLarge:
            return String(
                localized: "GitHub returned release metadata that was too large.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidReleaseResponse(let message):
            return String(
                localized: "The GitHub release information could not be read: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        case .untrustedReleaseURL:
            return String(localized: "GitHub returned an untrusted release link.", bundle: SwitchyardStrings.bundle)
        case .runtimeManifestMissing:
            return String(
                localized: "A Wine release does not include its runtime manifest.",
                bundle: SwitchyardStrings.bundle
            )
        case .untrustedRuntimeManifestURL:
            return String(
                localized: "A Wine release points to an untrusted runtime manifest.",
                bundle: SwitchyardStrings.bundle
            )
        case .invalidRuntimeManifest(let message):
            return String(
                localized: "A Wine runtime manifest could not be verified: \(message)",
                bundle: SwitchyardStrings.bundle
            )
        }
    }
}
