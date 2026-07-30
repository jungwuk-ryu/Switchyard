import AppCore
import Foundation
import Persistence

struct ContainerIndexScope: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    static let installedPrograms = ContainerIndexScope(rawValue: 1 << 0)
    static let startMenuEntries = ContainerIndexScope(rawValue: 1 << 1)
    static let storageByteCount = ContainerIndexScope(rawValue: 1 << 2)
    static let bridgeMetadata = ContainerIndexScope(rawValue: 1 << 3)

    static let all: ContainerIndexScope = [
        .installedPrograms,
        .startMenuEntries,
        .storageByteCount,
        .bridgeMetadata,
    ]
}

struct ContainerIndexIdentity: Hashable, Sendable {
    let containerID: UUID
    let path: String
    let revision: String

    init(
        containerID: UUID,
        path: String,
        revision: String
    ) {
        self.containerID = containerID
        self.path = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
        self.revision = revision
    }
}

struct ContainerIndexRequest: Sendable {
    let identity: ContainerIndexIdentity
    let container: Container

    init(
        container: Container,
        revision: String? = nil
    ) {
        let identity = ContainerIndexIdentity(
            containerID: container.id,
            path: container.path,
            revision: revision ?? Self.productionRevision
        )
        var normalizedContainer = container
        normalizedContainer.path = identity.path

        self.identity = identity
        self.container = normalizedContainer
    }

    // Index contents are invalidated by filesystem/runner events. UI-only manifest
    // updates such as status and lastRun must not create an unbounded stream of
    // otherwise equivalent cache identities.
    private static let productionRevision = "container-index-v1"
}

struct ContainerBridgeDependencyMetadata: Hashable, Sendable {
    enum Role: String, Hashable, Sendable {
        case protocolManifest
        case desktopShortcutManifest
        case desktopShortcut
        case desktopShortcutIcon
    }

    let role: Role
    let path: String
    let byteCount: Int64?
    let modificationDate: Date?
    let fingerprint: String?

    init(
        role: Role,
        path: String,
        byteCount: Int64? = nil,
        modificationDate: Date? = nil,
        fingerprint: String? = nil
    ) {
        self.role = role
        self.path = path
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.fingerprint = fingerprint
    }
}

struct ContainerBridgeIndexMetadata: Equatable, Sendable {
    let protocolSchemes: Set<String>
    let desktopShortcutEntries: [WineDesktopShortcutManifestEntry]
    let dependencies: [ContainerBridgeDependencyMetadata]

    init(
        protocolSchemes: Set<String> = [],
        desktopShortcutEntries: [WineDesktopShortcutManifestEntry] = [],
        dependencies: [ContainerBridgeDependencyMetadata] = []
    ) {
        self.protocolSchemes = protocolSchemes
        self.desktopShortcutEntries = desktopShortcutEntries
        self.dependencies = dependencies
    }
}

struct ContainerIndexSnapshot: Equatable, Sendable {
    let identity: ContainerIndexIdentity
    let requestedScopes: ContainerIndexScope
    let installedPrograms: [InstalledProgram]?
    let startMenuEntries: [WindowsStartMenuEntry]?
    let storageByteCount: Int64?
    let bridgeMetadata: ContainerBridgeIndexMetadata?
}

struct ContainerIndexScanners: Sendable {
    typealias InstalledProgramsScanner =
        @Sendable (ContainerIndexRequest) async throws -> [InstalledProgram]
    typealias StartMenuEntriesScanner =
        @Sendable (ContainerIndexRequest) async throws -> [WindowsStartMenuEntry]
    typealias StorageByteCountScanner =
        @Sendable (ContainerIndexRequest) async throws -> Int64
    typealias BridgeMetadataScanner =
        @Sendable (ContainerIndexRequest) async throws -> ContainerBridgeIndexMetadata

    let installedPrograms: InstalledProgramsScanner
    let startMenuEntries: StartMenuEntriesScanner
    let storageByteCount: StorageByteCountScanner
    let bridgeMetadata: BridgeMetadataScanner

    init(
        installedPrograms: @escaping InstalledProgramsScanner,
        startMenuEntries: @escaping StartMenuEntriesScanner,
        storageByteCount: @escaping StorageByteCountScanner,
        bridgeMetadata: @escaping BridgeMetadataScanner
    ) {
        self.installedPrograms = installedPrograms
        self.startMenuEntries = startMenuEntries
        self.storageByteCount = storageByteCount
        self.bridgeMetadata = bridgeMetadata
    }

    static let live = ContainerIndexScanners(
        installedPrograms: { request in
            InstalledProgramCatalog().installedPrograms(in: request.container)
        },
        startMenuEntries: { request in
            WindowsStartMenuCatalog().entries(in: request.container)
        },
        storageByteCount: { request in
            try ContainerStorageSizeService.calculateByteCount(
                forContainerAt: URL(
                    fileURLWithPath: request.identity.path,
                    isDirectory: true
                )
            )
        },
        bridgeMetadata: { request in
            LiveContainerBridgeMetadataScanner.scan(request)
        }
    )
}

struct ContainerIndexConfiguration: Sendable {
    var installedProgramsTTL: TimeInterval = 5
    var startMenuEntriesTTL: TimeInterval = 5
    var storageByteCountTTL: TimeInterval = 30
    var bridgeMetadataTTL: TimeInterval = 1
    var storageScanConcurrencyLimit: Int = 2
}

protocol ContainerIndexClock: Sendable {
    func now() -> TimeInterval
}

private struct SystemContainerIndexClock: ContainerIndexClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

private actor ContainerStorageScanLimiter {
    private var availablePermits: Int
    private var waiterOrder: [UUID] = []
    private var waiters:
        [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(limit: Int) {
        precondition(limit > 0, "Storage scan concurrency limit must be positive.")
        availablePermits = limit
    }

    func withPermit<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard availablePermits == 0 else {
            availablePermits -= 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiterOrder.append(waiterID)
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    private func release() {
        while let waiterID = waiterOrder.first {
            waiterOrder.removeFirst()
            if let continuation = waiters.removeValue(
                forKey: waiterID
            ) {
                continuation.resume()
                return
            }
        }
        availablePermits += 1
    }

    private func cancelWaiter(_ waiterID: UUID) {
        if let continuation = waiters.removeValue(forKey: waiterID) {
            waiterOrder.removeAll { $0 == waiterID }
            continuation.resume(throwing: CancellationError())
        }
    }

    func waitingCount() -> Int {
        waiters.count
    }
}

private final class ContainerIndexTaskWaiter<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completion: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    func value(
        of task: Task<Value, any Error>
    ) async throws -> Value {
        Task.detached { [self] in
            complete(with: await task.result)
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            self.complete(with: .failure(CancellationError()))
        }
    }

    private func register(
        _ newContinuation: CheckedContinuation<Value, any Error>
    ) {
        let completedResult: Result<Value, any Error>? = lock.withLock {
            if let completion {
                return completion
            }
            continuation = newContinuation
            return nil
        }
        if let completedResult {
            newContinuation.resume(with: completedResult)
        }
    }

    private func complete(
        with result: Result<Value, any Error>
    ) {
        let pendingContinuation: CheckedContinuation<Value, any Error>? =
            lock.withLock {
                guard completion == nil else { return nil }
                completion = result
                defer { continuation = nil }
                return continuation
            }
        pendingContinuation?.resume(with: result)
    }
}

actor ContainerIndexService {
    static let shared = ContainerIndexService(scanners: .live)

    private struct Cached<Value: Sendable>: Sendable {
        let value: Value
        let observedAt: TimeInterval
    }

    private struct InFlight<Value: Sendable>: Sendable {
        let id: UUID
        let generation: UInt64
        let task: Task<Value, any Error>
    }

    private enum ValueSource<Value: Sendable>: Sendable {
        case cached(Value)
        case inFlight(Task<Value, any Error>)

        func value() async throws -> Value {
            switch self {
            case let .cached(value):
                try Task.checkCancellation()
                return value
            case let .inFlight(task):
                return try await ContainerIndexTaskWaiter<Value>()
                    .value(of: task)
            }
        }
    }

    private let scanners: ContainerIndexScanners
    private let configuration: ContainerIndexConfiguration
    private let counters: PerformanceCounters
    private let clock: any ContainerIndexClock
    private let storageLimiter: ContainerStorageScanLimiter

    private var installedProgramsCache:
        [ContainerIndexIdentity: Cached<[InstalledProgram]>] = [:]
    private var startMenuEntriesCache:
        [ContainerIndexIdentity: Cached<[WindowsStartMenuEntry]>] = [:]
    private var storageByteCountCache:
        [ContainerIndexIdentity: Cached<Int64>] = [:]
    private var bridgeMetadataCache:
        [ContainerIndexIdentity: Cached<ContainerBridgeIndexMetadata>] = [:]

    private var installedProgramsTasks:
        [ContainerIndexIdentity: InFlight<[InstalledProgram]>] = [:]
    private var startMenuEntriesTasks:
        [ContainerIndexIdentity: InFlight<[WindowsStartMenuEntry]>] = [:]
    private var storageByteCountTasks:
        [ContainerIndexIdentity: InFlight<Int64>] = [:]
    private var bridgeMetadataTasks:
        [ContainerIndexIdentity: InFlight<ContainerBridgeIndexMetadata>] = [:]

    private var installedProgramsGenerations:
        [ContainerIndexIdentity: UInt64] = [:]
    private var startMenuEntriesGenerations:
        [ContainerIndexIdentity: UInt64] = [:]
    private var storageByteCountGenerations:
        [ContainerIndexIdentity: UInt64] = [:]
    private var bridgeMetadataGenerations:
        [ContainerIndexIdentity: UInt64] = [:]
    private var currentIdentityByContainerID:
        [UUID: ContainerIndexIdentity] = [:]

    init(
        scanners: ContainerIndexScanners,
        configuration: ContainerIndexConfiguration = ContainerIndexConfiguration(),
        counters: PerformanceCounters = .shared,
        clock: any ContainerIndexClock = SystemContainerIndexClock()
    ) {
        precondition(
            configuration.installedProgramsTTL >= 0
                && configuration.startMenuEntriesTTL >= 0
                && configuration.storageByteCountTTL >= 0
                && configuration.bridgeMetadataTTL >= 0,
            "Container index TTLs must not be negative."
        )
        self.scanners = scanners
        self.configuration = configuration
        self.counters = counters
        self.clock = clock
        storageLimiter = ContainerStorageScanLimiter(
            limit: configuration.storageScanConcurrencyLimit
        )
    }

    func snapshot(
        for request: ContainerIndexRequest,
        scopes: ContainerIndexScope,
        bypassCache: Bool = false
    ) async throws -> ContainerIndexSnapshot {
        counters.increment(.containerIndexRequests)
        prepareIdentity(request.identity)
        if bypassCache {
            removeCachedValues(
                for: request.identity,
                scopes: scopes
            )
        }
        let generationToken = generationToken(
            for: request.identity,
            scopes: scopes
        )

        let installedProgramsSource = scopes.contains(.installedPrograms)
            ? installedProgramsSource(for: request)
            : nil
        let startMenuEntriesSource = scopes.contains(.startMenuEntries)
            ? startMenuEntriesSource(for: request)
            : nil
        let storageByteCountSource = scopes.contains(.storageByteCount)
            ? storageByteCountSource(for: request)
            : nil
        let bridgeMetadataSource = scopes.contains(.bridgeMetadata)
            ? bridgeMetadataSource(for: request)
            : nil

        let installedPrograms = try await installedProgramsSource?.value()
        let startMenuEntries = try await startMenuEntriesSource?.value()
        let storageByteCount = try await storageByteCountSource?.value()
        let bridgeMetadata = try await bridgeMetadataSource?.value()

        guard currentIdentityByContainerID[request.identity.containerID]
                == request.identity,
              generationToken == self.generationToken(
                  for: request.identity,
                  scopes: scopes
              ) else {
            throw CancellationError()
        }

        return ContainerIndexSnapshot(
            identity: request.identity,
            requestedScopes: scopes,
            installedPrograms: installedPrograms,
            startMenuEntries: startMenuEntries,
            storageByteCount: storageByteCount,
            bridgeMetadata: bridgeMetadata
        )
    }

    func invalidate(
        _ identity: ContainerIndexIdentity,
        scopes: ContainerIndexScope = .all
    ) {
        if scopes.contains(.installedPrograms) {
            installedProgramsCache.removeValue(forKey: identity)
            installedProgramsTasks.removeValue(forKey: identity)?.task.cancel()
            advanceGeneration(&installedProgramsGenerations, for: identity)
        }
        if scopes.contains(.startMenuEntries) {
            startMenuEntriesCache.removeValue(forKey: identity)
            startMenuEntriesTasks.removeValue(forKey: identity)?.task.cancel()
            advanceGeneration(&startMenuEntriesGenerations, for: identity)
        }
        if scopes.contains(.storageByteCount) {
            storageByteCountCache.removeValue(forKey: identity)
            storageByteCountTasks.removeValue(forKey: identity)?.task.cancel()
            advanceGeneration(&storageByteCountGenerations, for: identity)
        }
        if scopes.contains(.bridgeMetadata) {
            bridgeMetadataCache.removeValue(forKey: identity)
            bridgeMetadataTasks.removeValue(forKey: identity)?.task.cancel()
            advanceGeneration(&bridgeMetadataGenerations, for: identity)
        }
    }

    func invalidate(
        containerID: UUID,
        scopes: ContainerIndexScope = .all
    ) {
        if scopes == .all {
            for identity in knownIdentities()
            where identity.containerID == containerID {
                prune(identity)
            }
            currentIdentityByContainerID.removeValue(forKey: containerID)
            return
        }
        for identity in knownIdentities() where identity.containerID == containerID {
            invalidate(identity, scopes: scopes)
        }
    }

    func invalidateAll(scopes: ContainerIndexScope = .all) {
        for identity in knownIdentities() {
            invalidate(identity, scopes: scopes)
        }
    }

    func knownIdentityCount(for containerID: UUID) -> Int {
        knownIdentities().filter { $0.containerID == containerID }.count
    }

    func storageWaiterCount() async -> Int {
        await storageLimiter.waitingCount()
    }

    private func removeCachedValues(
        for identity: ContainerIndexIdentity,
        scopes: ContainerIndexScope
    ) {
        if scopes.contains(.installedPrograms) {
            installedProgramsCache.removeValue(forKey: identity)
        }
        if scopes.contains(.startMenuEntries) {
            startMenuEntriesCache.removeValue(forKey: identity)
        }
        if scopes.contains(.storageByteCount) {
            storageByteCountCache.removeValue(forKey: identity)
        }
        if scopes.contains(.bridgeMetadata) {
            bridgeMetadataCache.removeValue(forKey: identity)
        }
    }

    private func installedProgramsSource(
        for request: ContainerIndexRequest
    ) -> ValueSource<[InstalledProgram]> {
        let identity = request.identity
        if let cached = freshValue(
            in: &installedProgramsCache,
            for: identity,
            ttl: configuration.installedProgramsTTL
        ) {
            counters.increment(.containerIndexCacheHits)
            return .cached(cached)
        }
        if let task = installedProgramsTasks[identity]?.task {
            counters.increment(.containerIndexCoalescedRequests)
            return .inFlight(task)
        }

        let id = UUID()
        let generation = installedProgramsGenerations[identity, default: 0]
        let scanner = scanners.installedPrograms
        counters.increment(.containerIndexScans)
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try Task.checkCancellation()
                let value = try await scanner(request)
                try Task.checkCancellation()
                await self?.finishInstalledPrograms(
                    value,
                    for: identity,
                    id: id,
                    generation: generation
                )
                return value
            } catch {
                await self?.failInstalledPrograms(
                    for: identity,
                    id: id,
                    generation: generation
                )
                throw error
            }
        }
        installedProgramsTasks[identity] = InFlight(
            id: id,
            generation: generation,
            task: task
        )
        return .inFlight(task)
    }

    private func startMenuEntriesSource(
        for request: ContainerIndexRequest
    ) -> ValueSource<[WindowsStartMenuEntry]> {
        let identity = request.identity
        if let cached = freshValue(
            in: &startMenuEntriesCache,
            for: identity,
            ttl: configuration.startMenuEntriesTTL
        ) {
            counters.increment(.containerIndexCacheHits)
            return .cached(cached)
        }
        if let task = startMenuEntriesTasks[identity]?.task {
            counters.increment(.containerIndexCoalescedRequests)
            return .inFlight(task)
        }

        let id = UUID()
        let generation = startMenuEntriesGenerations[identity, default: 0]
        let scanner = scanners.startMenuEntries
        counters.increment(.containerIndexScans)
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try Task.checkCancellation()
                let value = try await scanner(request)
                try Task.checkCancellation()
                await self?.finishStartMenuEntries(
                    value,
                    for: identity,
                    id: id,
                    generation: generation
                )
                return value
            } catch {
                await self?.failStartMenuEntries(
                    for: identity,
                    id: id,
                    generation: generation
                )
                throw error
            }
        }
        startMenuEntriesTasks[identity] = InFlight(
            id: id,
            generation: generation,
            task: task
        )
        return .inFlight(task)
    }

    private func storageByteCountSource(
        for request: ContainerIndexRequest
    ) -> ValueSource<Int64> {
        let identity = request.identity
        if let cached = freshValue(
            in: &storageByteCountCache,
            for: identity,
            ttl: configuration.storageByteCountTTL
        ) {
            counters.increment(.containerIndexCacheHits)
            return .cached(cached)
        }
        if let task = storageByteCountTasks[identity]?.task {
            counters.increment(.containerIndexCoalescedRequests)
            return .inFlight(task)
        }

        let id = UUID()
        let generation = storageByteCountGenerations[identity, default: 0]
        let scanner = scanners.storageByteCount
        let limiter = storageLimiter
        counters.increment(.containerIndexScans)
        counters.increment(.containerStorageScans)
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                let value = try await limiter.withPermit {
                    try Task.checkCancellation()
                    return try await scanner(request)
                }
                try Task.checkCancellation()
                await self?.finishStorageByteCount(
                    value,
                    for: identity,
                    id: id,
                    generation: generation
                )
                return value
            } catch {
                await self?.failStorageByteCount(
                    for: identity,
                    id: id,
                    generation: generation
                )
                throw error
            }
        }
        storageByteCountTasks[identity] = InFlight(
            id: id,
            generation: generation,
            task: task
        )
        return .inFlight(task)
    }

    private func bridgeMetadataSource(
        for request: ContainerIndexRequest
    ) -> ValueSource<ContainerBridgeIndexMetadata> {
        let identity = request.identity
        if let cached = freshValue(
            in: &bridgeMetadataCache,
            for: identity,
            ttl: configuration.bridgeMetadataTTL
        ) {
            counters.increment(.containerIndexCacheHits)
            return .cached(cached)
        }
        if let task = bridgeMetadataTasks[identity]?.task {
            counters.increment(.containerIndexCoalescedRequests)
            return .inFlight(task)
        }

        let id = UUID()
        let generation = bridgeMetadataGenerations[identity, default: 0]
        let scanner = scanners.bridgeMetadata
        counters.increment(.containerIndexScans)
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try Task.checkCancellation()
                let value = try await scanner(request)
                try Task.checkCancellation()
                await self?.finishBridgeMetadata(
                    value,
                    for: identity,
                    id: id,
                    generation: generation
                )
                return value
            } catch {
                await self?.failBridgeMetadata(
                    for: identity,
                    id: id,
                    generation: generation
                )
                throw error
            }
        }
        bridgeMetadataTasks[identity] = InFlight(
            id: id,
            generation: generation,
            task: task
        )
        return .inFlight(task)
    }

    private func finishInstalledPrograms(
        _ value: [InstalledProgram],
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard installedProgramsTasks[identity]?.id == id,
              installedProgramsTasks[identity]?.generation == generation,
              installedProgramsGenerations[identity, default: 0] == generation else {
            return
        }
        installedProgramsTasks.removeValue(forKey: identity)
        installedProgramsCache[identity] = Cached(
            value: value,
            observedAt: clock.now()
        )
    }

    private func failInstalledPrograms(
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard installedProgramsTasks[identity]?.id == id,
              installedProgramsTasks[identity]?.generation == generation else {
            return
        }
        installedProgramsTasks.removeValue(forKey: identity)
    }

    private func finishStartMenuEntries(
        _ value: [WindowsStartMenuEntry],
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard startMenuEntriesTasks[identity]?.id == id,
              startMenuEntriesTasks[identity]?.generation == generation,
              startMenuEntriesGenerations[identity, default: 0] == generation else {
            return
        }
        startMenuEntriesTasks.removeValue(forKey: identity)
        startMenuEntriesCache[identity] = Cached(
            value: value,
            observedAt: clock.now()
        )
    }

    private func failStartMenuEntries(
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard startMenuEntriesTasks[identity]?.id == id,
              startMenuEntriesTasks[identity]?.generation == generation else {
            return
        }
        startMenuEntriesTasks.removeValue(forKey: identity)
    }

    private func finishStorageByteCount(
        _ value: Int64,
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard storageByteCountTasks[identity]?.id == id,
              storageByteCountTasks[identity]?.generation == generation,
              storageByteCountGenerations[identity, default: 0] == generation else {
            return
        }
        storageByteCountTasks.removeValue(forKey: identity)
        storageByteCountCache[identity] = Cached(
            value: value,
            observedAt: clock.now()
        )
    }

    private func failStorageByteCount(
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard storageByteCountTasks[identity]?.id == id,
              storageByteCountTasks[identity]?.generation == generation else {
            return
        }
        storageByteCountTasks.removeValue(forKey: identity)
    }

    private func finishBridgeMetadata(
        _ value: ContainerBridgeIndexMetadata,
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard bridgeMetadataTasks[identity]?.id == id,
              bridgeMetadataTasks[identity]?.generation == generation,
              bridgeMetadataGenerations[identity, default: 0] == generation else {
            return
        }
        bridgeMetadataTasks.removeValue(forKey: identity)
        bridgeMetadataCache[identity] = Cached(
            value: value,
            observedAt: clock.now()
        )
    }

    private func failBridgeMetadata(
        for identity: ContainerIndexIdentity,
        id: UUID,
        generation: UInt64
    ) {
        guard bridgeMetadataTasks[identity]?.id == id,
              bridgeMetadataTasks[identity]?.generation == generation else {
            return
        }
        bridgeMetadataTasks.removeValue(forKey: identity)
    }

    private func freshValue<Value: Sendable>(
        in cache: inout [ContainerIndexIdentity: Cached<Value>],
        for identity: ContainerIndexIdentity,
        ttl: TimeInterval
    ) -> Value? {
        guard let cached = cache[identity] else { return nil }
        let age = clock.now() - cached.observedAt
        guard age >= 0, age < ttl else {
            cache.removeValue(forKey: identity)
            return nil
        }
        return cached.value
    }

    private func advanceGeneration(
        _ generations: inout [ContainerIndexIdentity: UInt64],
        for identity: ContainerIndexIdentity
    ) {
        generations[identity, default: 0] &+= 1
    }

    private struct GenerationToken: Equatable {
        let installedPrograms: UInt64?
        let startMenuEntries: UInt64?
        let storageByteCount: UInt64?
        let bridgeMetadata: UInt64?
    }

    private func generationToken(
        for identity: ContainerIndexIdentity,
        scopes: ContainerIndexScope
    ) -> GenerationToken {
        GenerationToken(
            installedPrograms: scopes.contains(.installedPrograms)
                ? installedProgramsGenerations[identity, default: 0]
                : nil,
            startMenuEntries: scopes.contains(.startMenuEntries)
                ? startMenuEntriesGenerations[identity, default: 0]
                : nil,
            storageByteCount: scopes.contains(.storageByteCount)
                ? storageByteCountGenerations[identity, default: 0]
                : nil,
            bridgeMetadata: scopes.contains(.bridgeMetadata)
                ? bridgeMetadataGenerations[identity, default: 0]
                : nil
        )
    }

    private func prepareIdentity(_ identity: ContainerIndexIdentity) {
        if currentIdentityByContainerID[identity.containerID] == identity {
            return
        }

        for staleIdentity in knownIdentities()
        where staleIdentity.containerID == identity.containerID
            && staleIdentity != identity {
            prune(staleIdentity)
        }
        currentIdentityByContainerID[identity.containerID] = identity
    }

    private func prune(_ identity: ContainerIndexIdentity) {
        installedProgramsCache.removeValue(forKey: identity)
        startMenuEntriesCache.removeValue(forKey: identity)
        storageByteCountCache.removeValue(forKey: identity)
        bridgeMetadataCache.removeValue(forKey: identity)
        installedProgramsTasks.removeValue(forKey: identity)?.task.cancel()
        startMenuEntriesTasks.removeValue(forKey: identity)?.task.cancel()
        storageByteCountTasks.removeValue(forKey: identity)?.task.cancel()
        bridgeMetadataTasks.removeValue(forKey: identity)?.task.cancel()
        installedProgramsGenerations.removeValue(forKey: identity)
        startMenuEntriesGenerations.removeValue(forKey: identity)
        storageByteCountGenerations.removeValue(forKey: identity)
        bridgeMetadataGenerations.removeValue(forKey: identity)
    }

    private func knownIdentities() -> Set<ContainerIndexIdentity> {
        Set(installedProgramsCache.keys)
            .union(startMenuEntriesCache.keys)
            .union(storageByteCountCache.keys)
            .union(bridgeMetadataCache.keys)
            .union(installedProgramsTasks.keys)
            .union(startMenuEntriesTasks.keys)
            .union(storageByteCountTasks.keys)
            .union(bridgeMetadataTasks.keys)
            .union(installedProgramsGenerations.keys)
            .union(startMenuEntriesGenerations.keys)
            .union(storageByteCountGenerations.keys)
            .union(bridgeMetadataGenerations.keys)
            .union(currentIdentityByContainerID.values)
    }
}

private enum LiveContainerBridgeMetadataScanner {
    static func scan(
        _ request: ContainerIndexRequest
    ) -> ContainerBridgeIndexMetadata {
        let prefixPath = request.identity.path
        let protocolManifestURL = WineProtocolAssociationFormat.manifestURL(
            prefixPath: prefixPath
        )
        let shortcutManifestURL = WineDesktopShortcutFormat.manifestURL(
            prefixPath: prefixPath
        )
        let protocolContents = WineManifestFileReader.contents(
            at: protocolManifestURL,
            insidePrefix: prefixPath,
            maximumBytes: WineProtocolAssociationFormat.maximumManifestBytes
        ) ?? ""
        let shortcutContents = WineManifestFileReader.contents(
            at: shortcutManifestURL,
            insidePrefix: prefixPath,
            maximumBytes: WineDesktopShortcutFormat.maximumManifestBytes
        ) ?? ""

        var dependencies = [
            dependency(.protocolManifest, url: protocolManifestURL),
            dependency(.desktopShortcutManifest, url: shortcutManifestURL),
        ]
        let entries = WineDesktopShortcutFormat.entries(
            inManifest: shortcutContents
        ).compactMap { entry -> WineDesktopShortcutManifestEntry? in
            guard let shortcutURL = WineDesktopShortcutFormat.hostShortcutURL(
                windowsPath: entry.windowsShortcutPath,
                prefixPath: prefixPath
            ) else {
                return nil
            }
            dependencies.append(
                dependency(.desktopShortcut, url: shortcutURL)
            )
            guard isRegularNonSymbolicFile(shortcutURL) else {
                return nil
            }

            var validatedEntry = entry
            if let windowsIconPath = entry.windowsIconPath,
               let iconURL = WineDesktopShortcutFormat.hostIconURL(
                   windowsPath: windowsIconPath,
                   prefixPath: prefixPath
               ) {
                dependencies.append(
                    dependency(.desktopShortcutIcon, url: iconURL)
                )
                if !isRegularNonSymbolicFile(iconURL) {
                    validatedEntry.windowsIconPath = nil
                }
            } else {
                validatedEntry.windowsIconPath = nil
            }
            return validatedEntry
        }

        return ContainerBridgeIndexMetadata(
            protocolSchemes: WineProtocolAssociationFormat.schemes(
                inManifest: protocolContents
            ),
            desktopShortcutEntries: entries,
            dependencies: Array(Set(dependencies)).sorted {
                if $0.role != $1.role {
                    return $0.role.rawValue < $1.role.rawValue
                }
                return $0.path < $1.path
            }
        )
    }

    private static func dependency(
        _ role: ContainerBridgeDependencyMetadata.Role,
        url: URL
    ) -> ContainerBridgeDependencyMetadata {
        let normalizedURL = url.standardizedFileURL
        let values = try? normalizedURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
            ]
        )
        return ContainerBridgeDependencyMetadata(
            role: role,
            path: normalizedURL.path,
            byteCount: values?.fileSize.map(Int64.init),
            modificationDate: values?.contentModificationDate
        )
    }

    private static func isRegularNonSymbolicFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }
}
