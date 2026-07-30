import AppCore
import Foundation
@testable import Persistence
import Testing

private enum InjectedDirectoryRenameError: Error {
    case moveFailed
    case saveFailed
    case manifestRecoveryFailed
}

@Test func containerDirectoryRenamerSurfacesInitialMoveFailureWithoutChangingState() throws {
    let fixture = try ContainerDirectoryRenameFixture()
    defer { fixture.remove() }

    var saveWasCalled = false
    let renamer = ContainerDirectoryRenamer(
        rootURL: fixture.rootURL,
        moveItem: { _, _ in
            throw InjectedDirectoryRenameError.moveFailed
        },
        saveManifest: {
            try fixture.saveManifest($0)
        }
    )

    do {
        _ = try renamer.rename(fixture.container, to: "Epic Games") { _ in
            saveWasCalled = true
        }
        Issue.record("An injected directory move failure unexpectedly succeeded.")
    } catch let error as ContainerDirectoryRenameError {
        guard case let .directoryMoveFailed(
            source,
            destination,
            recoveryLocations,
            _
        ) = error else {
            Issue.record("Unexpected typed rename error: \(error)")
            return
        }
        #expect(source == fixture.sourceURL)
        #expect(destination == fixture.destinationURL)
        #expect(
            recoveryLocations.map { $0.resolvingSymlinksInPath().path }
                == [fixture.sourceURL.resolvingSymlinksInPath().path]
        )
    }

    #expect(!saveWasCalled)
    try fixture.expectOnlyContainer(
        at: fixture.sourceURL,
        name: fixture.container.name
    )
}

@Test func containerDirectoryRenamerRollsBackDirectoryAndManifestAfterSaveFailure() throws {
    let fixture = try ContainerDirectoryRenameFixture()
    defer { fixture.remove() }

    var moveCount = 0
    let renamer = ContainerDirectoryRenamer(
        rootURL: fixture.rootURL,
        moveItem: { source, destination in
            moveCount += 1
            try FileManager.default.moveItem(at: source, to: destination)
        },
        saveManifest: {
            try fixture.saveManifest($0)
        }
    )

    #expect(throws: InjectedDirectoryRenameError.saveFailed) {
        _ = try renamer.rename(fixture.container, to: "Epic Games") { _ in
            throw InjectedDirectoryRenameError.saveFailed
        }
    }

    #expect(moveCount == 2)
    try fixture.expectOnlyContainer(
        at: fixture.sourceURL,
        name: fixture.container.name
    )
}

@Test func containerDirectoryRenamerKeepsOneConsistentManifestWhenRollbackMoveFails() throws {
    let fixture = try ContainerDirectoryRenameFixture()
    defer { fixture.remove() }

    var moveCount = 0
    let renamer = ContainerDirectoryRenamer(
        rootURL: fixture.rootURL,
        moveItem: { source, destination in
            moveCount += 1
            if moveCount == 2 {
                throw InjectedDirectoryRenameError.moveFailed
            }
            try FileManager.default.moveItem(at: source, to: destination)
        },
        saveManifest: {
            try fixture.saveManifest($0)
        }
    )

    do {
        _ = try renamer.rename(fixture.container, to: "Epic Games") { _ in
            throw InjectedDirectoryRenameError.saveFailed
        }
        Issue.record("An injected rollback failure unexpectedly succeeded.")
    } catch let error as ContainerDirectoryRenameError {
        guard case let .rollbackFailed(
            source,
            destination,
            recoveryLocations,
            _,
            _
        ) = error else {
            Issue.record("Unexpected typed rename error: \(error)")
            return
        }
        #expect(source == fixture.sourceURL)
        #expect(destination == fixture.destinationURL)
        #expect(
            recoveryLocations.map { $0.resolvingSymlinksInPath().path }
                == [fixture.destinationURL.resolvingSymlinksInPath().path]
        )
    }

    #expect(moveCount == 2)
    try fixture.expectOnlyContainer(
        at: fixture.destinationURL,
        name: "Epic Games"
    )
}

@Test func containerDirectoryRenamerSurfacesManifestRecoveryFailureWithoutCreatingDuplicate() throws {
    let fixture = try ContainerDirectoryRenameFixture()
    defer { fixture.remove() }

    var moveCount = 0
    let renamer = ContainerDirectoryRenamer(
        rootURL: fixture.rootURL,
        moveItem: { source, destination in
            moveCount += 1
            if moveCount == 2 {
                throw InjectedDirectoryRenameError.moveFailed
            }
            try FileManager.default.moveItem(at: source, to: destination)
        },
        saveManifest: { _ in
            throw InjectedDirectoryRenameError.manifestRecoveryFailed
        }
    )

    do {
        _ = try renamer.rename(fixture.container, to: "Epic Games") { _ in
            throw InjectedDirectoryRenameError.saveFailed
        }
        Issue.record("An injected manifest recovery failure unexpectedly succeeded.")
    } catch let error as ContainerDirectoryRenameError {
        guard case let .stateRecoveryFailed(
            recoveryLocations,
            _,
            rollbackReason,
            _
        ) = error else {
            Issue.record("Unexpected typed rename error: \(error)")
            return
        }
        #expect(
            recoveryLocations.map { $0.resolvingSymlinksInPath().path }
                == [fixture.destinationURL.resolvingSymlinksInPath().path]
        )
        #expect(rollbackReason != nil)
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    let containers = try ContainerManifestStore(rootURL: fixture.rootURL)
        .loadContainers()
    #expect(containers.count == 1)
    #expect(containers.first?.id == fixture.container.id)
    #expect(containers.first?.path == fixture.destinationURL.path)
}

@Test func containerDirectoryRenamerSurfacesRestoreFailureAfterDirectoryRollback() throws {
    let fixture = try ContainerDirectoryRenameFixture()
    defer { fixture.remove() }

    let renamer = ContainerDirectoryRenamer(
        rootURL: fixture.rootURL,
        moveItem: { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        },
        saveManifest: { _ in
            throw InjectedDirectoryRenameError.manifestRecoveryFailed
        }
    )

    do {
        _ = try renamer.rename(fixture.container, to: "Epic Games") { renamed in
            try fixture.saveManifest(renamed)
            throw InjectedDirectoryRenameError.saveFailed
        }
        Issue.record("An injected restore failure unexpectedly succeeded.")
    } catch let error as ContainerDirectoryRenameError {
        guard case let .stateRecoveryFailed(
            recoveryLocations,
            _,
            rollbackReason,
            _
        ) = error else {
            Issue.record("Unexpected typed rename error: \(error)")
            return
        }
        #expect(
            recoveryLocations.map { $0.resolvingSymlinksInPath().path }
                == [fixture.sourceURL.resolvingSymlinksInPath().path]
        )
        #expect(rollbackReason == nil)
    }

    #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
    let containers = try ContainerManifestStore(rootURL: fixture.rootURL)
        .loadContainers()
    #expect(containers.count == 1)
    #expect(containers.first?.id == fixture.container.id)
}

@Test func containerDirectoryRenamerRestoresCaseOnlyIntermediateMoveFailure() throws {
    let fixture = try ContainerDirectoryRenameFixture(
        sourceName: "EpicGames.container",
        containerName: "Epic Games"
    )
    defer { fixture.remove() }

    let destinationURL = fixture.rootURL.appendingPathComponent(
        "epicgames.container",
        isDirectory: true
    )
    var moveCount = 0
    let renamer = ContainerDirectoryRenamer(
        rootURL: fixture.rootURL,
        moveItem: { source, destination in
            moveCount += 1
            if moveCount == 2 {
                throw InjectedDirectoryRenameError.moveFailed
            }
            try FileManager.default.moveItem(at: source, to: destination)
        },
        saveManifest: {
            try fixture.saveManifest($0)
        }
    )

    do {
        _ = try renamer.rename(fixture.container, to: "epic games")
        Issue.record("An injected case-only move failure unexpectedly succeeded.")
    } catch let error as ContainerDirectoryRenameError {
        guard case let .directoryMoveFailed(
            source,
            destination,
            recoveryLocations,
            _
        ) = error else {
            Issue.record("Unexpected typed rename error: \(error)")
            return
        }
        #expect(source == fixture.sourceURL)
        #expect(destination == destinationURL)
        #expect(
            recoveryLocations.map { $0.resolvingSymlinksInPath().path }
                == [fixture.sourceURL.resolvingSymlinksInPath().path]
        )
    }

    #expect(moveCount == 3)
    try fixture.expectOnlyContainer(
        at: fixture.sourceURL,
        name: fixture.container.name
    )
}

@Test func containerDirectoryRenamerReportsCaseOnlyIntermediateRecoveryLocation() throws {
    let fixture = try ContainerDirectoryRenameFixture(
        sourceName: "EpicGames.container",
        containerName: "Epic Games",
        executableRelativePath: "drive_c/Games/Launcher.exe"
    )
    defer { fixture.remove() }

    var moveCount = 0
    var reportedRecoveryURL: URL?
    let renamer = ContainerDirectoryRenamer(
        rootURL: fixture.rootURL,
        moveItem: { source, destination in
            moveCount += 1
            if moveCount == 2 || moveCount == 3 {
                throw InjectedDirectoryRenameError.moveFailed
            }
            try FileManager.default.moveItem(at: source, to: destination)
        },
        saveManifest: {
            try fixture.saveManifest($0)
        }
    )

    do {
        _ = try renamer.rename(fixture.container, to: "epic games")
        Issue.record("Injected case-only move and rollback failures unexpectedly succeeded.")
    } catch let error as ContainerDirectoryRenameError {
        guard case let .directoryMoveFailed(
            _,
            _,
            recoveryLocations,
            _
        ) = error else {
            Issue.record("Unexpected typed rename error: \(error)")
            return
        }
        reportedRecoveryURL = recoveryLocations.first
        #expect(recoveryLocations.count == 1)
        #expect(
            recoveryLocations.first?.lastPathComponent
                .hasPrefix(".switchyard-rename-") == true
        )
    }

    #expect(moveCount == 3)
    let containers = try ContainerManifestStore(rootURL: fixture.rootURL)
        .loadContainers()
    #expect(containers.count == 1)
    #expect(containers.first?.id == fixture.container.id)
    let recoveryURL = try #require(reportedRecoveryURL)
    let recoveredContainer = try #require(containers.first)
    let executablePath = try #require(recoveredContainer.executablePath)
    #expect(
        URL(fileURLWithPath: recoveredContainer.path, isDirectory: true)
            .resolvingSymlinksInPath().path
            == recoveryURL.resolvingSymlinksInPath().path
    )
    #expect(
        executablePath
            == URL(
                fileURLWithPath: recoveredContainer.path,
                isDirectory: true
            ).appendingPathComponent(
                "drive_c/Games/Launcher.exe"
            ).path
    )
}

private struct ContainerDirectoryRenameFixture {
    var rootURL: URL
    var sourceURL: URL
    var destinationURL: URL
    var container: Container

    init(
        sourceName: String = "NewContainer.container",
        containerName: String = "New Container",
        executableRelativePath: String? = nil
    ) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixtureSourceURL = rootURL.appendingPathComponent(
            sourceName,
            isDirectory: true
        )
        sourceURL = fixtureSourceURL
        destinationURL = rootURL.appendingPathComponent(
            "EpicGames.container",
            isDirectory: true
        )
        container = Container(
            name: containerName,
            path: fixtureSourceURL.path,
            executablePath: executableRelativePath.map {
                fixtureSourceURL.appendingPathComponent($0).path
            }
        )
        try ContainerManifestStore(rootURL: rootURL).save(container)
    }

    func saveManifest(_ container: Container) throws {
        try ContainerManifestStore(rootURL: rootURL).save(container)
    }

    func expectOnlyContainer(at expectedURL: URL, name: String) throws {
        let containers = try ContainerManifestStore(rootURL: rootURL)
            .loadContainers()
        #expect(containers.count == 1)
        #expect(containers.first?.id == container.id)
        #expect(containers.first?.name == name)
        #expect(containers.first?.path == expectedURL.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
