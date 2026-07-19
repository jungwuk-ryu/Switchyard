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
    private static let runtimeManifestAssetName = "switchyard-runtime-release.json"
    private static let maximumReleaseResponseSize = 1 * 1024 * 1024
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

        guard let manifestURL = runtime.assets.first(where: {
            $0.name == Self.runtimeManifestAssetName
        })?.downloadURL else {
            throw OnlineReleaseCatalogError.runtimeManifestMissing
        }
        guard manifestURL.scheme == "https",
              manifestURL.host?.lowercased() == "github.com",
              manifestURL.path.hasPrefix("/jungwuk-ryu/switchyard-wine/releases/download/") else {
            throw OnlineReleaseCatalogError.untrustedRuntimeManifestURL
        }

        let manifest = try await runtimeManifest(at: manifestURL)
        return SwitchyardReleaseSnapshot(
            appRelease: app.summary,
            runtimeRelease: runtime.summary,
            runtimeManifest: manifest
        )
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
            throw OnlineReleaseCatalogError.invalidRuntimeManifest("The release metadata is incomplete.")
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
    var publishedAt: Date
    var assets: [GitHubReleaseAsset]

    var summary: PublishedGitHubRelease {
        PublishedGitHubRelease(tagName: tagName, webURL: webURL, publishedAt: publishedAt)
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case webURL = "html_url"
        case publishedAt = "published_at"
        case assets
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
            return "GitHub returned an invalid response."
        case .httpFailure(let statusCode):
            return "GitHub returned HTTP \(statusCode)."
        case .responseTooLarge:
            return "GitHub returned release metadata that was too large."
        case .invalidReleaseResponse(let message):
            return "The GitHub release information could not be read: \(message)"
        case .untrustedReleaseURL:
            return "GitHub returned an untrusted release link."
        case .runtimeManifestMissing:
            return "The latest Wine release does not include its runtime manifest."
        case .untrustedRuntimeManifestURL:
            return "The latest Wine release points to an untrusted runtime manifest."
        case .invalidRuntimeManifest(let message):
            return "The latest Wine runtime manifest could not be verified: \(message)"
        }
    }
}
