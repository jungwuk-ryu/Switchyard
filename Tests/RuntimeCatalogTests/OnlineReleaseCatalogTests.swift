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
    #expect(snapshot.runtimeRelease?.tagName == "runtime-aaaaaaaaaaaa")
    #expect(snapshot.runtimeManifest?.sourceRevision == sourceRevision)
}

@Test func onlineReleaseCatalogTreatsMissingStableRuntimeAsUnavailable() async throws {
    let appURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/Switchyard/releases/latest"
    ))
    let runtimeURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/switchyard-wine/releases/latest"
    ))
    let appRelease = Data(
        """
        {
          "tag_name": "v0.3.2",
          "html_url": "https://github.com/jungwuk-ryu/Switchyard/releases/tag/v0.3.2",
          "published_at": "2026-07-19T08:53:15Z",
          "assets": []
        }
        """.utf8
    )

    let catalog = OnlineReleaseCatalog { request in
        let url = try #require(request.url)
        let statusCode: Int
        let data: Data
        switch url {
        case appURL:
            statusCode = 200
            data = appRelease
        case runtimeURL:
            statusCode = 404
            data = Data(#"{"message":"Not Found"}"#.utf8)
        default:
            throw OnlineReleaseStubError.unexpectedRequest
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (data, response)
    }

    let snapshot = try await catalog.latestReleases()

    #expect(snapshot.appRelease.tagName == "v0.3.2")
    #expect(snapshot.runtimeRelease == nil)
    #expect(snapshot.runtimeManifest == nil)
}

@Test func onlineReleaseCatalogDoesNotHideRuntimeServerFailures() async throws {
    let appURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/Switchyard/releases/latest"
    ))
    let runtimeURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/switchyard-wine/releases/latest"
    ))
    let appRelease = Data(
        """
        {
          "tag_name": "v0.3.2",
          "html_url": "https://github.com/jungwuk-ryu/Switchyard/releases/tag/v0.3.2",
          "published_at": "2026-07-19T08:53:15Z",
          "assets": []
        }
        """.utf8
    )

    let catalog = OnlineReleaseCatalog { request in
        let url = try #require(request.url)
        let statusCode: Int
        let data: Data
        switch url {
        case appURL:
            statusCode = 200
            data = appRelease
        case runtimeURL:
            statusCode = 500
            data = Data()
        default:
            throw OnlineReleaseStubError.unexpectedRequest
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (data, response)
    }

    await #expect(throws: OnlineReleaseCatalogError.httpFailure(500)) {
        _ = try await catalog.latestReleases()
    }
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

@Test func onlineReleaseCatalogLoadsStableOfficialRuntimeReleases() async throws {
    let releasesURL = try #require(URL(
        string: "https://api.github.com/repos/jungwuk-ryu/switchyard-wine/releases?per_page=20"
    ))
    let stableManifestURL = try #require(URL(
        string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-stable/switchyard-runtime-release.json"
    ))
    let prereleaseManifestURL = try #require(URL(
        string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-preview/switchyard-runtime-release.json"
    ))
    let invalidManifestURL = try #require(URL(
        string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-invalid/switchyard-runtime-release.json"
    ))
    let sourceRevision = String(repeating: "c", count: 40)
    let manifest = PublishedRuntimeRelease(
        schemaVersion: 1,
        runtimeID: "switchyard-runtime-stable",
        sourceRevision: sourceRevision,
        archive: "Switchyard-Wine-Runtime-stable-macos-x86_64.zip",
        archiveSha256: String(repeating: "d", count: 64),
        archiveSize: 2_048,
        platform: "macos",
        hostArchitecture: "x86_64",
        peArchitectures: ["i386", "x86_64"],
        developerTeamID: "M3CULMDKU3",
        notarizationStatus: "Accepted",
        notarizationID: UUID().uuidString
    )
    let responses = [
        releasesURL: Data(
            """
            [
              {
                "tag_name": "runtime-invalid",
                "html_url": "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-invalid",
                "published_at": "2026-07-22T09:00:00Z",
                "draft": false,
                "prerelease": false,
                "assets": [
                  {
                    "name": "switchyard-runtime-release.json",
                    "browser_download_url": "\(invalidManifestURL.absoluteString)"
                  }
                ]
              },
              {
                "tag_name": "runtime-stable",
                "html_url": "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-stable",
                "published_at": "2026-07-22T08:00:00Z",
                "draft": false,
                "prerelease": false,
                "assets": [
                  {
                    "name": "switchyard-runtime-release.json",
                    "browser_download_url": "\(stableManifestURL.absoluteString)"
                  }
                ]
              },
              {
                "tag_name": "runtime-preview",
                "html_url": "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-preview",
                "published_at": "2026-07-23T08:00:00Z",
                "draft": false,
                "prerelease": true,
                "assets": [
                  {
                    "name": "switchyard-runtime-release.json",
                    "browser_download_url": "\(prereleaseManifestURL.absoluteString)"
                  }
                ]
              },
              {
                "tag_name": "runtime-draft",
                "html_url": "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-draft",
                "published_at": null,
                "draft": true,
                "prerelease": false,
                "assets": []
              },
              {
                "tag_name": "source-only",
                "html_url": "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/source-only",
                "published_at": "2026-07-21T08:00:00Z",
                "draft": false,
                "prerelease": false,
                "assets": []
              }
            ]
            """.utf8
        ),
        stableManifestURL: try JSONEncoder().encode(manifest),
        invalidManifestURL: Data("not-json".utf8)
    ]

    let catalog = OnlineReleaseCatalog { request in
        guard let url = request.url, let data = responses[url] else {
            throw OnlineReleaseStubError.unexpectedRequest
        }
        guard request.value(forHTTPHeaderField: "User-Agent") == "Switchyard" else {
            throw OnlineReleaseStubError.missingGitHubHeaders
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        return (data, response)
    }

    let releases = try await catalog.officialRuntimeReleases()

    #expect(releases.count == 1)
    #expect(releases.first?.release.tagName == "runtime-stable")
    #expect(releases.first?.manifest.sourceRevision == sourceRevision)
    #expect(releases.first?.manifestURL == stableManifestURL)
}

@Test func officialRuntimeReleaseRequiresTheConfiguredDeveloperTeam() throws {
    let manifestURL = try #require(URL(
        string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-stable/switchyard-runtime-release.json"
    ))
    let manifest = PublishedRuntimeRelease(
        schemaVersion: 1,
        runtimeID: "switchyard-runtime-stable",
        sourceRevision: String(repeating: "a", count: 40),
        archive: "Switchyard-Wine-Runtime-stable-macos-x86_64.zip",
        archiveSha256: String(repeating: "b", count: 64),
        archiveSize: 4_096,
        platform: "macos",
        hostArchitecture: "x86_64",
        peArchitectures: ["i386", "x86_64"],
        developerTeamID: "M3CULMDKU3",
        notarizationStatus: "Accepted",
        notarizationID: UUID().uuidString
    )
    let release = OfficialRuntimeRelease(
        release: PublishedGitHubRelease(
            tagName: "runtime-stable",
            webURL: try #require(URL(
                string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-stable"
            )),
            publishedAt: Date()
        ),
        manifestURL: manifestURL,
        manifest: manifest
    )

    let policy = try release.installationPolicy(
        trustedDeveloperTeamID: "M3CULMDKU3"
    )

    #expect(policy.sourceRevision == manifest.sourceRevision)
    #expect(policy.archiveSha256 == manifest.archiveSha256)
    #expect(
        release.managedInstallationID
            == "switchyard-runtime-stable-release-\(manifest.archiveSha256.prefix(16))"
    )
    #expect(throws: OfficialRuntimeReleaseError.untrustedDeveloperTeam) {
        _ = try release.installationPolicy(
            trustedDeveloperTeamID: "ABCDEFGHIJ"
        )
    }
}

private enum OnlineReleaseStubError: Error {
    case unexpectedRequest
    case missingGitHubHeaders
}
