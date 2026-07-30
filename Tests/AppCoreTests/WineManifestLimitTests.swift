import AppCore
import Foundation
import Testing

@Suite("Wine manifest limits")
struct WineManifestLimitTests {
    @Test func protocolManifestRejectsOversizeAndOverCardinalityWithoutCountingDuplicates() {
        let maximumSchemes = WineProtocolAssociationFormat.maximumSchemes
        let acceptedManifest = (
            [WineProtocolAssociationFormat.manifestHeader]
                + (0..<maximumSchemes).map { "scheme\($0)" }
                + ["SCHEME0"]
        ).joined(separator: "\n")

        let accepted = WineProtocolAssociationFormat.schemes(inManifest: acceptedManifest)
        #expect(accepted.count == maximumSchemes)
        #expect(accepted.contains("scheme0"))

        let overCardinalityManifest = (
            [WineProtocolAssociationFormat.manifestHeader]
                + (0...maximumSchemes).map { "scheme\($0)" }
        ).joined(separator: "\n")
        #expect(
            WineProtocolAssociationFormat.schemes(inManifest: overCardinalityManifest).isEmpty
        )

        let oversizedManifest = WineProtocolAssociationFormat.manifestHeader
            + "\n"
            + String(repeating: "a", count: WineProtocolAssociationFormat.maximumManifestBytes)
        #expect(WineProtocolAssociationFormat.schemes(inManifest: oversizedManifest).isEmpty)

        let overRecordLimitManifest = (
            [WineProtocolAssociationFormat.manifestHeader]
                + Array(
                    repeating: "!",
                    count: WineProtocolAssociationFormat.maximumManifestRecords + 1
                )
        ).joined(separator: "\n")
        #expect(
            WineProtocolAssociationFormat.schemes(inManifest: overRecordLimitManifest).isEmpty
        )
        #expect(
            WineProtocolAssociationFormat.maximumManifestBytes
                < WineDesktopShortcutFormat.maximumManifestBytes
        )
    }

    @Test func desktopManifestRejectsOversizeAndOverCardinalityAndUsesLastDuplicate() throws {
        #expect(WineDesktopShortcutFormat.maximumEntries <= 512)

        let acceptedManifest = (
            [WineDesktopShortcutFormat.manifestHeader]
                + (0..<WineDesktopShortcutFormat.maximumEntries).map(desktopManifestLine)
        ).joined(separator: "\n")
        #expect(
            WineDesktopShortcutFormat.entries(inManifest: acceptedManifest).count
                == WineDesktopShortcutFormat.maximumEntries
        )

        let overCardinalityManifest = (
            [WineDesktopShortcutFormat.manifestHeader]
                + (0...WineDesktopShortcutFormat.maximumEntries).map(desktopManifestLine)
        ).joined(separator: "\n")
        #expect(
            WineDesktopShortcutFormat.entries(inManifest: overCardinalityManifest).isEmpty
        )

        let oversizedManifest = WineDesktopShortcutFormat.manifestHeader
            + "\n"
            + String(repeating: "x", count: WineDesktopShortcutFormat.maximumManifestBytes)
        #expect(WineDesktopShortcutFormat.entries(inManifest: oversizedManifest).isEmpty)

        let overRecordLimitManifest = (
            [WineDesktopShortcutFormat.manifestHeader]
                + Array(
                    repeating: "invalid",
                    count: WineDesktopShortcutFormat.maximumManifestRecords + 1
                )
        ).joined(separator: "\n")
        #expect(WineDesktopShortcutFormat.entries(inManifest: overRecordLimitManifest).isEmpty)

        let duplicatePath = #"C:\users\steamuser\Desktop\Duplicate.url"#
        let otherPath = #"C:\users\steamuser\Desktop\Other.url"#
        let duplicateManifest = [
            WineDesktopShortcutFormat.manifestHeader,
            desktopManifestLine(name: "Zulu", windowsPath: duplicatePath),
            desktopManifestLine(name: "Alpha", windowsPath: duplicatePath),
            desktopManifestLine(name: "Beta", windowsPath: otherPath)
        ].joined(separator: "\n")
        #expect(
            WineDesktopShortcutFormat.entries(inManifest: duplicateManifest)
                == [
                    WineDesktopShortcutManifestEntry(
                        kind: .url,
                        displayName: "Alpha",
                        windowsShortcutPath: duplicatePath
                    ),
                    WineDesktopShortcutManifestEntry(
                        kind: .url,
                        displayName: "Beta",
                        windowsShortcutPath: otherPath
                    )
                ]
        )
    }

    @Test func learnedProtocolAssociationsHaveAnIndependentCardinalityLimit() {
        let containerID = UUID()
        var index = WineProtocolLearnedAssociationIndex()
        var acceptedAll = true
        for value in 0..<WineProtocolLearnedAssociationIndex.maximumAssociations {
            if index.learn(scheme: "learned\(value)", for: containerID) == nil {
                acceptedAll = false
            }
        }

        #expect(acceptedAll)
        #expect(
            index.associations(for: containerID).count
                == WineProtocolLearnedAssociationIndex.maximumAssociations
        )
        #expect(index.learn(scheme: "one-too-many", for: containerID) == nil)
        #expect(index.learn(scheme: "learned0", for: containerID) == "learned0")
        #expect(index.associations.count == WineProtocolLearnedAssociationIndex.maximumAssociations)
    }

    private func desktopManifestLine(_ index: Int) -> String {
        desktopManifestLine(
            name: "Shortcut \(index)",
            windowsPath: #"C:\users\steamuser\Desktop\Shortcut \#(index).url"#
        )
    }

    private func desktopManifestLine(name: String, windowsPath: String) -> String {
        "url\t\(hex(name))\t\(hex(windowsPath))\t"
    }

    private func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
