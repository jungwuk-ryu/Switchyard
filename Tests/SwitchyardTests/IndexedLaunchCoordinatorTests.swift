import Foundation
import Testing
@testable import Switchyard

@Suite("Indexed Launch Coordinator")
@MainActor
struct IndexedLaunchCoordinatorTests {
    @Test(
        "an immediate exit cannot be overwritten after delayed index preparation",
        .timeLimit(.minutes(1))
    )
    func immediateExitDoesNotResurrectRunningState() async throws {
        let gate = IndexedLaunchPreparationGate()
        let state = IndexedLaunchTestState()

        let launchTask = Task { @MainActor in
            await IndexedLaunchCoordinator.launch(
                prepareIndex: {
                    await gate.wait()
                },
                launch: {
                    let sessionID = UUID()
                    state.launchCount += 1
                    Task { @MainActor in
                        state.complete(sessionID)
                    }
                    return sessionID
                },
                register: { sessionID in
                    state.register(sessionID)
                },
                publishRunning: {
                    state.publishRunning()
                }
            )
        }

        await gate.waitUntilBlocked()
        #expect(state.launchCount == 0)
        #expect(state.status == .ready)
        #expect(!state.isRunning)

        await gate.release()
        _ = await launchTask.value
        try await waitForIndexedLaunchCondition {
            state.status == .finished
        }

        #expect(state.activeSessionIDs.isEmpty)
        #expect(state.statusHistory == [.running, .finished])
        #expect(!state.isRunning)
    }
}

@MainActor
private final class IndexedLaunchTestState {
    enum Status: Equatable {
        case ready
        case running
        case finished
    }

    private(set) var activeSessionIDs: Set<UUID> = []
    private(set) var status: Status = .ready
    private(set) var statusHistory: [Status] = []
    var launchCount = 0

    var isRunning: Bool {
        !activeSessionIDs.isEmpty || status == .running
    }

    func register(_ sessionID: UUID) {
        activeSessionIDs.insert(sessionID)
    }

    func publishRunning() {
        status = .running
        statusHistory.append(.running)
    }

    func complete(_ sessionID: UUID) {
        activeSessionIDs.remove(sessionID)
        status = .finished
        statusHistory.append(.finished)
    }
}

private actor IndexedLaunchPreparationGate {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isBlocked = true
        let observers = blockedWaiters
        blockedWaiters.removeAll()
        observers.forEach { $0.resume() }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum IndexedLaunchTestError: Error {
    case timeout
}

@MainActor
private func waitForIndexedLaunchCondition(
    _ condition: () -> Bool
) async throws {
    for _ in 0..<10_000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    throw IndexedLaunchTestError.timeout
}
