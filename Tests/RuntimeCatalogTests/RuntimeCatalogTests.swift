import AppCore
import Foundation
import RuntimeCatalog
import Testing

@Test func missingGPTKPathReportsMissing() {
    let locator = RuntimeLocator()
    let result = locator.validateGPTK(at: nil)
    #expect(result.status == .missing)
}

@Test func appleSignedGPTKMarkerProducesFingerprint() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try makeLaunchReadyGPTKLayout(
        at: root,
        sharedLibrarySource: URL(fileURLWithPath: "/bin/echo")
    )

    let result = RuntimeLocator().validateGPTK(at: root.path)
    #expect(result.status == .ok)
    #expect(result.fingerprint != nil)
}

@Test func appleSignedGPTKFrameworkReportsTrustedFingerprint() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let framework = try makeLaunchReadyGPTKLayout(
        at: root,
        sharedLibrarySource: URL(fileURLWithPath: "/bin/echo")
    )
    let resources = framework.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(
        at: resources,
        withIntermediateDirectories: true
    )
    let info: [String: Any] = [
        "CFBundleShortVersionString": "3.1",
        "CFBundleVersion": "3100"
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try infoData.write(to: resources.appendingPathComponent("Info.plist"))

    let result = RuntimeLocator().validateGPTK(at: root.path)

    #expect(result.status == .ok)
    let fingerprint = try #require(result.fingerprint)
    #expect(result.version == String(fingerprint.suffix(8)))
}

@Test func unsignedGPTKMarkerIsRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try makeLaunchReadyGPTKLayout(at: root)

    let result = RuntimeLocator().validateGPTK(at: root.path)

    #expect(result.status == .warning)
    #expect(result.message.contains("not fully Apple-signed"))
}

@Test func gptkDirectoryRejectsEscapingSymbolicLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try makeLaunchReadyGPTKLayout(
        at: root,
        sharedLibrarySource: URL(fileURLWithPath: "/bin/echo")
    )
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("outside"),
        withDestinationURL: FileManager.default.temporaryDirectory
    )

    let result = RuntimeLocator().validateGPTK(at: root.path)

    #expect(result.status == .warning)
    #expect(result.message.contains("symbolic link"))
}

@Test func nestedGPTKSelectionResolvesToLaunchReadyRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let framework = try makeLaunchReadyGPTKLayout(
        at: root,
        sharedLibrarySource: URL(fileURLWithPath: "/bin/echo")
    )
    let nested = framework.appendingPathComponent(
        "Versions/A/Resources",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )

    let canonical = RuntimeLocator().canonicalGPTKRoot(at: nested.path)

    #expect(
        canonical
            == root.resolvingSymlinksInPath().standardizedFileURL.path
    )
}

@Test func markerOnlyGPTKDirectoryIsNotLaunchReady() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/bin/echo"),
        to: root.appendingPathComponent("libd3dshared.dylib")
    )

    let result = RuntimeLocator().validateGPTK(at: root.path)

    #expect(result.status == .warning)
    #expect(result.message.contains("launch-ready GPTK redist layout"))
}

@Test func regularFileGPTKPathReportsMissing() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)

    let result = RuntimeLocator().validateGPTK(at: file.path)
    #expect(result.status == .missing)
}

@Test func latestDownloadedGPTKDiskImageSelectsNewestMatchingImage() throws {
    let downloads = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: downloads) }
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

    let older = downloads.appendingPathComponent("Game_Porting_Toolkit_3.dmg")
    let newer = downloads.appendingPathComponent("Game-Porting-Toolkit-4.dmg")
    let unrelated = downloads.appendingPathComponent("Unrelated.dmg")
    try Data().write(to: older)
    try Data().write(to: newer)
    try Data().write(to: unrelated)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)

    let result = RuntimeLocator().latestDownloadedGPTKDiskImage(in: downloads)

    #expect(
        result.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == newer.resolvingSymlinksInPath().path
    )
}

@Test func publishedRuntimeReleaseRequiresExactSignedNotarizedRevision() throws {
    let revision = String(repeating: "a", count: 40)
    let releaseNotarizationID = UUID().uuidString
    let policy = PublishedRuntimePolicy(
        sourceRevision: revision,
        releaseManifestURL: try #require(URL(string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-a/switchyard-runtime-release.json")),
        developerTeamID: "M3CULMDKU3",
        archiveSha256: String(repeating: "b", count: 64),
        archiveSize: 1024,
        notarizationID: releaseNotarizationID
    )
    let release = PublishedRuntimeRelease(
        schemaVersion: 1,
        runtimeID: "switchyard-runtime-a",
        sourceRevision: revision,
        archive: "Switchyard-Wine-Runtime-a.zip",
        archiveSha256: String(repeating: "b", count: 64),
        archiveSize: 1024,
        platform: "macos",
        hostArchitecture: "x86_64",
        peArchitectures: ["i386", "x86_64"],
        developerTeamID: "M3CULMDKU3",
        notarizationStatus: "Accepted",
        notarizationID: releaseNotarizationID
    )

    try PublishedRuntimeInstaller.validate(release: release, against: policy)

    var mismatched = release
    mismatched.sourceRevision = String(repeating: "c", count: 40)
    #expect(throws: (any Error).self) {
        try PublishedRuntimeInstaller.validate(release: mismatched, against: policy)
    }

    var unsigned = release
    unsigned.notarizationStatus = "not-submitted"
    #expect(throws: (any Error).self) {
        try PublishedRuntimeInstaller.validate(release: unsigned, against: policy)
    }

    var replacedArchive = release
    replacedArchive.archiveSha256 = String(repeating: "c", count: 64)
    #expect(throws: (any Error).self) {
        try PublishedRuntimeInstaller.validate(release: replacedArchive, against: policy)
    }
}

@Test func publishedRuntimeReleaseAcceptsBuildRuntimeIdentifiers() throws {
    let revision = String(repeating: "a", count: 40)
    let archiveSha256 = String(repeating: "b", count: 64)
    let notarizationID = UUID().uuidString
    let manifestURL = try #require(URL(string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-88ca753ede98/switchyard-runtime-release.json"))
    let policy = PublishedRuntimePolicy(
        sourceRevision: revision,
        releaseManifestURL: manifestURL,
        developerTeamID: "M3CULMDKU3",
        archiveSha256: archiveSha256,
        archiveSize: 1024,
        notarizationID: notarizationID
    )
    let runtimeID = "switchyard-local-wow64-x86_64-88ca753ede98-no-gptk-b4525679e7da-9245db166022-37a4f0cfb0fb-4fbf9011be92-1b749a3204a2-b40553c5dc41-62f8fecd4b11"
    let release = publishedRuntimeRelease(
        runtimeID: runtimeID,
        sourceRevision: revision,
        archiveSha256: archiveSha256,
        notarizationID: notarizationID
    )

    #expect(runtimeID.utf8.count == 141)
    try PublishedRuntimeInstaller.validate(release: release, against: policy)
}

@Test func publishedRuntimeReleaseIdentifierUsesManagedPathComponentBudget() throws {
    let revision = String(repeating: "a", count: 40)
    let archiveSha256 = String(repeating: "b", count: 64)
    let notarizationID = UUID().uuidString
    let manifestURL = try #require(URL(string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/download/runtime-budget/switchyard-runtime-release.json"))
    let policy = PublishedRuntimePolicy(
        sourceRevision: revision,
        releaseManifestURL: manifestURL,
        developerTeamID: "M3CULMDKU3",
        archiveSha256: archiveSha256,
        archiveSize: 1024,
        notarizationID: notarizationID
    )

    let exactBudgetRuntimeID = String(repeating: "r", count: 230)
    let exactBudgetRelease = publishedRuntimeRelease(
        runtimeID: exactBudgetRuntimeID,
        sourceRevision: revision,
        archiveSha256: archiveSha256,
        notarizationID: notarizationID
    )
    let officialRelease = OfficialRuntimeRelease(
        release: PublishedGitHubRelease(
            tagName: "runtime-budget",
            webURL: try #require(URL(string: "https://github.com/jungwuk-ryu/switchyard-wine/releases/tag/runtime-budget")),
            publishedAt: Date()
        ),
        manifestURL: manifestURL,
        manifest: exactBudgetRelease
    )

    try PublishedRuntimeInstaller.validate(release: exactBudgetRelease, against: policy)
    #expect(exactBudgetRuntimeID.utf8.count == 230)
    #expect(officialRelease.managedInstallationID.utf8.count == 255)

    var oversizedRelease = exactBudgetRelease
    oversizedRelease.runtimeID = String(repeating: "r", count: 231)
    #expect(throws: (any Error).self) {
        try PublishedRuntimeInstaller.validate(release: oversizedRelease, against: policy)
    }

    var unsafePathRelease = exactBudgetRelease
    unsafePathRelease.runtimeID = "switchyard/runtime"
    #expect(throws: (any Error).self) {
        try PublishedRuntimeInstaller.validate(release: unsafePathRelease, against: policy)
    }
}

private func publishedRuntimeRelease(
    runtimeID: String,
    sourceRevision: String,
    archiveSha256: String,
    notarizationID: String
) -> PublishedRuntimeRelease {
    PublishedRuntimeRelease(
        schemaVersion: 1,
        runtimeID: runtimeID,
        sourceRevision: sourceRevision,
        archive: "Switchyard-Wine-Runtime-test.zip",
        archiveSha256: archiveSha256,
        archiveSize: 1024,
        platform: "macos",
        hostArchitecture: "x86_64",
        peArchitectures: ["i386", "x86_64"],
        developerTeamID: "M3CULMDKU3",
        notarizationStatus: "Accepted",
        notarizationID: notarizationID
    )
}

@Test func publishedRuntimeCanBeInstalledWhenProvided() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let manifestValue = environment["SWITCHYARD_TEST_RUNTIME_RELEASE_MANIFEST_URL"],
          let manifestURL = URL(string: manifestValue),
          let sourceRevision = environment["SWITCHYARD_TEST_RUNTIME_SOURCE_REVISION"],
          let developerTeamID = environment["SWITCHYARD_TEST_RUNTIME_DEVELOPER_TEAM_ID"],
          let archiveSha256 = environment["SWITCHYARD_TEST_RUNTIME_ARCHIVE_SHA256"],
          let archiveSizeValue = environment["SWITCHYARD_TEST_RUNTIME_ARCHIVE_SIZE"],
          let archiveSize = UInt64(archiveSizeValue),
          let notarizationID = environment["SWITCHYARD_TEST_RUNTIME_NOTARIZATION_ID"] else {
        return
    }

    let runtimeCache = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runtimeCache) }

    let policy = PublishedRuntimePolicy(
        sourceRevision: sourceRevision,
        releaseManifestURL: manifestURL,
        developerTeamID: developerTeamID,
        archiveSha256: archiveSha256,
        archiveSize: archiveSize,
        notarizationID: notarizationID
    )
    let result = try await PublishedRuntimeInstaller(runtimeCacheRoot: runtimeCache).install(policy: policy)

    #expect(result.sourceRevision == sourceRevision)
    #expect(FileManager.default.isExecutableFile(atPath: result.winePath))
    #expect(URL(fileURLWithPath: result.winePath).path.hasPrefix(runtimeCache.path + "/"))
}

@Test func gptkDiskImagePathReportsWarningWhenProvided() {
    guard let path = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_GPTK_DMG"], !path.isEmpty else {
        return
    }

    let result = RuntimeLocator().validateGPTK(at: path)
    #expect(result.status == .warning)
    #expect(result.fingerprint != nil)
}

@discardableResult
private func makeLaunchReadyGPTKLayout(
    at root: URL,
    sharedLibrarySource: URL? = nil
) throws -> URL {
    let wineDirectory = root.appendingPathComponent(
        "redist/lib/wine",
        isDirectory: true
    )
    let framework = root.appendingPathComponent(
        "redist/lib/external/D3DMetal.framework",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: wineDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: framework,
        withIntermediateDirectories: true
    )
    let sharedLibrary = root.appendingPathComponent(
        "redist/lib/external/libd3dshared.dylib"
    )
    if let sharedLibrarySource {
        try FileManager.default.copyItem(
            at: sharedLibrarySource,
            to: sharedLibrary
        )
    } else {
        try Data().write(to: sharedLibrary)
    }
    return framework
}

@Test func gptkDiskImageCanBeImportedWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_GPTK_DMG"], !path.isEmpty else {
        return
    }

    let importRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: importRoot) }

    let locator = RuntimeLocator()
    let importedPath = try locator.importGPTKDiskImage(at: path, to: importRoot.path)
    let result = locator.validateGPTK(at: importedPath)

    #expect(result.status == .ok)
    #expect(result.fingerprint != nil)
}

@Test func wineDirectorySelectionResolvesBinWineExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let wine = bin.appendingPathComponent("wine")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: wine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

    let locator = RuntimeLocator()
    #expect(locator.resolveWineExecutablePath(for: root.path) == wine.path)

    let result = locator.diagnose(gptkPath: nil, winePath: root.path)
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })
    #expect(wineCheck.status == .ok)
    #expect(wineCheck.result.contains(wine.path))
}

@Test func preferredWineExecutablePathTracksLatestManagedRuntimeCache() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let oldRoot = cacheRoot.appendingPathComponent("switchyard-local-old", isDirectory: true)
    let newRoot = cacheRoot.appendingPathComponent("switchyard-local-new", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let oldSourceRevision = String(repeating: "a", count: 40)
    let newSourceRevision = String(repeating: "b", count: 40)
    let oldWine = try createSwitchyardWineRuntime(
        at: oldRoot,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: oldSourceRevision
    )
    let newWine = try createSwitchyardWineRuntime(
        at: newRoot,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: newSourceRevision
    )
    try setManifestModificationDate(at: oldRoot, to: Date(timeIntervalSince1970: 100))
    try setManifestModificationDate(at: newRoot, to: Date(timeIntervalSince1970: 200))

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: nil) == newWine.path)
    #expect(locator.preferredWineExecutablePath(for: oldWine.path) == oldWine.path)
    #expect(
        locator.preferredWineExecutablePath(
            for: oldWine.path,
            expectedSourceRevision: oldSourceRevision
        ) == oldWine.path
    )
    #expect(
        locator.preferredWineExecutablePath(
            for: oldWine.path,
            expectedSourceRevision: newSourceRevision
        ) == newWine.path
    )
}

@Test func compatibleInstalledRuntimeRequiresExactCleanCompleteRevision() throws {
    let expectedRevision = String(repeating: "a", count: 40)
    let otherRevision = String(repeating: "b", count: 40)
    let installations = [
        ManagedRuntimeInstallation(
            id: "other",
            rootURL: URL(fileURLWithPath: "/runtimes/other"),
            runtime: RuntimeBuild(
                id: "other",
                winePath: "/runtimes/other/bin/wine",
                patchsetID: "switchyard-wine-other",
                sourceRevision: otherRevision
            ),
            installedAt: Date(timeIntervalSince1970: 400),
            isCompleteWoW64: true,
            isCleanSource: true
        ),
        ManagedRuntimeInstallation(
            id: "dirty",
            rootURL: URL(fileURLWithPath: "/runtimes/dirty"),
            runtime: RuntimeBuild(
                id: "dirty",
                winePath: "/runtimes/dirty/bin/wine",
                patchsetID: "switchyard-wine-dirty",
                sourceRevision: expectedRevision
            ),
            installedAt: Date(timeIntervalSince1970: 300),
            isCompleteWoW64: true,
            isCleanSource: false
        ),
        ManagedRuntimeInstallation(
            id: "incomplete",
            rootURL: URL(fileURLWithPath: "/runtimes/incomplete"),
            runtime: RuntimeBuild(
                id: "incomplete",
                winePath: "/runtimes/incomplete/bin/wine",
                patchsetID: "switchyard-wine-incomplete",
                sourceRevision: expectedRevision
            ),
            installedAt: Date(timeIntervalSince1970: 200),
            isCompleteWoW64: false,
            isCleanSource: true
        ),
        ManagedRuntimeInstallation(
            id: "compatible",
            rootURL: URL(fileURLWithPath: "/runtimes/compatible"),
            runtime: RuntimeBuild(
                id: "compatible",
                winePath: "/runtimes/compatible/bin/wine",
                patchsetID: "switchyard-wine-compatible",
                sourceRevision: expectedRevision
            ),
            installedAt: Date(timeIntervalSince1970: 100),
            isCompleteWoW64: true,
            isCleanSource: true
        ),
    ]

    let selected = RuntimeLocator.compatibleInstalledRuntime(
        in: installations,
        sourceRevision: expectedRevision
    )

    #expect(selected?.id == "compatible")
    #expect(
        RuntimeLocator.compatibleInstalledRuntime(
            in: installations,
            sourceRevision: String(repeating: "c", count: 40)
        ) == nil
    )
    #expect(
        RuntimeLocator.compatibleInstalledRuntime(
            in: installations,
            sourceRevision: ""
        ) == nil
    )
}

@Test func preferredWineExecutablePathRecoversDeletedManagedRuntimeSelection() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheRuntimeRoot = cacheRoot.appendingPathComponent("switchyard-local-new", isDirectory: true)
    let deletedManagedWine = cacheRoot
        .appendingPathComponent("switchyard-local-deleted", isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("switchyard-wine")
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let newWine = try createSwitchyardWineRuntime(at: cacheRuntimeRoot, peArchitectures: ["i386", "x86_64"])

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: deletedManagedWine.path) == newWine.path)
}

@Test func preferredWineExecutablePathKeepsExternalWineSelection() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheRuntimeRoot = cacheRoot.appendingPathComponent("switchyard-local-new", isDirectory: true)
    let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let externalBin = externalRoot.appendingPathComponent("bin", isDirectory: true)
    let externalWine = externalBin.appendingPathComponent("wine")
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: externalRoot)
    }

    try createSwitchyardWineRuntime(at: cacheRuntimeRoot, peArchitectures: ["i386", "x86_64"])
    try FileManager.default.createDirectory(at: externalBin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: externalWine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: externalRoot.path) == externalWine.path)
}

@Test func pinnedSourcePolicyRejectsUnverifiedExternalWine() throws {
    let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let externalBin = externalRoot.appendingPathComponent("bin", isDirectory: true)
    let externalWine = externalBin.appendingPathComponent("wine")
    defer { try? FileManager.default.removeItem(at: externalRoot) }

    try FileManager.default.createDirectory(at: externalBin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: externalWine)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: externalWine.path)

    let locator = RuntimeLocator()
    let result = locator.diagnose(
        gptkPath: nil,
        winePath: externalWine.path,
        expectedSourceRevision: String(repeating: "e", count: 40)
    )
    let sourceCheck = try #require(result.1.first { $0.id == "runtime-source" })
    let runtime = locator.runtimeBuild(for: externalWine.path)

    #expect(result.0.wineSource == .warning)
    #expect(!result.0.canLaunch)
    #expect(sourceCheck.result.contains("cannot be verified"))
    #expect(runtime.id == "external-unverified")
    #expect(runtime.patchsetID == "external-unverified")
    #expect(runtime.sourceRevision.isEmpty)
}

@Test func runtimeBuildUsesManifestIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let revision = String(repeating: "f", count: 40)
    let buildTime = Date(timeIntervalSince1970: 1_752_822_300)
    let wine = try createSwitchyardWineRuntime(
        at: root,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: revision
    )
    try setManifestModificationDate(at: root, to: buildTime)

    let locator = RuntimeLocator()
    let runtime = locator.runtimeBuild(
        for: wine.path,
        versionSourceRevision: revision,
        versionDate: buildTime
    )
    try setManifestModificationDate(
        at: root,
        to: buildTime.addingTimeInterval(86_400)
    )
    let runtimeAfterMetadataChange = locator.runtimeBuild(
        for: wine.path,
        versionSourceRevision: revision,
        versionDate: buildTime
    )
    let runtimeWithoutPinnedDate = locator.runtimeBuild(for: wine.path)
    let runtimeWithMismatchedRevision = locator.runtimeBuild(
        for: wine.path,
        versionSourceRevision: String(repeating: "e", count: 40),
        versionDate: buildTime
    )

    #expect(runtime.id == "switchyard-test-runtime")
    #expect(runtime.patchsetID == "switchyard-test-patchset")
    #expect(runtime.sourceRevision == revision)
    #expect(runtime.winePath == wine.path)
    #expect(runtime.versionDate == buildTime)
    #expect(runtimeAfterMetadataChange.buildNumber == runtime.buildNumber)
    #expect(runtimeWithoutPinnedDate.buildNumber == nil)
    #expect(runtimeWithMismatchedRevision.buildNumber == nil)
}

@Test func switchyardWineRuntimeReportsWoW64PEArchitectures() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let wine = try createSwitchyardWineRuntime(at: root, peArchitectures: ["i386", "x86_64"])
    let sourceRevision = String(repeating: "a", count: 40)
    let versionDate = try #require(
        ISO8601DateFormatter().date(from: "2026-07-24T12:34:00Z")
    )
    let result = RuntimeLocator().diagnose(
        gptkPath: nil,
        winePath: root.path,
        expectedSourceRevision: sourceRevision,
        wineVersionDate: versionDate
    )
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })
    let sourceCheck = try #require(result.1.first { $0.id == "runtime-source" })

    #expect(wineCheck.status == .ok)
    #expect(wineCheck.version == "20260724.1234")
    #expect(wineCheck.result.contains("Switchyard Wine runtime"))
    #expect(wineCheck.result.contains("i386"))
    #expect(wineCheck.result.contains("x86_64"))
    #expect(wineCheck.result.contains(wine.path))
    #expect(sourceCheck.version == String(sourceRevision.prefix(12)))
}

@Test func externalWineReportsStableIdentifierInsteadOfGenericStatus() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let wine = root.appendingPathComponent("wine")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: wine.path
    )

    let result = RuntimeLocator().diagnose(
        gptkPath: nil,
        winePath: wine.path
    )
    let wineCheck = try #require(
        result.1.first { $0.id == "wine-runtime" }
    )

    #expect(wineCheck.status == .ok)
    #expect(wineCheck.version?.hasPrefix("wine-") == true)
}

@Test func switchyardWineRuntimeMissingI386ReportsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try createSwitchyardWineRuntime(at: root, peArchitectures: ["x86_64"])
    let result = RuntimeLocator().diagnose(gptkPath: nil, winePath: root.path)
    let wineCheck = try #require(result.1.first { $0.id == "wine-runtime" })

    #expect(wineCheck.status == .warning)
    #expect(wineCheck.result.contains("missing PE architecture(s): i386"))
}

@Test func switchyardWineRuntimeSourceMismatchReportsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let oldRevision = String(repeating: "a", count: 40)
    let expectedRevision = String(repeating: "b", count: 40)
    try createSwitchyardWineRuntime(
        at: root,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: oldRevision
    )

    let result = RuntimeLocator().diagnose(
        gptkPath: nil,
        winePath: root.path,
        expectedSourceRevision: expectedRevision
    )
    let sourceCheck = try #require(result.1.first { $0.id == "runtime-source" })

    #expect(result.0.wine == .ok)
    #expect(result.0.wineSource == .warning)
    #expect(!result.0.canLaunch)
    #expect(sourceCheck.result.contains(oldRevision.prefix(12)))
    #expect(sourceCheck.result.contains(expectedRevision.prefix(12)))
}

@Test func switchyardWineRuntimeDirtySourceReportsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceRevision = String(repeating: "c", count: 40)
    try createSwitchyardWineRuntime(
        at: root,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: sourceRevision,
        sourceDirty: true
    )

    let result = RuntimeLocator().diagnose(
        gptkPath: nil,
        winePath: root.path,
        expectedSourceRevision: sourceRevision
    )
    let sourceCheck = try #require(result.1.first { $0.id == "runtime-source" })

    #expect(result.0.wineSource == .warning)
    #expect(sourceCheck.result.contains("dirty source tree"))
}

@Test func missingRuntimeSourcePreventsLaunchReadiness() throws {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let result = RuntimeLocator(runtimeCacheRoot: cacheRoot).diagnose(
        gptkPath: nil,
        winePath: nil,
        expectedSourceRevision: String(repeating: "d", count: 40)
    )
    #expect(result.0.wineSource == .missing)
    #expect(!result.0.canLaunch)
}

@Test func openFontPackDiagnoseReportsMissingCacheAsWarning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let status = OpenFontPackCatalog.diagnose(cacheRoot: root)

    #expect(status.status == .warning)
    #expect(status.missingFonts.count == OpenFontPackCatalog.files.count)
}

@Test func managedRuntimeWithRegularFilesRemainsSelectableAndComplete() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let runtimeRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-regular",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let wine = try createSwitchyardWineRuntime(
        at: runtimeRoot,
        peArchitectures: ["i386", "x86_64"]
    )
    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)
    let installation = try #require(locator.installedManagedRuntimes().first)

    #expect(installation.runtime.winePath == wine.path)
    #expect(installation.isCompleteWoW64)
    #expect(locator.resolveWineExecutablePath(for: runtimeRoot.path) == wine.path)
    #expect(locator.preferredWineExecutablePath(for: nil) == wine.path)
}

@Test func managedRuntimeRejectsWineSymlinkEscapingRuntimeRoot() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let runtimeRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-escaping-wine",
        isDirectory: true
    )
    let outsideRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outsideWine = outsideRoot.appendingPathComponent("wine")
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: outsideRoot)
    }

    try writeExecutable(at: outsideWine)
    let wine = try createSwitchyardWineRuntime(
        at: runtimeRoot,
        peArchitectures: ["i386", "x86_64"]
    )
    try FileManager.default.removeItem(at: wine)
    try FileManager.default.createSymbolicLink(
        at: wine,
        withDestinationURL: outsideWine
    )

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)
    let diagnosis = locator.diagnose(gptkPath: nil, winePath: runtimeRoot.path)
    let wineCheck = try #require(
        diagnosis.1.first { $0.id == "wine-runtime" }
    )

    #expect(locator.resolveWineExecutablePath(for: runtimeRoot.path) == nil)
    #expect(locator.preferredWineExecutablePath(for: nil) == nil)
    #expect(locator.installedManagedRuntimes().isEmpty)
    #expect(locator.runtimeBuild(for: wine.path).id == "external-unverified")
    #expect(wineCheck.status == .missing)
}

@Test func managedRuntimeManifestCannotAuthorizeOutsideExecutable() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let runtimeRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-escaping-manifest",
        isDirectory: true
    )
    let outsideRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outsideWine = outsideRoot.appendingPathComponent("wine")
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: outsideRoot)
    }

    try writeExecutable(at: outsideWine)
    let wine = try createSwitchyardWineRuntime(
        at: runtimeRoot,
        peArchitectures: ["i386", "x86_64"],
        manifestExecutable: outsideWine.path
    )
    try FileManager.default.removeItem(at: wine)

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.preferredWineExecutablePath(for: nil) == nil)
    #expect(locator.installedManagedRuntimes().isEmpty)
}

@Test func managedRuntimeRejectsEscapingWineServerSymlink() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let runtimeRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-escaping-wineserver",
        isDirectory: true
    )
    let outsideRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outsideWineServer = outsideRoot.appendingPathComponent("wineserver")
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: outsideRoot)
    }

    try writeExecutable(at: outsideWineServer)
    let wine = try createSwitchyardWineRuntime(
        at: runtimeRoot,
        peArchitectures: ["i386", "x86_64"]
    )
    try FileManager.default.createSymbolicLink(
        at: wine.deletingLastPathComponent()
            .appendingPathComponent("wineserver"),
        withDestinationURL: outsideWineServer
    )

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.resolveWineExecutablePath(for: runtimeRoot.path) == nil)
    #expect(locator.installedManagedRuntimes().isEmpty)
}

@Test func managedRuntimeRejectsExecutableThroughEscapingDirectorySymlink() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let runtimeRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-escaping-bin",
        isDirectory: true
    )
    let outsideRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outsideWine = outsideRoot
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("wine")
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: outsideRoot)
    }

    try createSwitchyardWineRuntime(
        at: runtimeRoot,
        peArchitectures: ["i386", "x86_64"]
    )
    try FileManager.default.removeItem(
        at: runtimeRoot.appendingPathComponent("bin", isDirectory: true)
    )
    try writeExecutable(at: outsideWine)
    try FileManager.default.createSymbolicLink(
        at: runtimeRoot.appendingPathComponent("bin", isDirectory: true),
        withDestinationURL: outsideWine.deletingLastPathComponent()
    )

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)

    #expect(locator.resolveWineExecutablePath(for: runtimeRoot.path) == nil)
    #expect(locator.installedManagedRuntimes().isEmpty)
}

@Test func managedRuntimeRejectsPEMarkerSymlinkEscapingRuntimeRoot() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let runtimeRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-escaping-marker",
        isDirectory: true
    )
    let outsideRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outsideMarker = outsideRoot.appendingPathComponent("ntdll.dll")
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: outsideRoot)
    }

    try FileManager.default.createDirectory(
        at: outsideRoot,
        withIntermediateDirectories: true
    )
    try Data().write(to: outsideMarker)
    try createSwitchyardWineRuntime(
        at: runtimeRoot,
        peArchitectures: ["i386", "x86_64"]
    )
    let marker = runtimeRoot
        .appendingPathComponent("lib/wine/i386-windows", isDirectory: true)
        .appendingPathComponent("ntdll.dll")
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.createSymbolicLink(
        at: marker,
        withDestinationURL: outsideMarker
    )

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)
    let installation = try #require(locator.installedManagedRuntimes().first)
    let diagnosis = locator.diagnose(gptkPath: nil, winePath: runtimeRoot.path)
    let wineCheck = try #require(
        diagnosis.1.first { $0.id == "wine-runtime" }
    )

    #expect(!installation.isCompleteWoW64)
    #expect(wineCheck.status == .warning)
    #expect(wineCheck.result.contains("missing PE architecture(s): i386"))
}

@Test func managedRuntimeAllowsRelativeSymlinksThatStayInsideRuntimeRoot() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let runtimeRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-internal-links",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: cacheRoot) }

    let wine = try createSwitchyardWineRuntime(
        at: runtimeRoot,
        peArchitectures: ["i386", "x86_64"]
    )
    let bin = wine.deletingLastPathComponent()
    let wine64 = bin.appendingPathComponent("wine64")
    try FileManager.default.moveItem(at: wine, to: wine64)
    try FileManager.default.createSymbolicLink(
        atPath: wine.path,
        withDestinationPath: "wine64"
    )
    let wineServerTarget = bin.appendingPathComponent("wineserver.real")
    try writeExecutable(at: wineServerTarget)
    try FileManager.default.createSymbolicLink(
        atPath: bin.appendingPathComponent("wineserver").path,
        withDestinationPath: "wineserver.real"
    )

    let marker = runtimeRoot
        .appendingPathComponent("lib/wine/i386-windows", isDirectory: true)
        .appendingPathComponent("ntdll.dll")
    let sharedMarker = marker
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("shared-ntdll.dll")
    try FileManager.default.moveItem(at: marker, to: sharedMarker)
    try FileManager.default.createSymbolicLink(
        atPath: marker.path,
        withDestinationPath: "../shared-ntdll.dll"
    )

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)
    let installation = try #require(locator.installedManagedRuntimes().first)
    let diagnosis = locator.diagnose(gptkPath: nil, winePath: runtimeRoot.path)
    let wineCheck = try #require(
        diagnosis.1.first { $0.id == "wine-runtime" }
    )

    #expect(installation.runtime.winePath == wine.path)
    #expect(installation.isCompleteWoW64)
    #expect(locator.resolveWineExecutablePath(for: runtimeRoot.path) == wine.path)
    #expect(wineCheck.status == .ok)
}

@Test func managedRuntimeCatalogListsAndRemovesOnlyCacheRuntimes() throws {
    let cacheRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let olderRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-older",
        isDirectory: true
    )
    let newerRoot = cacheRoot.appendingPathComponent(
        "switchyard-runtime-newer",
        isDirectory: true
    )
    let outsideRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: outsideRoot)
    }

    try createSwitchyardWineRuntime(
        at: olderRoot,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: String(repeating: "a", count: 40)
    )
    try createSwitchyardWineRuntime(
        at: newerRoot,
        peArchitectures: ["i386", "x86_64"],
        sourceRevision: String(repeating: "b", count: 40)
    )
    try setManifestModificationDate(
        at: olderRoot,
        to: Date(timeIntervalSince1970: 100)
    )
    try setManifestModificationDate(
        at: newerRoot,
        to: Date(timeIntervalSince1970: 200)
    )

    let locator = RuntimeLocator(runtimeCacheRoot: cacheRoot)
    let installations = locator.installedManagedRuntimes()

    #expect(installations.map(\.rootURL.lastPathComponent) == [
        "switchyard-runtime-newer",
        "switchyard-runtime-older"
    ])
    #expect(installations.first?.runtime.sourceRevision == String(repeating: "b", count: 40))
    #expect(installations.allSatisfy { $0.isCompleteWoW64 })

    let outsideInstallation = ManagedRuntimeInstallation(
        id: "outside",
        rootURL: outsideRoot,
        runtime: try #require(installations.first).runtime,
        installedAt: Date(),
        isCompleteWoW64: true,
        isCleanSource: true
    )
    #expect(throws: ManagedRuntimeCatalogError.runtimeIsNotManaged) {
        try locator.removeManagedRuntime(outsideInstallation)
    }

    try createSwitchyardWineRuntime(
        at: outsideRoot,
        peArchitectures: ["i386", "x86_64"]
    )
    let escapingLink = cacheRoot.appendingPathComponent(
        "switchyard-runtime-link",
        isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
        at: escapingLink,
        withDestinationURL: outsideRoot
    )
    var linkedInstallation = outsideInstallation
    linkedInstallation.id = escapingLink.lastPathComponent
    linkedInstallation.rootURL = escapingLink
    #expect(throws: ManagedRuntimeCatalogError.runtimeIsNotManaged) {
        try locator.removeManagedRuntime(linkedInstallation)
    }
    #expect(FileManager.default.fileExists(atPath: outsideRoot.path))

    let internalAlias = cacheRoot.appendingPathComponent(
        "switchyard-runtime-alias",
        isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
        at: internalAlias,
        withDestinationURL: newerRoot
    )
    #expect(
        !locator.installedManagedRuntimes()
            .map(\.rootURL.lastPathComponent)
            .contains("switchyard-runtime-alias")
    )
    linkedInstallation.id = internalAlias.lastPathComponent
    linkedInstallation.rootURL = internalAlias
    #expect(throws: ManagedRuntimeCatalogError.runtimeIsNotManaged) {
        try locator.removeManagedRuntime(linkedInstallation)
    }
    #expect(FileManager.default.fileExists(atPath: newerRoot.path))

    let removable = try #require(installations.last)
    try locator.removeManagedRuntime(removable)

    #expect(!FileManager.default.fileExists(atPath: olderRoot.path))
    #expect(FileManager.default.fileExists(atPath: newerRoot.path))
}

@discardableResult
private func createSwitchyardWineRuntime(
    at root: URL,
    peArchitectures: [String],
    sourceRevision: String = String(repeating: "a", count: 40),
    sourceDirty: Bool = false,
    manifestExecutable: String? = nil
) throws -> URL {
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let wine = bin.appendingPathComponent("wine")
    try writeExecutable(at: wine)

    for architecture in peArchitectures {
        let peDirectory = root
            .appendingPathComponent("lib/wine", isDirectory: true)
            .appendingPathComponent("\(architecture)-windows", isDirectory: true)
        try FileManager.default.createDirectory(at: peDirectory, withIntermediateDirectories: true)
        try Data().write(to: peDirectory.appendingPathComponent("ntdll.dll"))
    }

    let quotedArchitectures = peArchitectures
        .map { "\"\($0)\"" }
        .joined(separator: ", ")
    let manifest = """
    {
      "id": "switchyard-test-runtime",
      "buildProfile": "switchyard-wow64-pe",
      "peArchitectures": [\(quotedArchitectures)],
      "executable": "\(manifestExecutable ?? wine.path)",
      "sourceRepository": "https://github.com/jungwuk-ryu/switchyard-wine",
      "sourceRevision": "\(sourceRevision)",
      "sourceDirty": \(sourceDirty),
      "patchsetID": "switchyard-test-patchset"
    }
    """
    try Data(manifest.utf8).write(to: root.appendingPathComponent("switchyard-runtime.json"))
    return wine
}

private func writeExecutable(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private func setManifestModificationDate(at runtimeRoot: URL, to date: Date) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: runtimeRoot.appendingPathComponent("switchyard-runtime.json").path
    )
}
