import AppCore
import Combine
import Foundation
import Testing
@testable import Switchyard

@Suite("Container Library Card Index")
@MainActor
struct ContainerLibraryCardIndexTests {
    @Test(
        "card and store-facing storage requests share one scan and suppress unchanged publishes",
        .timeLimit(.minutes(1))
    )
    func cardAndStoreCoalesceStorage() async throws {
        let container = Container(
            name: "Game",
            path: "/containers/Game",
            lastModified: Date(timeIntervalSinceReferenceDate: 1)
        )
        let gate = CardStorageScannerGate(value: 42_000)
        let counters = PerformanceCounters()
        let service = ContainerIndexService(
            scanners: ContainerIndexScanners(
                installedPrograms: { _ in [] },
                startMenuEntries: { _ in [] },
                storageByteCount: { request in
                    try await gate.scan(request)
                },
                bridgeMetadata: { _ in ContainerBridgeIndexMetadata() }
            ),
            counters: counters
        )
        let provider = CardStorageIndexProvider(
            containers: [container],
            service: service
        )
        let model = ContainerLibraryCardModel()
        var publishedValues: [Int64?] = []
        let subscription = model.$storageByteCount
            .dropFirst()
            .sink { publishedValues.append($0) }
        defer { subscription.cancel() }

        let storeFacingRequest = Task { @MainActor in
            try await provider.containerStorageByteCount(
                for: container.id,
                force: false
            )
        }
        await gate.waitForScanCount(1)
        let cardRequest = Task { @MainActor in
            await model.refreshStorageSize(
                for: container,
                store: provider
            )
        }
        try await waitForCardIndexCondition {
            counters.snapshot()[.containerIndexCoalescedRequests] == 1
        }

        await gate.release()
        #expect(try await storeFacingRequest.value == 42_000)
        await cardRequest.value
        #expect(model.storageByteCount == 42_000)
        #expect(await gate.scanCount == 1)
        #expect(publishedValues == [42_000])

        await model.refreshStorageSize(
            for: container,
            store: provider
        )
        #expect(publishedValues == [42_000])
        #expect(await gate.scanCount == 1)
        #expect(counters.snapshot()[.containerIndexCacheHits] == 1)
    }
}

@MainActor
private final class CardStorageIndexProvider:
    ContainerStorageIndexProviding
{
    var containers: [Container]
    private let service: ContainerIndexService

    init(
        containers: [Container],
        service: ContainerIndexService
    ) {
        self.containers = containers
        self.service = service
    }

    func containerStorageByteCount(
        for containerID: UUID,
        force: Bool
    ) async throws -> Int64 {
        guard let container = containers.first(where: {
            $0.id == containerID
        }) else {
            throw CancellationError()
        }
        let request = ContainerIndexRequest(container: container)
        let snapshot = try await service.snapshot(
            for: request,
            scopes: .storageByteCount,
            bypassCache: force
        )
        guard request.identity
                == containers.first(where: { $0.id == containerID })
                .map({ ContainerIndexRequest(container: $0).identity }),
              let byteCount = snapshot.storageByteCount else {
            throw CancellationError()
        }
        return byteCount
    }
}

private actor CardStorageScannerGate {
    private let value: Int64
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var scanCountWaiters:
        [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var scanCount = 0

    init(value: Int64) {
        self.value = value
    }

    func scan(_ request: ContainerIndexRequest) async throws -> Int64 {
        _ = request
        scanCount += 1
        let ready = scanCountWaiters.filter { $0.0 <= scanCount }
        scanCountWaiters.removeAll { $0.0 <= scanCount }
        ready.forEach { $0.1.resume() }
        if !isReleased {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return value
    }

    func waitForScanCount(_ target: Int) async {
        if scanCount >= target {
            return
        }
        await withCheckedContinuation { continuation in
            scanCountWaiters.append((target, continuation))
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum CardIndexTestError: Error {
    case timeout
}

private func waitForCardIndexCondition(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<10_000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    throw CardIndexTestError.timeout
}
