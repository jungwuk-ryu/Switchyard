import Foundation
@testable import RuntimeCatalog
import Testing

@Test func releaseVersionComparesGitHubTagsNumerically() throws {
    let current = try #require(ReleaseVersion("v0.3.2"))
    let nextPatch = try #require(ReleaseVersion("0.3.3"))
    let nextMinor = try #require(ReleaseVersion("v0.10.0"))
    let equivalent = try #require(ReleaseVersion("0.3.2.0+developer"))

    #expect(current < nextPatch)
    #expect(nextPatch < nextMinor)
    #expect(current == equivalent)
    #expect(ReleaseVersion("runtime-34fb5abd4109") == nil)
}

@Test func onlineReleaseCatalogLoadsLatestAppAndRuntimeManifest() async throws {
    let appURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/Switchyard/releases/latest"
    ))
    let runtimeURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/switchyard-wine/releases/latest"
    ))
    let manifestURL = try #require(URL(
        string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-aaaaaaaaaaaa/switchyard-runtime-release.json"
    ))
    let sourceRevision = String(repeating: "a", count: 40)
    let manifest = PublishedRuntimeRelease(
        schemaVersion: 1,
        runtimeID: "switchyard-runtime-aaaaaaaaaaaa",
        sourceRevision: sourceRevision,
        archive: "Switchyard-Wine-Runtime-aaaaaaaaaaaa-macos-x86_64.zip",
        archiveSha256: String(repeating: "b", count: 64),
        archiveSize: 1_024,
        platform: "macos",
        hostArchitecture: "x86_64",
        peArchitectures: ["i386", "x86_64"],
        developerTeamID: "M3CULMDKU3",
        notarizationStatus: "Accepted",
        notarizationID: UUID().uuidString
    )

    let responses = [
        appURL: Data(
            """
            {
              "tag_name": "v1.2.3",
              "html_url": "https://github.com/jungwuk-ryu/Switchyard/releases/tag/v1.2.3",
              "published_at": "2026-07-19T08:53:15Z",
              "assets": []
            }
            """.utf8
        ),
        runtimeURL: Data(
            """
            {
              "tag_name": "runtime-aaaaaaaaaaaa",
              "html_url": "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-aaaaaaaaaaaa",
              "published_at": "2026-07-19T08:38:12Z",
              "assets": [
                {
                  "name": "switchyard-runtime-release.json",
                  "browser_download_url": "\(manifestURL.absoluteString)"
                }
              ]
            }
            """.utf8
        ),
        manifestURL: try JSONEncoder().encode(manifest)
    ]

    let catalog = OnlineReleaseCatalog { request in
        guard let url = request.url, let data = responses[url] else {
            throw OnlineReleaseStubError.unexpectedRequest
        }
        if url.host == "api.github.com" {
            guard request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json",
                  request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28",
                  request.value(forHTTPHeaderField: "User-Agent") == "Switchyard" else {
                throw OnlineReleaseStubError.missingGitHubHeaders
            }
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (data, response)
    }

    let snapshot = try await catalog.latestReleases()

    #expect(snapshot.appRelease.tagName == "v1.2.3")
    #expect(snapshot.runtimeRelease.tagName == "runtime-aaaaaaaaaaaa")
    #expect(snapshot.runtimeManifest.sourceRevision == sourceRevision)
}

@Test func onlineReleaseCatalogRejectsUntrustedRuntimeManifestURL() async throws {
    let appURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/Switchyard/releases/latest"
    ))
    let runtimeURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/switchyard-wine/releases/latest"
    ))
    let untrustedManifestURL = try #require(URL(
        string: "https://example.com/switchyard-runtime-release.json"
    ))

    let responses = [
        appURL: Data(
            """
            {
              "tag_name": "v1.2.3",
              "html_url": "https://github.com/jungwuk-ryu/Switchyard/releases/tag/v1.2.3",
              "published_at": "2026-07-19T08:53:15Z",
              "assets": []
            }
            """.utf8
        ),
        runtimeURL: Data(
            """
            {
              "tag_name": "runtime-aaaaaaaaaaaa",
              "html_url": "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-aaaaaaaaaaaa",
              "published_at": "2026-07-19T08:38:12Z",
              "assets": [
                {
                  "name": "switchyard-runtime-release.json",
                  "browser_download_url": "\(untrustedManifestURL.absoluteString)"
                }
              ]
            }
            """.utf8
        )
    ]

    let catalog = OnlineReleaseCatalog { request in
        guard let url = request.url, let data = responses[url] else {
            throw OnlineReleaseStubError.unexpectedRequest
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (data, response)
    }

    await #expect(throws: OnlineReleaseCatalogError.untrustedRuntimeManifestURL) {
        _ = try await catalog.latestReleases()
    }
}

private enum OnlineReleaseStubError: Error {
    case unexpectedRequest
    case missingGitHubHeaders
}
