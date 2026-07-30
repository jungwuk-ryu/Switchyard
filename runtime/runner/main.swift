import AppCore
import Darwin
import Foundation

private enum RunnerRosettaAVXPolicy {
    static let current = RosettaAVXAdvertisingPolicy(
        isAppleSiliconHost: isAppleSiliconHost,
        macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    private static var isAppleSiliconHost: Bool {
        #if arch(arm64)
        true
        #elseif arch(x86_64)
        var isTranslated: Int32 = 0
        var size = MemoryLayout.size(ofValue: isTranslated)
        return sysctlbyname(
            "sysctl.proc_translated",
            &isTranslated,
            &size,
            nil,
            0
        ) == 0 && isTranslated == 1
        #else
        false
        #endif
    }
}

private enum SwitchyardRunnerError: LocalizedError {
    case missingWineServer(String)
    case invalidURLCallbackRequest
    case urlCallbackTimedOut
    case urlCallbackCommandFailed(Int32)
    case invalidDesktopShortcutRequest
    case desktopShortcutTimedOut
    case desktopShortcutCommandFailed(Int32)
    case wineServerCommandFailed(arguments: [String], status: Int32, output: String)
    case wineServerCommandTimedOut(arguments: [String])
    case wineRegistryCommandFailed(arguments: [String], status: Int32, output: String)
    case wineRegistryCommandTimedOut(arguments: [String])
    case wineProcessesCouldNotBeStopped([pid_t])
    case processInspectionFailed(Int32)
    case processInspectionTimedOut
    case processTableReadFailed
    case processTableReadIncomplete
    case windowsProcessIdentityUnavailable(UInt32)
    case windowsProcessIdentityChanged(UInt32)
    case windowsProcessTerminationFailed(processID: UInt32, status: Int32)
    case windowsProcessTerminationTimedOut(UInt32)
    case terminationRequested

    var errorDescription: String? {
        switch self {
        case let .missingWineServer(path):
            "wineserver was not found next to the Wine executable at \(path)."
        case .invalidURLCallbackRequest:
            "The Wine URL callback request was invalid."
        case .urlCallbackTimedOut:
            "The Wine URL callback did not finish within 15 seconds."
        case let .urlCallbackCommandFailed(status):
            "The Wine URL callback command failed with status \(status)."
        case .invalidDesktopShortcutRequest:
            "The Wine desktop shortcut request was invalid."
        case .desktopShortcutTimedOut:
            "The Wine desktop shortcut did not finish launching within 15 seconds."
        case let .desktopShortcutCommandFailed(status):
            "The Wine desktop shortcut command failed with status \(status)."
        case let .wineServerCommandFailed(arguments, status, output):
            "wineserver \(arguments.joined(separator: " ")) failed with status \(status): \(output)"
        case let .wineServerCommandTimedOut(arguments):
            "wineserver \(arguments.joined(separator: " ")) did not finish within 15 seconds."
        case let .wineRegistryCommandFailed(arguments, status, output):
            "Wine registry command \(arguments.joined(separator: " ")) failed with status \(status): \(output)"
        case let .wineRegistryCommandTimedOut(arguments):
            "Wine registry command \(arguments.joined(separator: " ")) did not finish within 15 seconds."
        case let .wineProcessesCouldNotBeStopped(processIDs):
            "Wine processes for this prefix could not be stopped: \(processIDs.map(String.init).joined(separator: ", "))."
        case let .processInspectionFailed(status):
            "The Wine process list command failed with status \(status)."
        case .processInspectionTimedOut:
            "The Wine process list command did not finish within 15 seconds."
        case .processTableReadFailed:
            "The host process table could not be read safely."
        case .processTableReadIncomplete:
            "The host process table changed too quickly to read completely."
        case let .windowsProcessIdentityUnavailable(processID):
            "Windows process \(processID) could not be identified safely."
        case let .windowsProcessIdentityChanged(processID):
            "Windows process \(processID) changed before it could be stopped."
        case let .windowsProcessTerminationFailed(processID, status):
            "Windows process \(processID) could not be stopped (exit code \(status))."
        case let .windowsProcessTerminationTimedOut(processID):
            "Windows process \(processID) did not stop within 15 seconds."
        case .terminationRequested:
            "Runner termination was requested before the child process started."
        }
    }
}

private struct InspectedWindowsProcess: Codable, Equatable {
    let executablePath: String
    let processID: UInt32?
}

private typealias WindowsProcessInstanceIdentity =
    ProcessInstanceIdentity<UInt32, String?>

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var isFinished = false

    func consumeAvailableData(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        data.append(handle.availableData)
    }

    func finish(from handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        data.append(Self.readAvailableData(from: handle))
        isFinished = true
    }

    func cancel(from handle: FileHandle) {
        handle.readabilityHandler = nil
        lock.lock()
        isFinished = true
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func readAvailableData(from handle: FileHandle) -> Data {
        // Wine helpers can leave wineserver holding the pipe's write end after
        // the direct child exits, so only drain bytes that are already readable.
        let descriptor = handle.fileDescriptor
        let originalFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            return Data()
        }
        defer {
            _ = Darwin.fcntl(descriptor, F_SETFL, originalFlags)
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount > 0 {
                result.append(contentsOf: buffer.prefix(byteCount))
            } else if byteCount == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return result
    }
}

private let wineServerCommandTimeout: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_WINESERVER_TIMEOUT"],
          let seconds = TimeInterval(value),
          seconds > 0 else {
        return 15
    }
    return seconds
}()

private let wineRegistryCommandTimeout: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment[
        "SWITCHYARD_TEST_WINE_REGISTRY_TIMEOUT"
    ],
    let seconds = TimeInterval(value),
    seconds > 0 else {
        return 15
    }
    return seconds
}()

private let callbackPrefixLockTimeout: Duration = .seconds(3)

private let outputDrainTimeout: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_OUTPUT_DRAIN_TIMEOUT"],
          let seconds = TimeInterval(value),
          seconds > 0 else {
        return 1
    }
    return seconds
}()

private let maximumLiveLogJournalBytes: Int64 = {
    guard let value = ProcessInfo.processInfo.environment[
        "SWITCHYARD_TEST_LIVE_LOG_MAX_BYTES"
    ],
    let bytes = Int64(value),
    bytes > 0 else {
        return 8 * 1_024 * 1_024
    }
    return bytes
}()

private let maximumPartialLogLineByteCount: Int = {
    guard let value = ProcessInfo.processInfo.environment[
        "SWITCHYARD_TEST_PARTIAL_LOG_MAX_BYTES"
    ],
    let bytes = Int(value),
    bytes > 0 else {
        return 64 * 1_024
    }
    return bytes
}()

private let signalExitGracePeriod: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_SIGNAL_EXIT_TIMEOUT"],
          let seconds = TimeInterval(value),
          seconds > 0 else {
        return 2
    }
    return seconds
}()

private let prefixProcessTerminationTimeout: TimeInterval = {
    guard let value = ProcessInfo.processInfo.environment["SWITCHYARD_TEST_PREFIX_PROCESS_TIMEOUT"],
          let seconds = TimeInterval(value),
          seconds > 0 else {
        return 2
    }
    return seconds
}()

private final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumPartialLineByteCount: Int
    private let counters: PerformanceCounters
    private var buffer = Data()
    private var hasPendingCarriageReturn = false
    private var isDiscardingOversizedLine = false

    init(
        maximumPartialLineByteCount: Int = maximumPartialLogLineByteCount,
        counters: PerformanceCounters = .shared
    ) {
        self.maximumPartialLineByteCount = max(1, maximumPartialLineByteCount)
        self.counters = counters
    }

    func consume(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var lines: [String] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if isDiscardingOversizedLine {
                guard let newlineIndex = data[cursor...].firstIndex(of: 0x0A) else {
                    recordDiscardedByteCount(data.distance(from: cursor, to: data.endIndex))
                    return lines
                }
                recordDiscardedByteCount(data.distance(from: cursor, to: newlineIndex))
                isDiscardingOversizedLine = false
                cursor = data.index(after: newlineIndex)
                continue
            }

            if hasPendingCarriageReturn {
                if data[cursor] == 0x0A {
                    hasPendingCarriageReturn = false
                    appendDecodedLine(buffer[...], to: &lines)
                    buffer.removeAll(keepingCapacity: true)
                    cursor = data.index(after: cursor)
                    continue
                }
                appendPendingCarriageReturn(to: &lines)
                if isDiscardingOversizedLine {
                    continue
                }
            }

            let newlineIndex = data[cursor...].firstIndex(of: 0x0A)
            var segmentEnd = newlineIndex ?? data.endIndex
            let endsWithCarriageReturn = segmentEnd > cursor
                && data[data.index(before: segmentEnd)] == 0x0D
            if endsWithCarriageReturn {
                segmentEnd = data.index(before: segmentEnd)
            }
            appendPartialBytes(data[cursor..<segmentEnd], to: &lines)

            guard let newlineIndex else {
                if endsWithCarriageReturn {
                    if isDiscardingOversizedLine {
                        recordDiscardedByteCount(1)
                    } else {
                        hasPendingCarriageReturn = true
                    }
                }
                return lines
            }
            if isDiscardingOversizedLine {
                isDiscardingOversizedLine = false
            } else {
                appendDecodedLine(buffer[...], to: &lines)
                buffer.removeAll(keepingCapacity: true)
            }
            cursor = data.index(after: newlineIndex)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        var emittedLines: [String] = []
        appendPendingCarriageReturn(to: &emittedLines)
        if let truncatedLine = emittedLines.first {
            buffer.removeAll(keepingCapacity: false)
            hasPendingCarriageReturn = false
            isDiscardingOversizedLine = false
            return truncatedLine
        }
        guard !isDiscardingOversizedLine else {
            buffer.removeAll(keepingCapacity: false)
            hasPendingCarriageReturn = false
            isDiscardingOversizedLine = false
            return nil
        }
        guard !buffer.isEmpty else { return nil }
        var pending = String(decoding: buffer, as: UTF8.self)
        if pending.last == "\r" {
            pending.removeLast()
        }
        buffer.removeAll(keepingCapacity: false)
        return pending
    }

    private func appendPendingCarriageReturn(to lines: inout [String]) {
        guard hasPendingCarriageReturn else { return }
        hasPendingCarriageReturn = false
        let carriageReturn = Data([0x0D])
        appendPartialBytes(carriageReturn[...], to: &lines)
    }

    private static func truncationMarker(
        maximumPartialLineByteCount: Int
    ) -> String {
        " … [truncated after \(maximumPartialLineByteCount) bytes; remainder discarded until newline]"
    }

    private func appendPartialBytes(
        _ data: Data.SubSequence,
        to lines: inout [String]
    ) {
        let availableByteCount = maximumPartialLineByteCount - buffer.count
        guard data.count > availableByteCount else {
            buffer.append(contentsOf: data)
            return
        }

        if availableByteCount > 0 {
            buffer.append(contentsOf: data.prefix(availableByteCount))
        }
        recordDiscardedByteCount(data.count - availableByteCount)
        counters.increment(.partialLogTruncations)

        // The retained raw prefix is byte-capped. The fixed marker is appended
        // exactly once, then every continuation byte is ignored until LF.
        let line = String(decoding: buffer, as: UTF8.self)
            + Self.truncationMarker(
                maximumPartialLineByteCount: maximumPartialLineByteCount
            )
        lines.append(line)
        buffer.removeAll(keepingCapacity: true)
        isDiscardingOversizedLine = true
    }

    private func appendDecodedLine(
        _ data: Data.SubSequence,
        to lines: inout [String]
    ) {
        var line = String(decoding: data, as: UTF8.self)
        if line.last == "\r" {
            line.removeLast()
        }
        lines.append(line)
    }

    private func recordDiscardedByteCount(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        counters.increment(.partialLogDiscardedBytes, by: UInt64(byteCount))
    }
}

private final class DebugLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var isClosed = false

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if Darwin.chmod(directory.path, mode_t(S_IRWXU)) != 0 {
            throw Self.posixError(operation: "protect debug log directory")
        }

        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Self.posixError(operation: "open debug log")
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let error = Self.posixError(operation: "protect debug log")
            Darwin.close(descriptor)
            throw error
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func write(source: String, level: String, message: String) {
        guard let data = "[\(source)] [\(level)] \(message)\n".data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        try? handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        try? handle.synchronize()
        try? handle.close()
        isClosed = true
    }

    private static func posixError(operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

private final class LiveLogViewActivityProbe {
    private let lockPath: String
    private var descriptor: Int32 = -1

    init(journalPath: String) {
        lockPath = URL(fileURLWithPath: journalPath)
            .deletingLastPathComponent()
            .appendingPathComponent(
                LiveLogJournalFormat.viewActivityLockFilename,
                isDirectory: false
            )
            .path
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func isViewActive() -> Bool {
        if descriptor < 0 {
            descriptor = Darwin.open(lockPath, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            // Journals created before the activity protocol remain live.
            return true
        }

        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return true
    }
}

private final class LiveLogJournalWriter: @unchecked Sendable {
    private static let maximumMessageBytes = 64 * 1_024
    private static let maximumTrackedEvents = 64
    private static let maximumSuppressedOccurrences = 256
    private static let repetitionFlushInterval: TimeInterval = 0.5
    private static let activityPollInterval: TimeInterval = 0.25
    private static let maximumBufferedLineCount = 5_000
    private static let maximumBufferedBytes = 4 * 1_024 * 1_024

    private struct RepetitionState {
        var latestLine: LogLine
        var suppressedOccurrenceCount: Int
        var lastEmissionDate: Date
    }

    private struct BufferedLine {
        var timestamp: Date
        var level: String
        var message: String
        var estimatedByteCount: Int
    }

    private struct ResetGeneration: Equatable {
        var firstWord: UInt64 = 0
        var secondWord: UInt64 = 0
    }

    private let lock = NSLock()
    private let descriptor: Int32
    private let resetGenerationDescriptor: Int32
    private let source: String
    private let encoder = JSONEncoder()
    private let viewActivityProbe: LiveLogViewActivityProbe
    private var activityTimer: DispatchSourceTimer?
    private var repetitionStates: [LiveLogEventKey: RepetitionState] = [:]
    private var bufferedLines: [BufferedLine] = []
    private var bufferedLineStartIndex = 0
    private var bufferedByteCount = 0
    private var omittedBufferedLineCount = 0
    private var observedResetGeneration: ResetGeneration
    private var lastKnownJournalSize: Int64 = 0
    private var lastDetectedJournalResetDate: Date?
    private var isFilteringActive: Bool
    private var isClosed = false

    init(path: String, source: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard Darwin.chmod(directory.path, mode_t(S_IRWXU)) == 0 else {
            throw Self.posixError(operation: "protect live log directory")
        }

        descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw Self.posixError(operation: "open live log journal")
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let error = Self.posixError(operation: "protect live log journal")
            Darwin.close(descriptor)
            throw error
        }
        self.source = source
        viewActivityProbe = LiveLogViewActivityProbe(journalPath: path)
        isFilteringActive = viewActivityProbe.isViewActive()
        do {
            let resetGeneration = try Self.openResetGeneration(
                forJournalPath: url.path,
                journalDescriptor: descriptor
            )
            resetGenerationDescriptor = resetGeneration.descriptor
            observedResetGeneration = resetGeneration.generation
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        updateLastKnownJournalSize()
        startActivityTimer()
    }

    func write(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }

        let timestamp = Date()
        let boundedMessage = boundedMessage(message)
        guard isFilteringActive else {
            buffer(
                timestamp: timestamp,
                level: level,
                message: boundedMessage
            )
            return
        }

        discardRepetitionStateIfJournalWasReset()
        let key = LiveLogPolicy.eventKey(
            containerID: nil,
            level: level,
            source: source,
            message: boundedMessage
        )
        if var state = repetitionStates[key] {
            if timestamp.timeIntervalSince(state.latestLine.timestamp)
                >= Self.repetitionFlushInterval {
                var linesToPersist = drainPendingRepetitionSummaries()
                let line = LogLine(
                    timestamp: timestamp,
                    level: level,
                    source: source,
                    message: boundedMessage
                )
                linesToPersist.append(line)
                _ = persist(linesToPersist, afterJournalReset: [line])
                repetitionStates[key] = RepetitionState(
                    latestLine: line,
                    suppressedOccurrenceCount: 0,
                    lastEmissionDate: timestamp
                )
                return
            }

            state.latestLine.timestamp = timestamp
            state.latestLine.message = boundedMessage
            let suppressedCount = state.suppressedOccurrenceCount + 1
            if timestamp.timeIntervalSince(state.lastEmissionDate)
                >= Self.repetitionFlushInterval
                || suppressedCount >= Self.maximumSuppressedOccurrences {
                state.suppressedOccurrenceCount = suppressedCount
                repetitionStates[key] = state
                let resetLine = LogLine(
                    timestamp: timestamp,
                    level: level,
                    source: source,
                    message: boundedMessage
                )
                if persist(
                    drainPendingRepetitionSummaries(),
                    afterJournalReset: [resetLine]
                ) {
                    repetitionStates[key] = RepetitionState(
                        latestLine: resetLine,
                        suppressedOccurrenceCount: 0,
                        lastEmissionDate: timestamp
                    )
                }
            } else {
                state.suppressedOccurrenceCount = suppressedCount
                repetitionStates[key] = state
            }
            return
        }

        var linesToPersist = drainPendingRepetitionSummaries()
        if repetitionStates.count >= Self.maximumTrackedEvents {
            repetitionStates.removeAll(keepingCapacity: true)
        }
        let line = LogLine(
            timestamp: timestamp,
            level: level,
            source: source,
            message: boundedMessage
        )
        linesToPersist.append(line)
        _ = persist(linesToPersist, afterJournalReset: [line])
        repetitionStates[key] = RepetitionState(
            latestLine: line,
            suppressedOccurrenceCount: 0,
            lastEmissionDate: timestamp
        )
    }

    func close() {
        activityTimer?.cancel()
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        if isFilteringActive {
            _ = persist(drainPendingRepetitionSummaries())
        } else {
            discardBufferedLinesIfJournalWasReset()
            flushBufferedLines()
        }
        repetitionStates.removeAll()
        Darwin.fsync(descriptor)
        Darwin.close(descriptor)
        Darwin.close(resetGenerationDescriptor)
        isClosed = true
    }

    private func startActivityTimer() {
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(
            deadline: .now() + Self.activityPollInterval,
            repeating: Self.activityPollInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.refreshActivityMode()
        }
        activityTimer = timer
        timer.resume()
    }

    private func refreshActivityMode() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }

        let shouldFilter = viewActivityProbe.isViewActive()
        guard shouldFilter != isFilteringActive else {
            if !shouldFilter {
                discardBufferedLinesIfJournalWasReset()
                flushBufferedLines()
            }
            return
        }

        if shouldFilter {
            discardBufferedLinesIfJournalWasReset()
            flushBufferedLines()
        } else {
            _ = persist(drainPendingRepetitionSummaries())
            repetitionStates.removeAll(keepingCapacity: true)
        }
        isFilteringActive = shouldFilter
    }

    private func buffer(
        timestamp: Date,
        level: String,
        message: String
    ) {
        let estimatedByteCount = message.utf8.count + level.utf8.count + 128
        bufferedLines.append(
            BufferedLine(
                timestamp: timestamp,
                level: level,
                message: message,
                estimatedByteCount: estimatedByteCount
            )
        )
        bufferedByteCount += estimatedByteCount

        while bufferedLines.count - bufferedLineStartIndex
                > Self.maximumBufferedLineCount
            || bufferedByteCount > Self.maximumBufferedBytes {
            bufferedByteCount -= bufferedLines[bufferedLineStartIndex]
                .estimatedByteCount
            bufferedLineStartIndex += 1
            omittedBufferedLineCount += 1
        }

        if bufferedLineStartIndex >= 1_024,
           bufferedLineStartIndex * 2 >= bufferedLines.count {
            bufferedLines.removeFirst(bufferedLineStartIndex)
            bufferedLineStartIndex = 0
        }
    }

    private func flushBufferedLines() {
        let retainedLines = bufferedLines[bufferedLineStartIndex...]
        guard !retainedLines.isEmpty || omittedBufferedLineCount > 0 else {
            return
        }

        var lines: [LogLine] = []
        lines.reserveCapacity(
            retainedLines.count + (omittedBufferedLineCount > 0 ? 1 : 0)
        )
        if omittedBufferedLineCount > 0 {
            lines.append(
                LogLine(
                    timestamp: retainedLines.first?.timestamp ?? Date(),
                    level: "warning",
                    source: source,
                    message: "\(omittedBufferedLineCount) high-volume log entries were omitted while Logs was closed; the protected debug run log retains complete output when developer logging is enabled."
                )
            )
        }
        lines.append(
            contentsOf: retainedLines.map {
                LogLine(
                    timestamp: $0.timestamp,
                    level: $0.level,
                    source: source,
                    message: $0.message
                )
            }
        )

        bufferedLines.removeAll(keepingCapacity: true)
        bufferedLineStartIndex = 0
        bufferedByteCount = 0
        omittedBufferedLineCount = 0
        _ = persist(lines)
    }

    private func discardBufferedLinesIfJournalWasReset() {
        guard discardRepetitionStateIfJournalWasReset(
            checkSizeRollback: true
        ) else {
            return
        }

        if let resetDate = lastDetectedJournalResetDate {
            bufferedLines = bufferedLines[bufferedLineStartIndex...].filter {
                $0.timestamp >= resetDate
            }
        } else {
            bufferedLines.removeAll(keepingCapacity: true)
        }
        bufferedLineStartIndex = 0
        bufferedByteCount = bufferedLines.reduce(into: 0) {
            $0 += $1.estimatedByteCount
        }
        omittedBufferedLineCount = 0
    }

    private func boundedMessage(_ message: String) -> String {
        let bytes = message.utf8
        guard bytes.count > Self.maximumMessageBytes else { return message }
        let retained = bytes.prefix(Self.maximumMessageBytes - 64)
        return String(decoding: retained, as: UTF8.self)
            + " … [live log entry truncated]"
    }

    private func encode(_ line: LogLine) -> Data? {
        guard var data = try? encoder.encode(line) else { return nil }
        data.append(0x0A)
        return data
    }

    private func drainPendingRepetitionSummaries() -> [LogLine] {
        var summaries: [LogLine] = []
        summaries.reserveCapacity(repetitionStates.count)

        for key in Array(repetitionStates.keys) {
            guard var state = repetitionStates[key],
                  state.suppressedOccurrenceCount > 0 else {
                continue
            }
            var summary = state.latestLine
            summary.id = UUID()
            summary.occurrenceCount = state.suppressedOccurrenceCount
            summaries.append(summary)

            state.suppressedOccurrenceCount = 0
            state.lastEmissionDate = state.latestLine.timestamp
            repetitionStates[key] = state
        }
        return summaries.sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    private func persist(
        _ lines: [LogLine],
        afterJournalReset resetLines: [LogLine] = []
    ) -> Bool {
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }

        let journalWasReset = discardRepetitionStateIfJournalWasReset(
            checkSizeRollback: true
        )
        let linesToPersist = journalWasReset ? resetLines : lines
        var encodedLines = Data()
        for line in linesToPersist {
            guard let encodedLine = encode(line) else { continue }
            encodedLines.append(encodedLine)
        }
        guard !encodedLines.isEmpty else { return journalWasReset }

        var payload = Data()
        var journalRolledOver = false
        var fileStatus = stat()
        if Darwin.fstat(descriptor, &fileStatus) == 0,
           Int64(fileStatus.st_size) + Int64(encodedLines.count)
                > maximumLiveLogJournalBytes {
            guard let generation = Self.replaceResetGeneration(
                on: resetGenerationDescriptor
            ) else {
                return journalWasReset
            }
            observedResetGeneration = generation
            repetitionStates.removeAll(keepingCapacity: true)
            guard Darwin.ftruncate(descriptor, 0) == 0 else {
                return true
            }
            journalRolledOver = true
            let rolloverLine = LogLine(
                level: "warning",
                source: source,
                message: "Live log journal reached its size limit; older entries were discarded."
            )
            payload.append(encodedLines)
            if let encodedRollover = encode(rolloverLine) {
                payload.append(encodedRollover)
            }
        } else {
            payload.append(encodedLines)
        }
        writeAll(payload)
        updateLastKnownJournalSize()
        return journalWasReset || journalRolledOver
    }

    @discardableResult
    private func discardRepetitionStateIfJournalWasReset(
        checkSizeRollback: Bool = false
    ) -> Bool {
        lastDetectedJournalResetDate = nil
        var journalWasReset = false
        if let generation = Self.readResetGeneration(
            from: resetGenerationDescriptor
        ), generation != observedResetGeneration {
            observedResetGeneration = generation
            journalWasReset = true
            lastDetectedJournalResetDate = Self.modificationDate(
                of: resetGenerationDescriptor
            )
        }

        var currentSize: Int64?
        if checkSizeRollback || journalWasReset {
            var fileStatus = stat()
            if Darwin.fstat(descriptor, &fileStatus) == 0 {
                currentSize = Int64(fileStatus.st_size)
                if checkSizeRollback,
                   let currentSize,
                   currentSize < lastKnownJournalSize {
                    journalWasReset = true
                    if lastDetectedJournalResetDate == nil {
                        lastDetectedJournalResetDate = Self.modificationDate(
                            of: descriptor
                        )
                    }
                }
            }
        }
        guard journalWasReset else { return false }
        repetitionStates.removeAll(keepingCapacity: true)
        if let currentSize {
            lastKnownJournalSize = currentSize
        }
        return true
    }

    private static func modificationDate(of descriptor: Int32) -> Date? {
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            return nil
        }
        return Date(
            timeIntervalSince1970: TimeInterval(
                fileStatus.st_mtimespec.tv_sec
            ) + TimeInterval(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private func updateLastKnownJournalSize() {
        var fileStatus = stat()
        if Darwin.fstat(descriptor, &fileStatus) == 0 {
            lastKnownJournalSize = Int64(fileStatus.st_size)
        }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard var baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, baseAddress, remaining)
                if written > 0 {
                    remaining -= written
                    baseAddress = baseAddress.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func openResetGeneration(
        forJournalPath journalPath: String,
        journalDescriptor: Int32
    ) throws -> (descriptor: Int32, generation: ResetGeneration) {
        guard flock(journalDescriptor, LOCK_EX) == 0 else {
            throw posixError(operation: "lock live log journal")
        }
        defer { flock(journalDescriptor, LOCK_UN) }

        let path = journalPath + LiveLogJournalFormat.resetGenerationSuffix
        let descriptor = Darwin.open(
            path,
            O_RDWR | O_CREAT | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw posixError(operation: "open live log reset generation")
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let error = posixError(
                operation: "protect live log reset generation"
            )
            Darwin.close(descriptor)
            throw error
        }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            let error = posixError(
                operation: "inspect live log reset generation"
            )
            Darwin.close(descriptor)
            throw error
        }
        if Int64(fileStatus.st_size)
            != Int64(LiveLogJournalFormat.resetGenerationByteCount) {
            guard replaceResetGeneration(on: descriptor) != nil else {
                let error = posixError(
                    operation: "initialize live log reset generation"
                )
                Darwin.close(descriptor)
                throw error
            }
        }
        guard let generation = readResetGeneration(from: descriptor) else {
            let error = posixError(operation: "read live log reset generation")
            Darwin.close(descriptor)
            throw error
        }
        return (descriptor, generation)
    }

    private static func replaceResetGeneration(
        on descriptor: Int32
    ) -> ResetGeneration? {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              write(
                  LiveLogJournalFormat.makeResetGeneration(),
                  to: descriptor
              ) else {
            return nil
        }
        return readResetGeneration(from: descriptor)
    }

    private static func readResetGeneration(
        from descriptor: Int32
    ) -> ResetGeneration? {
        guard MemoryLayout<ResetGeneration>.size
            == LiveLogJournalFormat.resetGenerationByteCount else {
            return nil
        }
        var generation = ResetGeneration()
        let readCount = withUnsafeMutableBytes(of: &generation) { buffer in
            Darwin.pread(
                descriptor,
                buffer.baseAddress,
                buffer.count,
                0
            )
        }
        guard readCount == MemoryLayout<ResetGeneration>.size else {
            return nil
        }
        return generation
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Bool {
        var succeeded = true
        data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset: off_t = 0
            while remaining > 0 {
                let written = Darwin.pwrite(
                    descriptor,
                    address,
                    remaining,
                    offset
                )
                if written > 0 {
                    remaining -= written
                    offset += off_t(written)
                    address = address.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    succeeded = false
                    return
                }
            }
        }
        return succeeded
    }

    private static func posixError(operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

private final class RunnerProcessRegistry: @unchecked Sendable {
    static let shared = RunnerProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var terminationSignal: Int32?

    func launch(_ process: Process) throws {
        lock.lock()
        guard terminationSignal == nil else {
            lock.unlock()
            throw SwitchyardRunnerError.terminationRequested
        }
        let identifier = ObjectIdentifier(process)
        processes[identifier] = process
        do {
            try process.run()
            lock.unlock()
        } catch {
            processes.removeValue(forKey: identifier)
            lock.unlock()
            throw error
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func requestTermination(signalNumber: Int32) -> Int32 {
        lock.lock()
        if terminationSignal == nil {
            terminationSignal = signalNumber
        }
        let exitStatus = 128 + (terminationSignal ?? signalNumber)
        let activeProcesses = Array(processes.values)
        lock.unlock()

        for activeProcess in activeProcesses {
            stopProcessWithinDeadline(activeProcess)
        }
        return exitStatus
    }

    var requestedExitStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return terminationSignal.map { 128 + $0 }
    }
}

private func runnerExit(_ status: Int32) -> Never {
    Foundation.exit(RunnerProcessRegistry.shared.requestedExitStatus ?? status)
}

private final class TerminationSignalMonitor {
    private let sources: [DispatchSourceSignal]

    init() {
        signal(SIGPIPE, SIG_IGN)
        sources = [SIGTERM, SIGINT].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler {
                let status = RunnerProcessRegistry.shared.requestTermination(
                    signalNumber: signalNumber
                )
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + signalExitGracePeriod
                ) {
                    Foundation.exit(status)
                }
            }
            source.resume()
            return source
        }
    }

    deinit {
        for source in sources {
            source.cancel()
        }
    }
}

@main
struct SwitchyardRunner {
    static func main() {
        let signalMonitor = TerminationSignalMonitor()

        withExtendedLifetime(signalMonitor) {
            runCommand()
        }
    }

    private static func runCommand() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            printUsage()
            runnerExit(2)
        }

        switch arguments[0] {
        case "diagnose":
            print("switchyard-runner ok")
        case "inspect-session":
            do {
                try inspectSession(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(
                    Data("Unable to inspect Wine prefix session: \(error.localizedDescription)\n".utf8)
                )
                runnerExit(2)
            }
        case "probe-prefix":
            probePrefix(arguments: Array(arguments.dropFirst()))
        case "probe-prefix-host":
            probePrefixHost(arguments: Array(arguments.dropFirst()))
        case "list-processes":
            do {
                try listProcesses(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("Unable to inspect Wine processes: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "list-process-details":
            do {
                try listProcessDetails(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("Unable to inspect Wine process details: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "list-host-processes":
            do {
                try listHostProcesses(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("Unable to inspect Wine host processes: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "terminate-process":
            do {
                try terminateProcess(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("Unable to stop the Windows process: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "stop-prefix":
            do {
                try stopPrefix(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("Unable to stop Wine prefix session: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "open-url":
            do {
                try openURL(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("switchyard-runner failed to deliver a URL callback: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "open-shortcut":
            do {
                try openDesktopShortcut(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("switchyard-runner failed to open a desktop shortcut: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        case "run":
            do {
                try run(arguments: Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("switchyard-runner failed: \(error.localizedDescription)\n".utf8))
                runnerExit(1)
            }
        default:
            printUsage()
            runnerExit(2)
        }
    }

    private static func run(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--plan" else {
            printUsage()
            runnerExit(2)
        }

        let planURL = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: planURL)
        var plan = try JSONDecoder().decode(CommandPlan.self, from: data)
        plan.environment = RunnerRosettaAVXPolicy.current.resolving(plan.environment)
        let debugLogWriter = openDebugLogWriter(path: plan.debugLogPath, source: plan.logSource)
        let liveLogWriter = openLiveLogWriter(path: plan.liveLogPath, source: plan.logSource)
        defer {
            debugLogWriter?.close()
            liveLogWriter?.close()
        }
        let environmentKeys = plan.environment.keys.sorted().joined(separator: ",")
        emit(
            source: plan.logSource,
            level: "info",
            message: "switchyard-runner start: executable=\(plan.executable) argumentCount=\(plan.arguments.count)",
            debugLogWriter: debugLogWriter,
            liveLogWriter: liveLogWriter
        )
        emit(
            source: plan.logSource,
            level: "info",
            message: "environment-keys=\(environmentKeys)",
            debugLogWriter: debugLogWriter,
            liveLogWriter: liveLogWriter
        )

        if plan.terminateExistingPrefixSession == true {
            try terminateExistingPrefixSession(plan: plan)
        }
        if let displayMode = plan.containerDisplayMode {
            try configureContainerDisplay(displayMode, plan: plan)
            emit(
                source: plan.logSource,
                level: "info",
                message: "container display mode configured: \(displayMode.rawValue)",
                debugLogWriter: debugLogWriter,
                liveLogWriter: liveLogWriter
            )
        }
        try preparePrivateDesktop(plan: plan)
        var protocolMonitor = try startProtocolAssociationMonitor(plan: plan)
        defer {
            stopProtocolAssociationMonitor(&protocolMonitor)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        if let workingDirectory = plan.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutBuffer = LineAccumulator()
        let stderrBuffer = LineAccumulator()
        let forwardsCapturedOutput = plan.forwardCapturedOutput != false
        try RunnerProcessRegistry.shared.launch(process)
        let outputGroup = DispatchGroup()
        streamOutput(
            from: stdout.fileHandleForReading,
            source: plan.logSource,
            level: "info",
            to: forwardsCapturedOutput ? FileHandle.standardOutput : nil,
            accumulator: stdoutBuffer,
            debugLogWriter: debugLogWriter,
            liveLogWriter: liveLogWriter,
            group: outputGroup
        )
        streamOutput(
            from: stderr.fileHandleForReading,
            source: plan.logSource,
            level: "error",
            to: forwardsCapturedOutput ? FileHandle.standardError : nil,
            accumulator: stderrBuffer,
            debugLogWriter: debugLogWriter,
            liveLogWriter: liveLogWriter,
            group: outputGroup
        )
        process.waitUntilExit()
        RunnerProcessRegistry.shared.clear(process)
        if !waitForOutputDrain(
            outputGroup,
            plan: plan,
            debugLogWriter: debugLogWriter,
            liveLogWriter: liveLogWriter
        ) {
            emit(
                source: plan.logSource,
                level: "warning",
                message: "output drain timed out after the launched process exited; a descendant may still hold its output streams open",
                debugLogWriter: debugLogWriter,
                liveLogWriter: liveLogWriter
            )
        }
        emit(
            source: plan.logSource,
            level: "info",
            message: "switchyard-runner exit: status=\(process.terminationStatus)",
            debugLogWriter: debugLogWriter,
            liveLogWriter: liveLogWriter
        )
        debugLogWriter?.close()
        liveLogWriter?.close()
        stopProtocolAssociationMonitor(&protocolMonitor)
        runnerExit(process.terminationStatus)
    }

    private static func listProcesses(arguments: [String]) throws {
        let configuration = processInspectionConfiguration(arguments: arguments)
        let prefixLock = try WinePrefixFileLock(prefixPath: configuration.prefixPath, mode: .shared)
        defer { prefixLock.unlock() }
        validateProcessInspectionPaths(configuration)
        let paths = Set(
            try processInspectionOutput(
                winePath: configuration.winePath,
                prefixPath: configuration.prefixPath,
                properties: ["ExecutablePath"]
            )
                .components(separatedBy: .newlines)
                .dropFirst()
                .compactMap(WineProtocolAssociationFormat.normalizedWindowsExecutablePath)
                .filter { !isProcessInspectionHelper($0) }
        ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        FileHandle.standardOutput.write(try JSONEncoder().encode(paths))
    }

    private static func listProcessDetails(arguments: [String]) throws {
        let configuration = processInspectionConfiguration(arguments: arguments)
        let prefixLock = try WinePrefixFileLock(prefixPath: configuration.prefixPath, mode: .shared)
        defer { prefixLock.unlock() }
        validateProcessInspectionPaths(configuration)

        let detailedOutput = try processInspectionOutput(
            winePath: configuration.winePath,
            prefixPath: configuration.prefixPath,
            properties: ["ExecutablePath", "ProcessId"]
        )
        var details = processDetails(from: detailedOutput)
        if details.isEmpty {
            let pathOutput = try processInspectionOutput(
                winePath: configuration.winePath,
                prefixPath: configuration.prefixPath,
                properties: ["ExecutablePath"]
            )
            details = Set(
                pathOutput
                    .components(separatedBy: .newlines)
                    .dropFirst()
                    .compactMap(WineProtocolAssociationFormat.normalizedWindowsExecutablePath)
                    .filter { !isProcessInspectionHelper($0) }
            )
            .map { InspectedWindowsProcess(executablePath: $0, processID: nil) }
        }

        details.sort {
            let pathOrder = $0.executablePath.localizedStandardCompare($1.executablePath)
            if pathOrder != .orderedSame {
                return pathOrder == .orderedAscending
            }
            return ($0.processID ?? 0) < ($1.processID ?? 0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(details))
    }

    private static func processInspectionConfiguration(
        arguments: [String]
    ) -> (winePath: String, prefixPath: String) {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix" else {
            printUsage()
            runnerExit(2)
        }
        return (arguments[1], arguments[3])
    }

    private static func validateProcessInspectionPaths(
        _ configuration: (winePath: String, prefixPath: String)
    ) {
        guard FileManager.default.isExecutableFile(atPath: configuration.winePath),
              FileManager.default.fileExists(atPath: configuration.prefixPath) else {
            printUsage()
            runnerExit(2)
        }
    }

    private static func processInspectionOutput(
        winePath: String,
        prefixPath: String,
        properties: [String]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let collector = ProcessOutputCollector()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = ["wmic", "process", "get", properties.joined(separator: ",")]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "WINEPREFIX": prefixPath,
            "WINEDEBUG": "-all"
        ]) { _, new in new }
        process.currentDirectoryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.consumeAvailableData(from: handle)
        }
        defer { RunnerProcessRegistry.shared.clear(process) }

        do {
            try RunnerProcessRegistry.shared.launch(process)
        } catch {
            collector.cancel(from: output.fileHandleForReading)
            throw error
        }
        guard waitForExit(process, timeout: wineServerCommandTimeout) else {
            stopProcessWithinDeadline(process)
            collector.finish(from: output.fileHandleForReading)
            throw SwitchyardRunnerError.processInspectionTimedOut
        }
        collector.finish(from: output.fileHandleForReading)
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.processInspectionFailed(process.terminationStatus)
        }
        return collector.text
    }

    private static func processDetails(from output: String) -> [InspectedWindowsProcess] {
        var seenProcessIDs: Set<UInt32> = []
        return output
            .components(separatedBy: .newlines)
            .dropFirst()
            .compactMap { rawLine -> InspectedWindowsProcess? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = line.lastIndex(where: \.isWhitespace) else {
                    return nil
                }
                let processIDValue = line[line.index(after: separator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let processID = UInt32(processIDValue), processID > 0 else {
                    return nil
                }
                let rawPath = String(line[..<separator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let executablePath = WineProtocolAssociationFormat
                    .normalizedWindowsExecutablePath(rawPath),
                      !isProcessInspectionHelper(executablePath),
                      seenProcessIDs.insert(processID).inserted else {
                    return nil
                }
                return InspectedWindowsProcess(
                    executablePath: executablePath,
                    processID: processID
                )
            }
    }

    private static func processIdentities(
        from output: String
    ) -> [WindowsProcessInstanceIdentity] {
        var seenProcessIDs: Set<UInt32> = []
        return output
            .components(separatedBy: .newlines)
            .dropFirst()
            .compactMap { rawLine -> WindowsProcessInstanceIdentity? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let creationDateEnd = line.firstIndex(where: \.isWhitespace),
                      let processIDSeparator = line.lastIndex(where: \.isWhitespace),
                      creationDateEnd < processIDSeparator else {
                    return nil
                }

                let creationDate = String(line[..<creationDateEnd])
                let processIDValue = line[line.index(after: processIDSeparator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rawPath = String(line[creationDateEnd..<processIDSeparator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !creationDate.isEmpty,
                      let processID = UInt32(processIDValue),
                      processID > 0,
                      let executablePath = WineProtocolAssociationFormat
                        .normalizedWindowsExecutablePath(rawPath),
                      !isProcessInspectionHelper(executablePath),
                      seenProcessIDs.insert(processID).inserted else {
                    return nil
                }

                return WindowsProcessInstanceIdentity(
                    processID: processID,
                    startIdentity: Optional(creationDate),
                    executableIdentity: executablePath
                        .replacingOccurrences(of: "/", with: "\\")
                        .lowercased()
                )
            }
    }

    private static func processIdentity(
        processID: UInt32,
        winePath: String,
        prefixPath: String
    ) throws -> WindowsProcessInstanceIdentity? {
        do {
            let output = try processInspectionOutput(
                winePath: winePath,
                prefixPath: prefixPath,
                properties: ["CreationDate", "ExecutablePath", "ProcessId"]
            )
            let strongIdentities = processIdentities(from: output)
            if let identity = strongIdentities.first(where: {
                $0.processID == processID
            }) {
                return identity
            }
            guard strongIdentities.isEmpty else {
                return nil
            }
        } catch SwitchyardRunnerError.processInspectionFailed(_) {
            // The pinned Wine runtime currently does not expose CreationDate
            // on Win32_Process. Preserve executable identity checking there,
            // while using the stronger start identity on runtimes that do.
        }

        let fallbackOutput = try processInspectionOutput(
            winePath: winePath,
            prefixPath: prefixPath,
            properties: ["ExecutablePath", "ProcessId"]
        )
        guard let process = processDetails(from: fallbackOutput).first(where: {
            $0.processID == processID
        }) else {
            return nil
        }
        return WindowsProcessInstanceIdentity(
            processID: processID,
            startIdentity: nil,
            executableIdentity: process.executablePath
                .replacingOccurrences(of: "/", with: "\\")
                .lowercased()
        )
    }

    private static func isProcessInspectionHelper(_ executablePath: String) -> Bool {
        executablePath
            .replacingOccurrences(of: "/", with: "\\")
            .lowercased()
            .hasSuffix("\\wbem\\wmic.exe")
    }

    private static func terminateProcess(arguments: [String]) throws {
        guard arguments.count == 6,
              arguments[0] == "--wine",
              arguments[2] == "--prefix",
              arguments[4] == "--pid",
              let processID = UInt32(arguments[5]),
              processID > 0,
              FileManager.default.isExecutableFile(atPath: arguments[1]),
              FileManager.default.fileExists(atPath: arguments[3]) else {
            printUsage()
            runnerExit(2)
        }

        let prefixLock = try WinePrefixFileLock(prefixPath: arguments[3], mode: .shared)
        defer { prefixLock.unlock() }

        guard let selectedIdentity = try processIdentity(
            processID: processID,
            winePath: arguments[1],
            prefixPath: arguments[3]
        ) else {
            throw SwitchyardRunnerError.windowsProcessIdentityUnavailable(processID)
        }
        guard let currentIdentity = try processIdentity(
            processID: processID,
            winePath: arguments[1],
            prefixPath: arguments[3]
        ),
        selectedIdentity.identifiesSameProcess(as: currentIdentity) else {
            throw SwitchyardRunnerError.windowsProcessIdentityChanged(processID)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[1])
        process.arguments = ["taskkill", "/PID", String(processID), "/F"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "WINEPREFIX": arguments[3],
            "WINEDEBUG": "-all"
        ]) { _, new in new }
        process.currentDirectoryURL = URL(fileURLWithPath: arguments[3], isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)
        guard waitForExit(process, timeout: wineServerCommandTimeout) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.windowsProcessTerminationTimedOut(processID)
        }
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.windowsProcessTerminationFailed(
                processID: processID,
                status: process.terminationStatus
            )
        }
    }

    private static func listHostProcesses(arguments: [String]) throws {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix",
              FileManager.default.isExecutableFile(atPath: arguments[1]),
              FileManager.default.fileExists(atPath: arguments[3]) else {
            printUsage()
            runnerExit(2)
        }

        let processIDs = try wineProcessIdentities(
            wineExecutablePath: arguments[1],
            prefixPath: arguments[3]
        ).map(\.processID)
        FileHandle.standardOutput.write(try JSONEncoder().encode(processIDs))
    }

    private static func stopPrefix(arguments: [String]) throws {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix",
              FileManager.default.isExecutableFile(atPath: arguments[1]),
              FileManager.default.fileExists(atPath: arguments[3]) else {
            printUsage()
            runnerExit(2)
        }

        let environment = ProcessInfo.processInfo.environment.merging([
            "WINEPREFIX": arguments[3],
            "WINEDEBUG": "-all"
        ]) { _, new in new }
        try stopWinePrefixSession(
            wineExecutablePath: arguments[1],
            prefixPath: arguments[3],
            environment: environment
        )
    }

    private static func preparePrivateDesktop(plan: CommandPlan) throws {
        guard plan.environment[WineDesktopShortcutFormat.privateDesktopEnvironmentKey] == "1",
              let prefixPath = plan.environment["WINEPREFIX"],
              !prefixPath.isEmpty else {
            return
        }

        let fileManager = FileManager.default
        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let usersURL = prefixURL.appendingPathComponent("drive_c/users", isDirectory: true)
        let resolvedUsersURL = usersURL.resolvingSymlinksInPath()
        guard path(resolvedUsersURL.path, isWithin: prefixURL.path),
              let userURLs = try? fileManager.contentsOfDirectory(
                  at: usersURL,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ),
              let hostDesktopURL = fileManager.urls(
                  for: .desktopDirectory,
                  in: .userDomainMask
              ).first?.resolvingSymlinksInPath() else {
            return
        }

        for userURL in userURLs {
            let userValues = try userURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard userValues.isDirectory == true,
                  userValues.isSymbolicLink != true,
                  path(userURL.resolvingSymlinksInPath().path, isWithin: prefixURL.path) else {
                continue
            }

            let desktopURL = userURL.appendingPathComponent("Desktop", isDirectory: true)
            guard let desktopValues = try? desktopURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  desktopValues.isSymbolicLink == true,
                  desktopURL.resolvingSymlinksInPath() == hostDesktopURL else {
                continue
            }

            let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: desktopURL.path)
            try fileManager.removeItem(at: desktopURL)
            do {
                try fileManager.createDirectory(at: desktopURL, withIntermediateDirectories: false)
                guard Darwin.chmod(desktopURL.path, mode_t(S_IRWXU)) == 0 else {
                    throw POSIXError(.EACCES)
                }
            } catch {
                try? fileManager.removeItem(at: desktopURL)
                try? fileManager.createSymbolicLink(atPath: desktopURL.path, withDestinationPath: linkTarget)
                throw error
            }
        }
    }

    private static func startProtocolAssociationMonitor(plan: CommandPlan) throws -> Process? {
        let exportsProtocols = plan.environment[
            WineProtocolAssociationFormat.manifestEnvironmentKey
        ]?.isEmpty == false
        let exportsShortcuts = plan.environment[
            WineDesktopShortcutFormat.manifestEnvironmentKey
        ]?.isEmpty == false
        guard exportsProtocols || exportsShortcuts else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = ["winemenubuilder.exe", "-m"]
        process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
        if let workingDirectory = plan.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try RunnerProcessRegistry.shared.launch(process)
        return process
    }

    private static func stopProtocolAssociationMonitor(_ monitor: inout Process?) {
        guard let process = monitor else { return }
        stopProcessWithinDeadline(process)
        RunnerProcessRegistry.shared.clear(process)
        monitor = nil
    }

    private static func probePrefix(arguments: [String]) {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix" else {
            printUsage()
            runnerExit(2)
        }

        do {
            let prefixLock = try WinePrefixFileLock(
                prefixPath: arguments[3],
                mode: .shared
            )
            defer { prefixLock.unlock() }
            guard FileManager.default.isExecutableFile(atPath: arguments[1]),
                  FileManager.default.fileExists(atPath: arguments[3]),
                  let wineServerURL = wineServerURL(forWineExecutable: arguments[1]) else {
                runnerExit(2)
            }

            let result = try inspectWinePrefixSession(
                wineExecutablePath: arguments[1],
                wineServerURL: wineServerURL,
                prefixPath: arguments[3]
            ).result
            runnerExit(result.exitStatus)
        } catch {
            FileHandle.standardError.write(Data("Unable to inspect Wine prefix session: \(error)\n".utf8))
            runnerExit(2)
        }
    }

    private static func inspectSession(arguments: [String]) throws {
        let configuration = processInspectionConfiguration(arguments: arguments)
        let prefixLock = try WinePrefixFileLock(
            prefixPath: configuration.prefixPath,
            mode: .shared
        )
        defer { prefixLock.unlock() }
        validateProcessInspectionPaths(configuration)
        guard let wineServerURL = wineServerURL(
            forWineExecutable: configuration.winePath
        ) else {
            throw SwitchyardRunnerError.missingWineServer(configuration.winePath)
        }

        let inspection = try inspectWinePrefixSession(
            wineExecutablePath: configuration.winePath,
            wineServerURL: wineServerURL,
            prefixPath: configuration.prefixPath
        )
        let wireState: WinePrefixInspectionState = switch inspection.result {
        case .active:
            .active
        case .inactive:
            .inactive
        case .residualProcesses:
            .orphaned
        }
        let response = WinePrefixSessionInspection(
            state: wireState,
            hostProcessIDs: inspection.hostProcesses.map(\.processID)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(response))
    }

    private static func probePrefixHost(arguments: [String]) {
        guard arguments.count == 4,
              arguments[0] == "--wine",
              arguments[2] == "--prefix",
              FileManager.default.isExecutableFile(atPath: arguments[1]),
              FileManager.default.fileExists(atPath: arguments[3]) else {
            printUsage()
            runnerExit(2)
        }

        do {
            let result: WinePrefixProbeResult = try wineProcessIdentities(
                wineExecutablePath: arguments[1],
                prefixPath: arguments[3]
            ).isEmpty ? .inactive : .residualProcesses
            runnerExit(result.exitStatus)
        } catch {
            FileHandle.standardError.write(
                Data("Unable to inspect Wine host processes: \(error.localizedDescription)\n".utf8)
            )
            runnerExit(2)
        }
    }

    private static func openURL(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--request" else {
            throw SwitchyardRunnerError.invalidURLCallbackRequest
        }

        let requestURL = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: requestURL)
        try? FileManager.default.removeItem(at: requestURL)
        let request = try JSONDecoder().decode(WineURLCallbackRequest.self, from: data)
        guard let scheme = WineProtocolAssociationFormat.scheme(inRawURL: request.rawURL),
              scheme == request.scheme else {
            throw SwitchyardRunnerError.invalidURLCallbackRequest
        }

        let prefixLock = try WinePrefixFileLock(
            prefixPath: request.prefixPath,
            mode: .shared,
            acquisitionTimeout: callbackPrefixLockTimeout,
            cancellationCheck: {
                RunnerProcessRegistry.shared.requestedExitStatus != nil
            }
        )
        defer { prefixLock.unlock() }
        guard FileManager.default.isExecutableFile(atPath: request.winePath),
              FileManager.default.fileExists(atPath: request.prefixPath) else {
            throw SwitchyardRunnerError.invalidURLCallbackRequest
        }

        let handlerExecutablePath: String?
        if let requestedHandlerExecutablePath = request.handlerExecutablePath {
            guard let normalizedHandlerExecutablePath = WineProtocolAssociationFormat
                .normalizedWindowsExecutablePath(requestedHandlerExecutablePath) else {
                throw SwitchyardRunnerError.invalidURLCallbackRequest
            }
            handlerExecutablePath = normalizedHandlerExecutablePath
        } else {
            handlerExecutablePath = nil
        }

        let environment = RunnerRosettaAVXPolicy.current.resolving(
            ProcessInfo.processInfo.environment.merging([
                "WINEPREFIX": request.prefixPath,
                WineProtocolAssociationFormat.manifestEnvironmentKey:
                    WineProtocolAssociationFormat.windowsManifestPath,
                WineDesktopShortcutFormat.manifestEnvironmentKey:
                    WineDesktopShortcutFormat.windowsManifestPath,
                WineDesktopShortcutFormat.privateDesktopEnvironmentKey: "1"
            ]) { _, new in new },
            preference: request.rosettaAVXAdvertisingPreference ?? .automatic
        )
        if let handlerExecutablePath {
            let registrationExists = try protocolRegistrationExists(
                scheme: scheme,
                winePath: request.winePath,
                prefixPath: request.prefixPath,
                environment: environment
            )
            if !registrationExists {
                guard windowsExecutableExists(handlerExecutablePath, prefixPath: request.prefixPath) else {
                    throw SwitchyardRunnerError.invalidURLCallbackRequest
                }
                try runURLCallbackWineCommand(
                    winePath: request.winePath,
                    prefixPath: request.prefixPath,
                    environment: environment,
                    arguments: [handlerExecutablePath, request.rawURL]
                )
                do {
                    try registerLearnedProtocol(
                        scheme: scheme,
                        handlerExecutablePath: handlerExecutablePath,
                        winePath: request.winePath,
                        prefixPath: request.prefixPath,
                        environment: environment
                    )
                } catch {
                    removeLearnedProtocol(
                        scheme: scheme,
                        winePath: request.winePath,
                        prefixPath: request.prefixPath,
                        environment: environment
                    )
                    throw error
                }
                synchronizeUserProtocolRegistration(
                    scheme: scheme,
                    winePath: request.winePath,
                    prefixPath: request.prefixPath,
                    environment: environment
                )
                return
            }
        }
        synchronizeUserProtocolRegistration(
            scheme: scheme,
            winePath: request.winePath,
            prefixPath: request.prefixPath,
            environment: environment
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.winePath)
        process.arguments = ["start", request.rawURL]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: request.prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)

        guard waitForExit(process, timeout: 15) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.urlCallbackTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.urlCallbackCommandFailed(process.terminationStatus)
        }
    }

    private static func openDesktopShortcut(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--request" else {
            throw SwitchyardRunnerError.invalidDesktopShortcutRequest
        }

        let requestURL = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: requestURL)
        try? FileManager.default.removeItem(at: requestURL)
        let request = try JSONDecoder().decode(WineDesktopShortcutRequest.self, from: data)
        guard request.shortcutID.count == 64,
              request.shortcutID.allSatisfy(\.isHexDigit),
              let shortcutPath = WineDesktopShortcutFormat.normalizedShortcutPath(
                  request.windowsShortcutPath
              ) else {
            throw SwitchyardRunnerError.invalidDesktopShortcutRequest
        }

        let prefixLock = try WinePrefixFileLock(
            prefixPath: request.prefixPath,
            mode: .shared,
            acquisitionTimeout: callbackPrefixLockTimeout,
            cancellationCheck: {
                RunnerProcessRegistry.shared.requestedExitStatus != nil
            }
        )
        defer { prefixLock.unlock() }
        guard FileManager.default.isExecutableFile(atPath: request.winePath),
              FileManager.default.fileExists(atPath: request.prefixPath),
              let shortcutURL = WineDesktopShortcutFormat.hostShortcutURL(
                  windowsPath: shortcutPath,
                  prefixPath: request.prefixPath
              ),
              let values = try? shortcutURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw SwitchyardRunnerError.invalidDesktopShortcutRequest
        }

        let environment = RunnerRosettaAVXPolicy.current.resolving(
            ProcessInfo.processInfo.environment.merging([
                "WINEPREFIX": request.prefixPath,
                WineProtocolAssociationFormat.manifestEnvironmentKey:
                    WineProtocolAssociationFormat.windowsManifestPath,
                WineDesktopShortcutFormat.manifestEnvironmentKey:
                    WineDesktopShortcutFormat.windowsManifestPath,
                WineDesktopShortcutFormat.privateDesktopEnvironmentKey: "1"
            ]) { _, new in new },
            preference: request.rosettaAVXAdvertisingPreference ?? .automatic
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.winePath)
        process.arguments = ["start", shortcutPath]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: request.prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)

        guard waitForExit(process, timeout: 15) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.desktopShortcutTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.desktopShortcutCommandFailed(process.terminationStatus)
        }
    }

    private static func registerLearnedProtocol(
        scheme: String,
        handlerExecutablePath: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) throws {
        let key = "HKCU\\Software\\Classes\\\(scheme)"
        let handlerCommand = "\"\(handlerExecutablePath)\" \"%1\""
        let commands = [
            ["reg", "add", key, "/ve", "/d", "URL:\(scheme) protocol", "/f"],
            ["reg", "add", key, "/v", "URL Protocol", "/d", "", "/f"],
            ["reg", "add", "\(key)\\shell\\open\\command", "/ve", "/d", handlerCommand, "/f"]
        ]

        for arguments in commands {
            try runURLCallbackWineCommand(
                winePath: winePath,
                prefixPath: prefixPath,
                environment: environment,
                arguments: arguments
            )
        }
    }

    private static func protocolRegistrationExists(
        scheme: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = ["reg", "query", "HKCR\\\(scheme)\\shell\\open\\command", "/ve"]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)

        guard waitForExit(process, timeout: wineServerCommandTimeout) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.urlCallbackTimedOut
        }
        switch process.terminationStatus {
        case 0:
            return true
        case 1:
            return false
        default:
            throw SwitchyardRunnerError.urlCallbackCommandFailed(process.terminationStatus)
        }
    }

    private static func removeLearnedProtocol(
        scheme: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) {
        for key in ["HKCU\\Software\\Classes\\\(scheme)", "HKCR\\\(scheme)"] {
            try? runURLCallbackWineCommand(
                winePath: winePath,
                prefixPath: prefixPath,
                environment: environment,
                arguments: ["reg", "delete", key, "/f"]
            )
        }
    }

    private static func runURLCallbackWineCommand(
        winePath: String,
        prefixPath: String,
        environment: [String: String],
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }
        try RunnerProcessRegistry.shared.launch(process)

        guard waitForExit(process, timeout: wineServerCommandTimeout) else {
            stopProcessWithinDeadline(process)
            throw SwitchyardRunnerError.urlCallbackTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.urlCallbackCommandFailed(process.terminationStatus)
        }
    }

    private static func windowsExecutableExists(_ windowsPath: String, prefixPath: String) -> Bool {
        let relativeComponents = windowsPath.dropFirst(3).split(separator: "\\").map(String.init)
        guard !relativeComponents.isEmpty else { return false }

        let driveLetter = String(windowsPath.prefix(1)).lowercased()
        let prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true).standardizedFileURL
        let mappedDriveURL: URL
        if driveLetter == "c" {
            mappedDriveURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        } else {
            mappedDriveURL = prefixURL
                .appendingPathComponent("dosdevices", isDirectory: true)
                .appendingPathComponent("\(driveLetter):", isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: mappedDriveURL.path) else { return false }

        let driveRootURL = mappedDriveURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executableURL = relativeComponents.reduce(driveRootURL) { url, component in
            url.appendingPathComponent(component)
        }
        let resolvedExecutableURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let driveRootPath = driveRootURL.path
        let isInsideMappedDrive = driveRootPath == "/"
            ? resolvedExecutableURL.path.hasPrefix("/")
            : resolvedExecutableURL.path.hasPrefix(driveRootPath + "/")
        guard isInsideMappedDrive else { return false }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: resolvedExecutableURL.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
    }

    private static func synchronizeUserProtocolRegistration(
        scheme: String,
        winePath: String,
        prefixPath: String,
        environment: [String: String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: winePath)
        process.arguments = [
            "reg", "copy",
            "HKCU\\Software\\Classes\\\(scheme)",
            "HKCR\\\(scheme)",
            "/s", "/f"
        ]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { RunnerProcessRegistry.shared.clear(process) }

        do {
            try RunnerProcessRegistry.shared.launch(process)
        } catch {
            return
        }
        guard waitForExit(process, timeout: 15) else {
            stopProcessWithinDeadline(process)
            return
        }
    }

    private static func printUsage() {
        FileHandle.standardError.write(
            Data("usage: switchyard-runner diagnose | inspect-session --wine <path> --prefix <path> | probe-prefix --wine <path> --prefix <path> | probe-prefix-host --wine <path> --prefix <path> | list-processes --wine <path> --prefix <path> | list-process-details --wine <path> --prefix <path> | list-host-processes --wine <path> --prefix <path> | terminate-process --wine <path> --prefix <path> --pid <guest-pid> | stop-prefix --wine <path> --prefix <path> | open-url --request <request.json> | open-shortcut --request <request.json> | run --plan <command-plan.json>\n".utf8)
        )
    }
}

private func terminateExistingPrefixSession(plan: CommandPlan) throws {
    FileHandle.standardOutput.write(
        Data("[\(plan.logSource)] Stopping any existing Wine session for this prefix before relaunch.\n".utf8)
    )

    try stopPrefixSession(plan: plan)
}

private func stopPrefixSession(plan: CommandPlan) throws {
    let environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
    try stopWinePrefixSession(
        wineExecutablePath: plan.executable,
        prefixPath: plan.environment["WINEPREFIX"] ?? plan.workingDirectory ?? "",
        environment: environment
    )
}

private func configureContainerDisplay(
    _ displayMode: ContainerDisplayMode,
    plan: CommandPlan
) throws {
    let retinaValue = displayMode == .standard ? "N" : "Y"
    let dpiValue = displayMode == .retinaWithLargerInterface ? "192" : "96"
    let commands = [
        [
            "reg", "add", #"HKCU\Software\Wine\Mac Driver"#,
            "/v", "RetinaMode",
            "/t", "REG_SZ",
            "/d", retinaValue,
            "/f",
        ],
        [
            "reg", "add", #"HKCU\Control Panel\Desktop"#,
            "/v", "LogPixels",
            "/t", "REG_DWORD",
            "/d", dpiValue,
            "/f",
        ],
    ]

    do {
        for arguments in commands {
            try runWineRegistryCommand(plan: plan, arguments: arguments)
        }
    } catch {
        try? stopPrefixSession(plan: plan)
        throw error
    }

    // reg.exe starts a Wine session using the previous system DPI. End that
    // transient session so the target starts after the new values are committed.
    try stopPrefixSession(plan: plan)
}

private func runWineRegistryCommand(
    plan: CommandPlan,
    arguments: [String]
) throws {
    let process = Process()
    let output = Pipe()
    let outputCollector = ProcessOutputCollector()
    process.executableURL = URL(fileURLWithPath: plan.executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(plan.environment) { _, new in new }
    if let workingDirectory = plan.workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    }
    process.standardOutput = output
    process.standardError = output
    output.fileHandleForReading.readabilityHandler = { handle in
        outputCollector.consumeAvailableData(from: handle)
    }
    defer { RunnerProcessRegistry.shared.clear(process) }

    do {
        try RunnerProcessRegistry.shared.launch(process)
    } catch {
        outputCollector.cancel(from: output.fileHandleForReading)
        throw error
    }

    guard waitForExit(process, timeout: wineRegistryCommandTimeout) else {
        stopProcessWithinDeadline(process)
        outputCollector.finish(from: output.fileHandleForReading)
        throw SwitchyardRunnerError.wineRegistryCommandTimedOut(arguments: arguments)
    }

    outputCollector.finish(from: output.fileHandleForReading)
    guard process.terminationStatus == 0 else {
        throw SwitchyardRunnerError.wineRegistryCommandFailed(
            arguments: arguments,
            status: process.terminationStatus,
            output: outputCollector.text
        )
    }
}

private func stopWinePrefixSession(
    wineExecutablePath: String,
    prefixPath: String,
    environment: [String: String]
) throws {
    guard let wineServerURL = wineServerURL(forWineExecutable: wineExecutablePath) else {
        throw SwitchyardRunnerError.missingWineServer(wineExecutablePath)
    }

    // Do not issue any termination command unless the process table can be
    // enumerated completely. An empty list from a failed read is not evidence
    // that the selected prefix is inactive.
    _ = try wineProcessIdentities(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )

    try runWineServer(
        at: wineServerURL,
        arguments: ["-k"],
        environment: environment,
        acceptedExitStatuses: [0, 1]
    )
    try runWineServer(at: wineServerURL, arguments: ["-w"], environment: environment)
    try stopResidualWineProcesses(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
}

private func wineServerURL(forWineExecutable path: String) -> URL? {
    let wineURL = URL(fileURLWithPath: path)
    let candidates = [
        wineURL.deletingLastPathComponent().appendingPathComponent("wineserver"),
        wineURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("wineserver")
    ]

    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private enum WinePrefixProbeResult {
    case active
    case inactive
    case residualProcesses

    var exitStatus: Int32 {
        switch self {
        case .active: 0
        case .inactive: 1
        case .residualProcesses: 3
        }
    }
}

private struct WinePrefixSessionProbe {
    let result: WinePrefixProbeResult
    let hostProcesses: [HostWineProcessIdentity]
}

private func inspectWinePrefixSession(
    wineExecutablePath: String,
    wineServerURL: URL,
    prefixPath: String
) throws -> WinePrefixSessionProbe {
    // `wineserver -w` can start a fresh server for an inactive prefix.
    // Check the host process table first so every read-only probe, including
    // extended output draining, leaves an inactive session untouched.
    let initialProcesses = try wineProcessIdentities(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    guard !initialProcesses.isEmpty else {
        return WinePrefixSessionProbe(result: .inactive, hostProcesses: [])
    }

    let process = Process()
    process.executableURL = wineServerURL
    process.arguments = ["-w"]
    process.environment = ProcessInfo.processInfo.environment.merging(["WINEPREFIX": prefixPath]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    defer { RunnerProcessRegistry.shared.clear(process) }
    try RunnerProcessRegistry.shared.launch(process)

    if waitForExit(process, timeout: 0.25) {
        guard process.terminationStatus == 0 else {
            throw SwitchyardRunnerError.wineServerCommandFailed(
                arguments: ["-w"],
                status: process.terminationStatus,
                output: ""
            )
        }
        let residualProcesses = try wineProcessIdentities(
            wineExecutablePath: wineExecutablePath,
            prefixPath: prefixPath
        )
        return WinePrefixSessionProbe(
            result: residualProcesses.isEmpty ? .inactive : .residualProcesses,
            hostProcesses: residualProcesses
        )
    }

    stopProcessWithinDeadline(process)
    let activeProcesses = try wineProcessIdentities(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    guard !activeProcesses.isEmpty else {
        return WinePrefixSessionProbe(result: .inactive, hostProcesses: [])
    }
    return WinePrefixSessionProbe(
        result: .active,
        hostProcesses: activeProcesses
    )
}

private func probeWinePrefixSession(
    wineExecutablePath: String,
    wineServerURL: URL,
    prefixPath: String
) throws -> WinePrefixProbeResult {
    try inspectWinePrefixSession(
        wineExecutablePath: wineExecutablePath,
        wineServerURL: wineServerURL,
        prefixPath: prefixPath
    ).result
}

private let knownWineProcessExecutableNames: Set<String> = [
    "switchyard-wine",
    "wine",
    "wine-preloader",
    "wine64",
    "wine64-preloader",
    "wineserver"
]

private struct HostProcessStartIdentity: Hashable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64
}

private typealias HostWineProcessIdentity =
    ProcessInstanceIdentity<pid_t, HostProcessStartIdentity>

private enum ProcessEnvironmentLookup {
    case value(String)
    case unavailable
}

private struct WineProcessSelectionContext {
    let prefixURL: URL
    let expectedExecutablePaths: Set<String>

    init?(wineExecutablePath: String, prefixPath: String) {
        guard !prefixPath.isEmpty else { return nil }
        prefixURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        expectedExecutablePaths = Set(
            [
                URL(fileURLWithPath: wineExecutablePath).standardizedFileURL.path,
                URL(fileURLWithPath: wineExecutablePath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path,
            ]
        )
    }
}

private func wineProcessIdentities(
    wineExecutablePath: String,
    prefixPath: String
) throws -> [HostWineProcessIdentity] {
    guard let context = WineProcessSelectionContext(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    ) else {
        return []
    }
    let currentProcessID = ProcessInfo.processInfo.processIdentifier
    let processIDs: [pid_t]
    switch allProcessIDs() {
    case let .complete(completeProcessIDs):
        processIDs = completeProcessIDs
    case .incomplete:
        throw SwitchyardRunnerError.processTableReadIncomplete
    case .failed:
        throw SwitchyardRunnerError.processTableReadFailed
    }

    return processIDs.compactMap { processID -> HostWineProcessIdentity? in
        guard processID > 0,
              processID != currentProcessID else {
            return nil
        }
        return wineProcessIdentity(processID, context: context)
    }
    .sorted { $0.processID < $1.processID }
}

private func allProcessIDs() -> ProcessTableSnapshot<pid_t> {
    switch ProcessInfo.processInfo.environment["SWITCHYARD_TEST_PROCESS_TABLE_STATUS"] {
    case "failed":
        return .failed
    case "incomplete":
        return .incomplete([])
    default:
        break
    }

    let estimatedCount = proc_listallpids(nil, 0)
    guard estimatedCount > 0 else { return .failed }

    var capacity = Int(estimatedCount) + 32
    var latestProcessIDs: [pid_t] = []
    for _ in 0..<4 {
        guard capacity <= Int(Int32.max) / MemoryLayout<pid_t>.stride else {
            return .incomplete(latestProcessIDs)
        }
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let listedCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard listedCount > 0 else { return .failed }
        latestProcessIDs = Array(processIDs.prefix(Int(listedCount)))
        if listedCount < capacity {
            return .complete(latestProcessIDs)
        }
        capacity *= 2
    }
    return .incomplete(latestProcessIDs)
}

private func hostProcessIdentity(_ processID: pid_t) -> HostWineProcessIdentity? {
    guard let initialStartIdentity = processStartIdentity(processID),
          let executablePath = processExecutablePath(processID),
          let currentStartIdentity = processStartIdentity(processID),
          initialStartIdentity == currentStartIdentity else {
        return nil
    }

    return HostWineProcessIdentity(
        processID: processID,
        startIdentity: initialStartIdentity,
        executableIdentity: URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .path
    )
}

private func processStartIdentity(_ processID: pid_t) -> HostProcessStartIdentity? {
    var processInfo = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(
        processID,
        PROC_PIDTBSDINFO,
        0,
        &processInfo,
        expectedSize
    ) == expectedSize else {
        return nil
    }
    return HostProcessStartIdentity(
        seconds: processInfo.pbi_start_tvsec,
        microseconds: processInfo.pbi_start_tvusec
    )
}

private func processExecutablePath(_ processID: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = buffer.withUnsafeMutableBytes { bytes in
        proc_pidpath(processID, bytes.baseAddress, UInt32(bytes.count))
    }
    guard length > 0 else { return nil }
    let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: pathBytes, as: UTF8.self)
}

private func processWorkingDirectoryPath(_ processID: pid_t) -> String? {
    var pathInfo = proc_vnodepathinfo()
    let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(
        processID,
        PROC_PIDVNODEPATHINFO,
        0,
        &pathInfo,
        expectedSize
    ) == expectedSize else {
        return nil
    }

    return withUnsafePointer(to: &pathInfo.pvi_cdir.vip_path) { pathPointer in
        pathPointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
            String(cString: $0)
        }
    }
}

private func processEnvironmentValue(
    _ processID: pid_t,
    key: String
) -> ProcessEnvironmentLookup {
    var managementInformationBase: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
    var byteCount = 0
    guard sysctl(
        &managementInformationBase,
        UInt32(managementInformationBase.count),
        nil,
        &byteCount,
        nil,
        0
    ) == 0,
    byteCount > MemoryLayout<Int32>.size else {
        return .unavailable
    }

    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard bytes.withUnsafeMutableBytes({ buffer in
        sysctl(
            &managementInformationBase,
            UInt32(managementInformationBase.count),
            buffer.baseAddress,
            &byteCount,
            nil,
            0
        )
    }) == 0 else {
        return .unavailable
    }

    let argumentCount = bytes.withUnsafeBytes {
        $0.loadUnaligned(as: Int32.self)
    }
    var offset = MemoryLayout<Int32>.size

    func skipString() {
        while offset < byteCount && bytes[offset] != 0 {
            offset += 1
        }
        if offset < byteCount {
            offset += 1
        }
    }

    skipString()
    while offset < byteCount && bytes[offset] == 0 {
        offset += 1
    }
    for _ in 0..<max(0, Int(argumentCount)) {
        skipString()
    }

    let environmentKeyPrefix = key + "="
    while offset < byteCount {
        while offset < byteCount && bytes[offset] == 0 {
            offset += 1
        }
        let entryStart = offset
        while offset < byteCount && bytes[offset] != 0 {
            offset += 1
        }
        guard entryStart < offset else { continue }

        let entry = String(decoding: bytes[entryStart..<offset], as: UTF8.self)
        if entry.hasPrefix(environmentKeyPrefix) {
            return .value(String(entry.dropFirst(environmentKeyPrefix.count)))
        }
    }
    return .unavailable
}

private func path(_ candidatePath: String, isWithin directoryPath: String) -> Bool {
    candidatePath == directoryPath || candidatePath.hasPrefix(directoryPath + "/")
}

private func stopResidualWineProcesses(
    wineExecutablePath: String,
    prefixPath: String
) throws {
    var remainingProcesses = try wineProcessIdentities(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    guard !remainingProcesses.isEmpty else { return }

    signalWineProcesses(
        remainingProcesses,
        signal: SIGTERM,
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    _ = waitForWineProcessesToExit(
        remainingProcesses,
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath,
        timeout: prefixProcessTerminationTimeout
    )
    remainingProcesses = try wineProcessIdentities(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    guard !remainingProcesses.isEmpty else { return }

    signalWineProcesses(
        remainingProcesses,
        signal: SIGKILL,
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    _ = waitForWineProcessesToExit(
        remainingProcesses,
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath,
        timeout: 1
    )
    remainingProcesses = try wineProcessIdentities(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    )
    guard remainingProcesses.isEmpty else {
        throw SwitchyardRunnerError.wineProcessesCouldNotBeStopped(
            remainingProcesses.map(\.processID)
        )
    }
}

private func signalWineProcesses(
    _ processes: [HostWineProcessIdentity],
    signal: Int32,
    wineExecutablePath: String,
    prefixPath: String
) {
    guard let context = WineProcessSelectionContext(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    ) else {
        return
    }
    for process in processes {
        ProcessIdentitySignalGate.signal(
            selected: process,
            signal: signal,
            currentIdentity: {
                currentWineProcessIdentity(
                    process,
                    context: context
                )
            },
            send: Darwin.kill
        )
    }
}

private func waitForWineProcessesToExit(
    _ selectedProcesses: [HostWineProcessIdentity],
    wineExecutablePath: String,
    prefixPath: String,
    timeout: TimeInterval
) -> [HostWineProcessIdentity] {
    guard let context = WineProcessSelectionContext(
        wineExecutablePath: wineExecutablePath,
        prefixPath: prefixPath
    ) else {
        return selectedProcesses
    }
    let deadline = Date().addingTimeInterval(timeout)
    var remainingProcesses = selectedProcesses.filter {
        currentWineProcessIdentity(
            $0,
            context: context
        ) != nil
    }
    while !remainingProcesses.isEmpty && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        remainingProcesses = selectedProcesses.filter {
            currentWineProcessIdentity(
                $0,
                context: context
            ) != nil
        }
    }
    return remainingProcesses
}

private func currentWineProcessIdentity(
    _ selected: HostWineProcessIdentity,
    context: WineProcessSelectionContext
) -> HostWineProcessIdentity? {
    guard let current = wineProcessIdentity(
        selected.processID,
        context: context
    ),
    selected.identifiesSameProcess(as: current) else {
        return nil
    }
    return current
}

private func wineProcessIdentity(
    _ processID: pid_t,
    context: WineProcessSelectionContext
) -> HostWineProcessIdentity? {
    guard let identity = hostProcessIdentity(processID),
          let executablePath = identity.executableIdentity else {
        return nil
    }

    let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
    let resolvedExecutablePath = executableURL.resolvingSymlinksInPath().path
    let executableName = executableURL.lastPathComponent.lowercased()
    guard context.expectedExecutablePaths.contains(executableURL.path)
            || context.expectedExecutablePaths.contains(resolvedExecutablePath)
            || knownWineProcessExecutableNames.contains(executableName) else {
        return nil
    }

    let isAssociatedWithPrefix: Bool
    switch processEnvironmentValue(processID, key: "WINEPREFIX") {
    case let .value(environmentPrefixPath) where !environmentPrefixPath.isEmpty:
        isAssociatedWithPrefix = URL(
            fileURLWithPath: environmentPrefixPath,
            isDirectory: true
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path == context.prefixURL.path
    case .value, .unavailable:
        guard let workingDirectoryPath = processWorkingDirectoryPath(processID) else {
            return nil
        }
        isAssociatedWithPrefix = path(
            URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path,
            isWithin: context.prefixURL.path
        )
    }

    guard isAssociatedWithPrefix,
          let currentIdentity = hostProcessIdentity(processID),
          identity.identifiesSameProcess(as: currentIdentity) else {
        return nil
    }
    return identity
}

private func runWineServer(
    at url: URL,
    arguments: [String],
    environment: [String: String],
    acceptedExitStatuses: Set<Int32> = [0]
) throws {
    let process = Process()
    let output = Pipe()
    let outputCollector = ProcessOutputCollector()
    process.executableURL = url
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = output
    process.standardError = output
    output.fileHandleForReading.readabilityHandler = { handle in
        outputCollector.consumeAvailableData(from: handle)
    }
    defer { RunnerProcessRegistry.shared.clear(process) }
    do {
        try RunnerProcessRegistry.shared.launch(process)
    } catch {
        outputCollector.cancel(from: output.fileHandleForReading)
        throw error
    }

    guard waitForExit(process, timeout: wineServerCommandTimeout) else {
        stopProcessWithinDeadline(process)
        outputCollector.finish(from: output.fileHandleForReading)
        throw SwitchyardRunnerError.wineServerCommandTimedOut(arguments: arguments)
    }

    outputCollector.finish(from: output.fileHandleForReading)
    guard acceptedExitStatuses.contains(process.terminationStatus) else {
        throw SwitchyardRunnerError.wineServerCommandFailed(
            arguments: arguments,
            status: process.terminationStatus,
            output: outputCollector.text
        )
    }
}

private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    return !process.isRunning
}

private func stopProcessWithinDeadline(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    if waitForExit(process, timeout: 0.5) {
        return
    }

    Darwin.kill(process.processIdentifier, SIGKILL)
    _ = waitForExit(process, timeout: 0.5)
}

private func waitForOutputDrain(
    _ group: DispatchGroup,
    plan: CommandPlan,
    debugLogWriter: DebugLogWriter?,
    liveLogWriter: LiveLogJournalWriter?
) -> Bool {
    guard RunnerProcessRegistry.shared.requestedExitStatus == nil else {
        return false
    }
    guard group.wait(timeout: .now() + outputDrainTimeout) == .timedOut else {
        return true
    }
    guard RunnerProcessRegistry.shared.requestedExitStatus == nil else {
        return false
    }
    guard plan.keepLoggingWhilePrefixIsActive != false,
          liveLogWriter != nil,
          let prefixPath = plan.environment["WINEPREFIX"],
          !prefixPath.isEmpty,
          let wineServerURL = wineServerURL(forWineExecutable: plan.executable) else {
        return false
    }

    var didAnnounceExtendedDrain = false
    while true {
        guard RunnerProcessRegistry.shared.requestedExitStatus == nil else {
            return false
        }
        let prefixState: WinePrefixProbeResult
        do {
            prefixState = try probeWinePrefixSession(
                wineExecutablePath: plan.executable,
                wineServerURL: wineServerURL,
                prefixPath: prefixPath
            )
        } catch {
            return false
        }
        guard case .active = prefixState else {
            return false
        }

        if !didAnnounceExtendedDrain {
            emit(
                source: plan.logSource,
                level: "info",
                message: "launched process exited; continuing live log capture while wineserver remains active",
                debugLogWriter: debugLogWriter,
                liveLogWriter: liveLogWriter
            )
            didAnnounceExtendedDrain = true
        }
        if group.wait(timeout: .now() + outputDrainTimeout) == .success {
            return true
        }
        guard RunnerProcessRegistry.shared.requestedExitStatus == nil else {
            return false
        }
    }
}

private func emitLine(
    source: String,
    level: String,
    message: String,
    outputHandle: FileHandle?,
    debugLogWriter: DebugLogWriter?,
    liveLogWriter: LiveLogJournalWriter?
) {
    emit(
        source: source,
        level: level,
        message: message,
        debugLogWriter: debugLogWriter,
        liveLogWriter: liveLogWriter
    )
    if let outputHandle {
        let text = "[\(source)] \(message)"
        try? outputHandle.write(contentsOf: Data((text + "\n").utf8))
    }
}

private func emit(
    source: String,
    level: String,
    message: String,
    debugLogWriter: DebugLogWriter?,
    liveLogWriter: LiveLogJournalWriter?
) {
    debugLogWriter?.write(source: source, level: level, message: message)
    liveLogWriter?.write(level: level, message: message)
}

private func openDebugLogWriter(path: String?, source: String) -> DebugLogWriter? {
    guard let path else { return nil }
    do {
        let writer = try DebugLogWriter(path: path)
        writer.write(source: source, level: "info", message: "created protected debug log")
        return writer
    } catch {
        FileHandle.standardError.write(Data("[\(source)] Unable to open switchyard debug log file: \(error)\n".utf8))
        return nil
    }
}

private func openLiveLogWriter(path: String?, source: String) -> LiveLogJournalWriter? {
    guard let path else { return nil }
    do {
        let writer = try LiveLogJournalWriter(path: path, source: source)
        writer.write(level: "info", message: "opened protected live log journal")
        return writer
    } catch {
        try? FileHandle.standardError.write(
            contentsOf: Data("[\(source)] Unable to open live log journal: \(error)\n".utf8)
        )
        return nil
    }
}

private func streamOutput(
    from inputHandle: FileHandle,
    source: String,
    level: String,
    to outputHandle: FileHandle?,
    accumulator: LineAccumulator,
    debugLogWriter: DebugLogWriter?,
    liveLogWriter: LiveLogJournalWriter?,
    group: DispatchGroup
) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        defer {
            if let tail = accumulator.flush(), !tail.isEmpty {
                emitLine(
                    source: source,
                    level: ProcessLogLevelPolicy.normalizedLevel(
                        for: tail,
                        fallbackLevel: level
                    ),
                    message: tail,
                    outputHandle: outputHandle,
                    debugLogWriter: debugLogWriter,
                    liveLogWriter: liveLogWriter
                )
            }
            group.leave()
        }

        while true {
            // This task lives for the launched process, so drain Foundation's
            // temporary Data objects after every output chunk.
            let reachedEnd = autoreleasepool {
                let data = inputHandle.availableData
                guard !data.isEmpty else { return true }
                for line in accumulator.consume(data) where !line.isEmpty {
                    emitLine(
                        source: source,
                        level: ProcessLogLevelPolicy.normalizedLevel(
                            for: line,
                            fallbackLevel: level
                        ),
                        message: line,
                        outputHandle: outputHandle,
                        debugLogWriter: debugLogWriter,
                        liveLogWriter: liveLogWriter
                    )
                }
                return false
            }
            if reachedEnd { break }
        }
    }
}
