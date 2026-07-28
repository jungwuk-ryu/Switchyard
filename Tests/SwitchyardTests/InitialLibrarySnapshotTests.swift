import AppCore
import Foundation
import Testing
@testable import Switchyard

@MainActor
@Test
func initialLibrarySnapshotReportsFailureWhenTheIndexCannotBeRecovered() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let manifestURL = root.appendingPathComponent("switchyard-library.json")
    let corruptIndex = Data("{ invalid json".utf8)
    try corruptIndex.write(to: manifestURL, options: [.atomic])

    let result = AppStore.initialLibrarySnapshotResult(libraryPath: root.path)

    #expect(throws: (any Error).self) {
        _ = try result.get()
    }
    #expect(try Data(contentsOf: manifestURL) == corruptIndex)
}

@MainActor
@Test
func initialLibrarySnapshotTreatsAMissingFirstRunIndexAsSuccess() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = AppStore.initialLibrarySnapshotResult(libraryPath: root.path)
    let loaded = try result.get()

    #expect(loaded == nil)
}

@MainActor
@Test
func initialRecentProgramLaunchesPreserveStoredDataWhenContainerLoadingFails() throws {
    let suiteName = "InitialLibrarySnapshotTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let containerID = UUID()
    let launches = [
        containerID: [
            RecentProgramLaunch(
                executablePath: "C:\\Program Files\\Example\\example.exe",
                launchedAt: Date(timeIntervalSince1970: 1_753_075_800)
            )
        ]
    ]
    defaults.set(
        try JSONEncoder().encode(launches),
        forKey: "recentProgramLaunches.v1"
    )

    let loaded = AppStore.initialRecentProgramLaunches(
        defaults: defaults,
        containers: nil
    )

    #expect(loaded == launches)
}
