import AppCore
import Foundation
import Persistence
import Testing

@Test func librarySnapshotRoundTripsBottlesAndLaunchers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bottle = Bottle(name: "Steam", path: root.appendingPathComponent("Steam.bottle", isDirectory: true).path, wineBuildID: "wine-a", patchsetID: "patch-a")
    let launcher = Launcher(name: "Steam", kind: .steam, bottleID: bottle.id)
    let snapshot = SwitchyardLibrarySnapshot(bottles: [bottle], launchers: [launcher])
    let store = LibraryManifestStore(rootURL: root)

    try store.save(snapshot)
    let loaded = try #require(try store.loadSnapshot())

    #expect(loaded.bottles.count == 1)
    #expect(loaded.launchers.count == 1)
    #expect(loaded.bottles.first?.id == bottle.id)
    #expect(loaded.bottles.first?.name == "Steam")
    #expect(loaded.launchers.first?.id == launcher.id)
    #expect(loaded.launchers.first?.bottleID == bottle.id)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Steam.bottle/switchyard-bottle.json").path))
}
