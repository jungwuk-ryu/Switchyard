import AppCore
import Darwin
import Foundation

struct LiveLogJournalStore: @unchecked Sendable {
    let rootURL: URL

    private let fileManager: FileManager
    private let lock = NSRecursiveLock()

    init(
        rootURL: URL = Self.defaultRootURL(),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Switchyard", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
    }

    func journalURL(for containerID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "\(containerID.uuidString.lowercased()).jsonl",
            isDirectory: false
        )
    }

    func prepareJournal(
        for containerID: UUID,
        reset: Bool
    ) throws -> URL {
        try withLock {
            try ensureDirectory()
            let url = journalURL(for: containerID)
            let descriptor = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard descriptor >= 0 else {
                throw posixError(operation: "open live log journal")
            }
            defer { Darwin.close(descriptor) }

            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw posixError(operation: "protect live log journal")
            }
            if reset {
                guard flock(descriptor, LOCK_EX) == 0 else {
                    throw posixError(operation: "lock live log journal")
                }
                defer { flock(descriptor, LOCK_UN) }
                guard Darwin.ftruncate(descriptor, 0) == 0 else {
                    throw posixError(operation: "reset live log journal")
                }
            }
            return url
        }
    }

    func existingJournalURL(for containerID: UUID) -> URL? {
        withLock {
            let url = journalURL(for: containerID)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
            return url
        }
    }

    func clearJournal(for containerID: UUID) throws {
        try withLock {
            guard let url = existingJournalURL(for: containerID) else { return }
            try truncateJournal(at: url)
        }
    }

    func clearAllJournals() throws {
        try withLock {
            guard fileManager.fileExists(atPath: rootURL.path) else { return }
            for url in try journalURLs() {
                try truncateJournal(at: url)
            }
        }
    }

    func removeJournal(for containerID: UUID) throws {
        try withLock {
            let url = journalURL(for: containerID)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard Darwin.chmod(rootURL.path, mode_t(S_IRWXU)) == 0 else {
            throw posixError(operation: "protect live log directory")
        }
    }

    private func journalURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.pathExtension.lowercased() == "jsonl"
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func truncateJournal(at url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_APPEND | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw posixError(operation: "open live log journal")
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw posixError(operation: "lock live log journal")
        }
        defer { flock(descriptor, LOCK_UN) }
        guard Darwin.ftruncate(descriptor, 0) == 0 else {
            throw posixError(operation: "clear live log journal")
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func posixError(operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

final class LiveLogJournalMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryInterval: TimeInterval
    private var tailers: [UUID: LiveLogJournalTailer] = [:]

    init(deliveryInterval: TimeInterval = 0.25) {
        self.deliveryInterval = max(0, deliveryInterval)
    }

    func start(
        containerID: UUID,
        source: String,
        journalURL: URL,
        replayLimit: Int,
        onLogs: @escaping @Sendable ([LogLine]) -> Void
    ) throws {
        lock.lock()
        if let existing = tailers[containerID],
           existing.journalURL == journalURL {
            lock.unlock()
            return
        }
        let previous = tailers.removeValue(forKey: containerID)
        lock.unlock()
        previous?.cancel(deliverPending: false)

        let tailer = try LiveLogJournalTailer(
            containerID: containerID,
            source: source,
            journalURL: journalURL,
            replayLimit: replayLimit,
            deliveryInterval: deliveryInterval,
            onLogs: onLogs
        )

        lock.lock()
        tailers[containerID] = tailer
        lock.unlock()
        tailer.start()
    }

    func stop(containerID: UUID, deliverPending: Bool = true) {
        lock.lock()
        let tailer = tailers.removeValue(forKey: containerID)
        lock.unlock()
        tailer?.cancel(deliverPending: deliverPending)
    }

    func stopAll(deliverPending: Bool = false) {
        lock.lock()
        let activeTailers = Array(tailers.values)
        tailers.removeAll()
        lock.unlock()
        activeTailers.forEach { $0.cancel(deliverPending: deliverPending) }
    }

    func isMonitoring(containerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tailers[containerID] != nil
    }

    var monitoredContainerIDs: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(tailers.keys)
    }

    func pendingLineCount(containerID: UUID) -> Int {
        lock.lock()
        let tailer = tailers[containerID]
        lock.unlock()
        return tailer?.pendingLineCount ?? 0
    }
}

private final class LiveLogJournalTailer: @unchecked Sendable {
    let journalURL: URL

    private static let readChunkSize = 64 * 1_024
    private static let maximumReplayBytes: Int64 = 4 * 1_024 * 1_024
    private static let maximumPendingRecordBytes = 128 * 1_024
    private static let maximumPendingLineCount = 2_048

    private let containerID: UUID
    private let source: String
    private let replayLimit: Int
    private let deliveryInterval: TimeInterval
    private let onLogs: @Sendable ([LogLine]) -> Void
    private let queue: DispatchQueue
    private let descriptor: Int32
    private let sourceHandle: DispatchSourceFileSystemObject
    private let decoder = JSONDecoder()
    private let lifecycleLock = NSLock()

    private var offset: Int64 = 0
    private var pending = Data()
    private var discardingInitialFragment = false
    private var pendingDelivery: [LogLine] = []
    private var omittedLineCount = 0
    private var isDeliveryScheduled = false
    private var hasStarted = false
    private var isCancelled = false
    private var deliverPendingAfterCancellation = false

    init(
        containerID: UUID,
        source: String,
        journalURL: URL,
        replayLimit: Int,
        deliveryInterval: TimeInterval,
        onLogs: @escaping @Sendable ([LogLine]) -> Void
    ) throws {
        self.containerID = containerID
        self.source = source
        self.journalURL = journalURL
        self.replayLimit = max(0, replayLimit)
        self.deliveryInterval = deliveryInterval
        self.onLogs = onLogs
        queue = DispatchQueue(
            label: "dev.switchyard.live-log-journal.\(containerID.uuidString)",
            qos: .utility
        )

        descriptor = Darwin.open(journalURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        sourceHandle = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
    }

    func start() {
        lifecycleLock.lock()
        guard !hasStarted, !isCancelled else {
            lifecycleLock.unlock()
            return
        }
        hasStarted = true
        lifecycleLock.unlock()

        sourceHandle.setEventHandler { [weak self] in
            guard let self else { return }
            let events = sourceHandle.data
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                cancel()
                return
            }
            readAvailable(replaying: false)
        }
        sourceHandle.setCancelHandler { [descriptor] in
            Darwin.close(descriptor)
        }

        queue.sync {
            readAvailable(replaying: true)
            sourceHandle.resume()
        }
    }

    func cancel(deliverPending: Bool = true) {
        lifecycleLock.lock()
        guard !isCancelled else {
            lifecycleLock.unlock()
            return
        }
        isCancelled = true
        deliverPendingAfterCancellation = deliverPending
        let shouldCancelSource = hasStarted
        lifecycleLock.unlock()

        if shouldCancelSource {
            if deliverPending {
                queue.async { [self] in
                    flushPendingDelivery()
                }
            }
            sourceHandle.cancel()
        } else {
            Darwin.close(descriptor)
        }
    }

    var pendingLineCount: Int {
        queue.sync { pendingDelivery.count }
    }

    private func readAvailable(replaying: Bool) {
        lifecycleLock.lock()
        let shouldRead = !isCancelled
        lifecycleLock.unlock()
        guard shouldRead else { return }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else { return }
        let fileSize = Int64(fileStatus.st_size)
        var shouldLimitDelivery = replaying

        if replaying {
            offset = max(0, fileSize - Self.maximumReplayBytes)
            discardingInitialFragment = offset > 0
        } else if fileSize < offset {
            offset = 0
            pending.removeAll(keepingCapacity: true)
            discardingInitialFragment = false
            shouldLimitDelivery = true
        }

        var decodedLines: [LogLine] = []
        while offset < fileSize {
            let requestedCount = min(
                Self.readChunkSize,
                Int(fileSize - offset)
            )
            var bytes = [UInt8](repeating: 0, count: requestedCount)
            let bytesRead = Darwin.pread(
                descriptor,
                &bytes,
                requestedCount,
                off_t(offset)
            )
            guard bytesRead > 0 else { break }
            offset += Int64(bytesRead)
            let chunkLines = consume(Data(bytes.prefix(bytesRead)))
            if shouldLimitDelivery {
                decodedLines.append(contentsOf: chunkLines)
                if replayLimit == 0 {
                    decodedLines.removeAll(keepingCapacity: true)
                } else if decodedLines.count > replayLimit * 2 {
                    decodedLines = Array(decodedLines.suffix(replayLimit))
                }
            } else {
                enqueueForDelivery(chunkLines)
            }
        }

        if shouldLimitDelivery {
            if decodedLines.count > replayLimit {
                decodedLines = Array(decodedLines.suffix(replayLimit))
            }
            flushPendingDelivery()
            if !decodedLines.isEmpty {
                onLogs(decodedLines)
            }
        }

        var latestStatus = stat()
        if Darwin.fstat(descriptor, &latestStatus) == 0,
           Int64(latestStatus.st_size) != offset {
            queue.async { [weak self] in
                self?.readAvailable(replaying: false)
            }
        }
    }

    private func enqueueForDelivery(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }
        let overflow = pendingDelivery.count + lines.count - Self.maximumPendingLineCount
        if overflow > 0 {
            omittedLineCount += overflow
            if lines.count >= Self.maximumPendingLineCount {
                pendingDelivery.removeAll(keepingCapacity: true)
                pendingDelivery.append(
                    contentsOf: lines.suffix(Self.maximumPendingLineCount)
                )
            } else {
                pendingDelivery.removeFirst(min(overflow, pendingDelivery.count))
                pendingDelivery.append(contentsOf: lines)
            }
        } else {
            pendingDelivery.append(contentsOf: lines)
        }

        guard !isDeliveryScheduled else { return }
        isDeliveryScheduled = true
        queue.asyncAfter(
            deadline: .now() + deliveryInterval
        ) { [weak self] in
            self?.flushPendingDelivery()
        }
    }

    private func flushPendingDelivery() {
        lifecycleLock.lock()
        let shouldDeliver = !isCancelled || deliverPendingAfterCancellation
        if isCancelled {
            deliverPendingAfterCancellation = false
        }

        var lines = pendingDelivery
        pendingDelivery.removeAll(keepingCapacity: true)
        let omitted = omittedLineCount
        omittedLineCount = 0
        isDeliveryScheduled = false

        guard shouldDeliver else {
            lifecycleLock.unlock()
            return
        }
        if omitted > 0 {
            lines.append(
                LogLine(
                    containerID: containerID,
                    level: "warning",
                    source: source,
                    message: "\(omitted) high-volume log entries were omitted from the live view; the protected live journal continues with the newest entries."
                )
            )
        }
        if !lines.isEmpty {
            onLogs(lines)
        }
        lifecycleLock.unlock()
    }

    private func consume(_ data: Data) -> [LogLine] {
        var incoming = data
        if discardingInitialFragment {
            guard let newlineIndex = incoming.firstIndex(of: 0x0A) else {
                return []
            }
            incoming.removeSubrange(...newlineIndex)
            discardingInitialFragment = false
        }

        pending.append(incoming)
        var decodedLines: [LogLine] = []
        var recordStart = pending.startIndex

        while recordStart < pending.endIndex,
              let newlineIndex = pending[recordStart...].firstIndex(of: 0x0A) {
            let record = pending[recordStart..<newlineIndex]
            if !record.isEmpty,
               var line = try? decoder.decode(LogLine.self, from: Data(record)) {
                line.containerID = containerID
                if line.source.isEmpty {
                    line.source = source
                }
                decodedLines.append(line)
            }
            recordStart = pending.index(after: newlineIndex)
        }

        if recordStart > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<recordStart)
        }
        if pending.count > Self.maximumPendingRecordBytes {
            pending.removeAll(keepingCapacity: true)
        }
        return decodedLines
    }
}
