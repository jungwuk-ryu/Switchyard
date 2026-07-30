@testable import AppCore
import Darwin
import Foundation
import Testing

@Suite("Wine callback request cleanup")
struct WineCallbackRequestCleanupTests {
    @Test func filenameValidationAcceptsOnlyCanonicalUUIDJSONNames() {
        #expect(
            WineCallbackRequestCleanup.isCanonicalRequestFilename(
                "01234567-89AB-CDEF-0123-456789ABCDEF.json"
            )
        )
        #expect(
            WineCallbackRequestCleanup.isCanonicalRequestFilename(
                "01234567-89ab-cdef-0123-456789abcdef.json"
            )
        )
        #expect(
            !WineCallbackRequestCleanup.isCanonicalRequestFilename(
                "../234567-89AB-CDEF-0123-456789ABCDEF.json"
            )
        )
        #expect(
            !WineCallbackRequestCleanup.isCanonicalRequestFilename(
                "0123456789AB-CDEF-0123-456789ABCDEF.json"
            )
        )
        #expect(
            !WineCallbackRequestCleanup.isCanonicalRequestFilename(
                "01234567-89AB-CDEF-0123-456789ABCDEG.json"
            )
        )
        #expect(
            !WineCallbackRequestCleanup.isCanonicalRequestFilename(
                "01234567-89AB-CDEF-0123-456789ABCDEF.JSON"
            )
        )
        #expect(
            !WineCallbackRequestCleanup.isCanonicalRequestFilename(
                "01234567-89AB-CDEF-0123-456789ABCDEF.json.backup"
            )
        )
    }

    @Test func cleanupRemovesOnlyOldOwnedCanonicalRegularFilesAndIsIdempotent() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-callback-cleanup-\(UUID().uuidString)")
        let bridgeRoot = temporaryRoot.appendingPathComponent("ProtocolBridge", isDirectory: true)
        let requests = bridgeRoot.appendingPathComponent("Requests", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: requests, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let staleURL = requests.appendingPathComponent(
            "00000000-0000-0000-0000-000000000001.json"
        )
        let freshURL = requests.appendingPathComponent(
            "00000000-0000-0000-0000-000000000002.json"
        )
        let directoryURL = requests.appendingPathComponent(
            "00000000-0000-0000-0000-000000000003.json",
            isDirectory: true
        )
        let symlinkURL = requests.appendingPathComponent(
            "00000000-0000-0000-0000-000000000004.json"
        )
        let noncanonicalURL = requests.appendingPathComponent("stale-request.json")
        let outsideTargetURL = outside.appendingPathComponent("secret.json")

        try Data("stale".utf8).write(to: staleURL)
        try Data("fresh".utf8).write(to: freshURL)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: outsideTargetURL)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideTargetURL)
        try Data("noncanonical".utf8).write(to: noncanonicalURL)

        let cleanupNow = Date().addingTimeInterval(
            WineCallbackRequestCleanup.staleRequestAge + 3_600
        )
        try fileManager.setAttributes(
            [.modificationDate: cleanupNow],
            ofItemAtPath: freshURL.path
        )

        let removed = WineCallbackRequestCleanup.removeStaleRequests(
            inBridgeRoot: bridgeRoot,
            now: cleanupNow
        )
        #expect(removed == 1)
        #expect(!fileManager.fileExists(atPath: staleURL.path))
        #expect(fileManager.fileExists(atPath: freshURL.path))
        #expect(fileManager.fileExists(atPath: directoryURL.path))
        #expect(fileManager.fileExists(atPath: symlinkURL.path))
        #expect(fileManager.fileExists(atPath: noncanonicalURL.path))
        #expect(fileManager.fileExists(atPath: outsideTargetURL.path))

        let secondRemoval = WineCallbackRequestCleanup.removeStaleRequests(
            inBridgeRoot: bridgeRoot,
            now: cleanupNow
        )
        #expect(secondRemoval == 0)
        #expect(fileManager.fileExists(atPath: freshURL.path))
        #expect(fileManager.fileExists(atPath: symlinkURL.path))
    }

    @Test func cleanupRejectsSymlinkDirectoriesAndUnexpectedOwners() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-callback-boundary-\(UUID().uuidString)")
        let actualBridgeRoot = temporaryRoot.appendingPathComponent(
            "ActualProtocolBridge",
            isDirectory: true
        )
        let actualRequests = actualBridgeRoot.appendingPathComponent("Requests", isDirectory: true)
        let linkedBridgeRoot = temporaryRoot.appendingPathComponent(
            "LinkedProtocolBridge",
            isDirectory: true
        )
        let requestsSymlinkRoot = temporaryRoot.appendingPathComponent(
            "ShortcutBridge",
            isDirectory: true
        )
        let outsideRequests = temporaryRoot.appendingPathComponent(
            "OutsideRequests",
            isDirectory: true
        )
        try fileManager.createDirectory(at: actualRequests, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: requestsSymlinkRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideRequests, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: linkedBridgeRoot,
            withDestinationURL: actualBridgeRoot
        )
        try fileManager.createSymbolicLink(
            at: requestsSymlinkRoot.appendingPathComponent("Requests"),
            withDestinationURL: outsideRequests
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let rootLinkedRequest = actualRequests.appendingPathComponent(
            "00000000-0000-0000-0000-000000000011.json"
        )
        let requestsLinkedRequest = outsideRequests.appendingPathComponent(
            "00000000-0000-0000-0000-000000000012.json"
        )
        try Data("root-link".utf8).write(to: rootLinkedRequest)
        try Data("requests-link".utf8).write(to: requestsLinkedRequest)
        let cleanupNow = Date().addingTimeInterval(
            WineCallbackRequestCleanup.staleRequestAge + 3_600
        )

        #expect(
            WineCallbackRequestCleanup.removeStaleRequests(
                inBridgeRoot: linkedBridgeRoot,
                now: cleanupNow
            ) == 0
        )
        #expect(fileManager.fileExists(atPath: rootLinkedRequest.path))

        #expect(
            WineCallbackRequestCleanup.removeStaleRequests(
                inBridgeRoot: requestsSymlinkRoot,
                now: cleanupNow
            ) == 0
        )
        #expect(fileManager.fileExists(atPath: requestsLinkedRequest.path))

        #expect(
            WineCallbackRequestCleanup.removeStaleRequests(
                inBridgeRoot: actualBridgeRoot,
                now: cleanupNow,
                staleAfter: WineCallbackRequestCleanup.staleRequestAge,
                ownerUserID: getuid() &+ 1
            ) == 0
        )
        #expect(fileManager.fileExists(atPath: rootLinkedRequest.path))
    }

    @Test func cleanupUsesNewestFileTimestampAndRequiresStrictlyOlderThanCutoff() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("switchyard-callback-time-\(UUID().uuidString)")
        let bridgeRoot = temporaryRoot.appendingPathComponent("ProtocolBridge", isDirectory: true)
        let requests = bridgeRoot.appendingPathComponent("Requests", isDirectory: true)
        try fileManager.createDirectory(at: requests, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let requestURL = requests.appendingPathComponent(
            "00000000-0000-0000-0000-000000000021.json"
        )
        try Data("request".utf8).write(to: requestURL)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: requestURL.path
        )

        let creationTime = Date()
        #expect(
            WineCallbackRequestCleanup.removeStaleRequests(
                inBridgeRoot: bridgeRoot,
                now: creationTime.addingTimeInterval(
                    WineCallbackRequestCleanup.staleRequestAge - 60
                )
            ) == 0
        )
        #expect(fileManager.fileExists(atPath: requestURL.path))

        let boundary = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3_600
        )
        try fileManager.setAttributes(
            [.modificationDate: boundary],
            ofItemAtPath: requestURL.path
        )
        #expect(
            WineCallbackRequestCleanup.removeStaleRequests(
                inBridgeRoot: bridgeRoot,
                now: boundary.addingTimeInterval(
                    WineCallbackRequestCleanup.staleRequestAge
                )
            ) == 0
        )
        #expect(fileManager.fileExists(atPath: requestURL.path))
    }
}
