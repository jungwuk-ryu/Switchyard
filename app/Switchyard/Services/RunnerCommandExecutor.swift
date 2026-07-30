import Darwin
import Dispatch
import Foundation

struct RunnerCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data
    let didTruncateStandardOutput: Bool
    let didTruncateStandardError: Bool
}

enum RunnerCommandExecutorError: Error, Equatable {
    case timedOut
}

protocol RunnerCommandExecuting: Sendable {
    func execute(
        executableURL: URL,
        arguments: [String],
        deadline: Duration
    ) async throws -> RunnerCommandResult

    func cancelAll()
}

final class RunnerCommandExecutor: RunnerCommandExecuting, @unchecked Sendable {
    private let outputByteLimit: Int
    private let terminationGrace: Duration
    private let outputDrainGrace: Duration
    private let lock = NSLock()
    private var executions: [ObjectIdentifier: RunnerCommandExecution] = [:]

    init(
        outputByteLimit: Int = 4 * 1_024 * 1_024,
        terminationGrace: Duration = .seconds(3),
        outputDrainGrace: Duration = .milliseconds(100)
    ) {
        self.outputByteLimit = max(1, outputByteLimit)
        self.terminationGrace = terminationGrace
        self.outputDrainGrace = outputDrainGrace
    }

    var activeExecutionCount: Int {
        lock.withLock { executions.count }
    }

    func execute(
        executableURL: URL,
        arguments: [String],
        deadline: Duration
    ) async throws -> RunnerCommandResult {
        let execution = RunnerCommandExecution(
            executableURL: executableURL,
            arguments: arguments,
            deadline: deadline,
            terminationGrace: terminationGrace,
            outputDrainGrace: outputDrainGrace,
            outputByteLimit: outputByteLimit
        ) { [weak self] identifier in
            self?.removeExecution(identifier)
        }
        let identifier = ObjectIdentifier(execution)
        lock.withLock {
            executions[identifier] = execution
        }
        do {
            return try await execution.run()
        } catch {
            removeExecution(identifier)
            throw error
        }
    }

    func cancelAll() {
        let activeExecutions = lock.withLock { Array(executions.values) }
        for execution in activeExecutions {
            execution.cancel()
        }
    }

    private func removeExecution(_ identifier: ObjectIdentifier) {
        _ = lock.withLock {
            executions.removeValue(forKey: identifier)
        }
    }
}

private final class RunnerCommandExecution: @unchecked Sendable {
    private enum StopReason {
        case cancelled
        case timedOut
    }

    private struct OutputState {
        var data = Data()
        var isTruncated = false
        var didReachEOF = false
    }

    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let executableURL: URL
    private let arguments: [String]
    private let deadline: Duration
    private let terminationGrace: Duration
    private let outputDrainGrace: Duration
    private let outputByteLimit: Int
    private let onFinish: @Sendable (ObjectIdentifier) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<RunnerCommandResult, any Error>?
    private var standardOutput = OutputState()
    private var standardError = OutputState()
    private var terminationStatus: Int32?
    private var stopReason: StopReason?
    private var didStart = false
    private var didBeginProcessTreeTermination = false
    private var didCompleteProcessTreeTermination = true
    private var processGroupID: pid_t?
    private var activeOutputCallbackCount = 0
    private var isForcingOutputClosure = false
    private var didCloseOutputHandles = false
    private var didFinish = false
    private var deadlineTask: Task<Void, Never>?
    private var processTreeTerminationTask: Task<Void, Never>?
    private var outputDrainTask: Task<Void, Never>?

    init(
        executableURL: URL,
        arguments: [String],
        deadline: Duration,
        terminationGrace: Duration,
        outputDrainGrace: Duration,
        outputByteLimit: Int,
        onFinish: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.deadline = deadline
        self.terminationGrace = terminationGrace
        self.outputDrainGrace = outputDrainGrace
        self.outputByteLimit = outputByteLimit
        self.onFinish = onFinish
    }

    func run() async throws -> RunnerCommandResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        requestStop(.cancelled)
    }

    private func start(
        _ continuation: CheckedContinuation<RunnerCommandResult, any Error>
    ) {
        let shouldAbortBeforeLaunch = lock.withLock {
            self.continuation = continuation
            return stopReason != nil
        }
        guard !shouldAbortBeforeLaunch else {
            finishWithoutLaunching()
            return
        }

        configureOutputHandlers()
        deadlineTask = Task { [weak self, deadline] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            self?.requestStop(.timedOut)
        }

        do {
            let processID = try Self.spawnProcess(
                executableURL: executableURL,
                arguments: arguments,
                standardOutputFileDescriptor:
                    standardOutputPipe.fileHandleForWriting.fileDescriptor,
                standardErrorFileDescriptor:
                    standardErrorPipe.fileHandleForWriting.fileDescriptor,
                standardOutputReadFileDescriptor:
                    standardOutputPipe.fileHandleForReading.fileDescriptor,
                standardErrorReadFileDescriptor:
                    standardErrorPipe.fileHandleForReading.fileDescriptor
            )
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            let shouldStop = lock.withLock {
                didStart = true
                processGroupID = processID
                return stopReason != nil
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                waitForDirectProcess(processID)
            }
            if shouldStop {
                beginTerminationIfNeeded()
            }
        } catch {
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
            finishImmediately(throwing: error)
        }
    }

    private func waitForDirectProcess(_ processID: pid_t) {
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            errno = 0
            waitResult = Darwin.waitpid(processID, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR

        let terminationStatus = if waitResult == processID {
            Self.terminationStatus(fromWaitStatus: waitStatus)
        } else {
            Int32(-1)
        }
        processDidExit(status: terminationStatus)
    }

    private func configureOutputHandlers() {
        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle, isStandardError: false)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle, isStandardError: true)
        }
    }

    private func consumeAvailableData(
        from handle: FileHandle,
        isStandardError: Bool
    ) {
        let shouldRead = lock.withLock {
            guard !isForcingOutputClosure, !didFinish else { return false }
            activeOutputCallbackCount += 1
            return true
        }
        guard shouldRead else { return }
        defer { outputCallbackDidFinish() }

        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            try? handle.close()
            markOutputEOF(isStandardError: isStandardError)
            return
        }

        lock.withLock {
            if isStandardError {
                append(data, to: &standardError)
            } else {
                append(data, to: &standardOutput)
            }
        }
    }

    private func append(_ data: Data, to output: inout OutputState) {
        let remainingByteCount = max(0, outputByteLimit - output.data.count)
        if remainingByteCount > 0 {
            output.data.append(data.prefix(remainingByteCount))
        }
        if data.count > remainingByteCount {
            output.isTruncated = true
        }
    }

    private func markOutputEOF(isStandardError: Bool) {
        lock.withLock {
            if isStandardError {
                standardError.didReachEOF = true
            } else {
                standardOutput.didReachEOF = true
            }
        }
        finishIfReady()
    }

    private func processDidExit(status: Int32) {
        let needsBoundedDrain = lock.withLock {
            terminationStatus = status
            return !standardOutput.didReachEOF || !standardError.didReachEOF
        }
        deadlineTask?.cancel()
        beginTerminationIfNeeded()
        if needsBoundedDrain {
            scheduleBoundedOutputDrain()
        } else {
            finishIfReady()
        }
    }

    private func requestStop(_ reason: StopReason) {
        let shouldContinue = lock.withLock {
            guard !didFinish, terminationStatus == nil else { return false }
            if stopReason == nil {
                stopReason = reason
            }
            return true
        }
        guard shouldContinue else { return }

        beginTerminationIfNeeded()
        forceOutputClosure()
        finishIfReady()
    }

    private func scheduleBoundedOutputDrain() {
        let task = Task { [weak self, outputDrainGrace] in
            do {
                try await Task.sleep(for: outputDrainGrace)
            } catch {
                return
            }
            self?.forceOutputClosure()
        }
        let shouldRetainTask = lock.withLock {
            guard !didFinish,
                  outputDrainTask == nil,
                  !standardOutput.didReachEOF || !standardError.didReachEOF else {
                return false
            }
            outputDrainTask = task
            return true
        }
        if !shouldRetainTask {
            task.cancel()
        }
    }

    private func forceOutputClosure() {
        let shouldCloseNow = lock.withLock {
            guard !didCloseOutputHandles else { return false }
            isForcingOutputClosure = true
            return activeOutputCallbackCount == 0
        }
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        if shouldCloseNow {
            closeOutputHandles()
        }
    }

    private func outputCallbackDidFinish() {
        let shouldClose = lock.withLock {
            activeOutputCallbackCount -= 1
            return isForcingOutputClosure
                && activeOutputCallbackCount == 0
                && !didCloseOutputHandles
        }
        if shouldClose {
            closeOutputHandles()
        }
    }

    private func closeOutputHandles() {
        let shouldDrainAndClose = lock.withLock {
            guard !didCloseOutputHandles else { return false }
            didCloseOutputHandles = true
            return true
        }
        guard shouldDrainAndClose else { return }

        drainAvailableData(
            from: standardOutputPipe.fileHandleForReading,
            isStandardError: false
        )
        drainAvailableData(
            from: standardErrorPipe.fileHandleForReading,
            isStandardError: true
        )
        try? standardOutputPipe.fileHandleForReading.close()
        try? standardErrorPipe.fileHandleForReading.close()
        lock.withLock {
            standardOutput.didReachEOF = true
            standardError.didReachEOF = true
        }
        finishIfReady()
    }

    private func drainAvailableData(
        from handle: FileHandle,
        isStandardError: Bool
    ) {
        let fileDescriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let byteCount = buffer.withUnsafeMutableBytes {
            Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
        }
        guard byteCount > 0 else { return }

        let data = Data(buffer.prefix(byteCount))
        lock.withLock {
            if isStandardError {
                append(data, to: &standardError)
            } else {
                append(data, to: &standardOutput)
            }
        }
    }

    private func beginTerminationIfNeeded() {
        let terminationState: (
            processGroupID: pid_t,
            gracefulTerminationDuration: Duration
        )? = lock.withLock {
            guard didStart,
                  !didFinish,
                  !didBeginProcessTreeTermination,
                  let processGroupID else {
                return nil
            }
            didBeginProcessTreeTermination = true
            didCompleteProcessTreeTermination = false
            let directChildExitedNormally = terminationStatus != nil
                && stopReason == nil
            let gracefulTerminationDuration = if directChildExitedNormally {
                min(terminationGrace, outputDrainGrace)
            } else {
                terminationGrace
            }
            return (processGroupID, gracefulTerminationDuration)
        }
        guard let terminationState else { return }

        Self.signal(
            SIGTERM,
            toIsolatedProcessGroup: terminationState.processGroupID
        )

        let task = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let gracefulTerminationDeadline = clock.now.advanced(
                by: terminationState.gracefulTerminationDuration
            )
            while Self.isProcessGroupAlive(terminationState.processGroupID),
                  clock.now < gracefulTerminationDeadline,
                  !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return
                }
            }

            Self.signal(
                SIGKILL,
                toIsolatedProcessGroup: terminationState.processGroupID
            )

            let killConfirmationDeadline = clock.now.advanced(
                by: .milliseconds(500)
            )
            while Self.isProcessGroupAlive(terminationState.processGroupID),
                  clock.now < killConfirmationDeadline,
                  !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return
                }
            }
            self.processTreeTerminationDidFinish()
        }
        let shouldRetainTask = lock.withLock {
            guard !didFinish else { return false }
            processTreeTerminationTask = task
            return true
        }
        if !shouldRetainTask {
            task.cancel()
        }
    }

    private static func isProcessGroupAlive(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 0 else { return false }
        errno = 0
        return Darwin.killpg(processGroupID, 0) == 0 || errno == EPERM
    }

    private static func signal(
        _ signal: Int32,
        toIsolatedProcessGroup processGroupID: pid_t
    ) {
        guard processGroupID > 0 else { return }
        _ = Darwin.killpg(processGroupID, signal)
    }

    private static func spawnProcess(
        executableURL: URL,
        arguments: [String],
        standardOutputFileDescriptor: Int32,
        standardErrorFileDescriptor: Int32,
        standardOutputReadFileDescriptor: Int32,
        standardErrorReadFileDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try checkPOSIXResult(
            posix_spawn_file_actions_init(&fileActions),
            operation: "initialize spawn file actions"
        )
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        try checkPOSIXResult(
            posix_spawn_file_actions_addinherit_np(
                &fileActions,
                STDIN_FILENO
            ),
            operation: "inherit standard input"
        )
        try checkPOSIXResult(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutputFileDescriptor,
                STDOUT_FILENO
            ),
            operation: "redirect standard output"
        )
        try checkPOSIXResult(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardErrorFileDescriptor,
                STDERR_FILENO
            ),
            operation: "redirect standard error"
        )
        for fileDescriptor in [
            standardOutputReadFileDescriptor,
            standardErrorReadFileDescriptor,
            standardOutputFileDescriptor,
            standardErrorFileDescriptor,
        ] {
            try checkPOSIXResult(
                posix_spawn_file_actions_addclose(
                    &fileActions,
                    fileDescriptor
                ),
                operation: "close inherited pipe descriptor"
            )
        }

        var attributes: posix_spawnattr_t?
        try checkPOSIXResult(
            posix_spawnattr_init(&attributes),
            operation: "initialize spawn attributes"
        )
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        try checkPOSIXResult(
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask),
            operation: "set child signal mask"
        )
        try checkPOSIXResult(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "create isolated process group"
        )
        let flags = POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        try checkPOSIXResult(
            posix_spawnattr_setflags(&attributes, Int16(flags)),
            operation: "set spawn flags"
        )

        let executablePath = executableURL.path
        let argumentStorage = try NullTerminatedCStringArray(
            [executablePath] + arguments
        )
        let environmentStorage = try NullTerminatedCStringArray(
            ProcessInfo.processInfo.environment.map { key, value in
                "\(key)=\(value)"
            }
        )
        var processID: pid_t = 0
        let spawnResult = executablePath.withCString { executablePathPointer in
            argumentStorage.withUnsafeMutablePointer { argumentPointer in
                environmentStorage.withUnsafeMutablePointer { environmentPointer in
                    posix_spawn(
                        &processID,
                        executablePathPointer,
                        &fileActions,
                        &attributes,
                        argumentPointer,
                        environmentPointer
                    )
                }
            }
        }
        try checkPOSIXResult(spawnResult, operation: "launch process")
        return processID
    }

    private static func terminationStatus(
        fromWaitStatus waitStatus: Int32
    ) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return signal
    }

    private static func checkPOSIXResult(
        _ result: Int32,
        operation: String
    ) throws {
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(result),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not \(operation): \(String(cString: strerror(result)))",
                ]
            )
        }
    }

    private func processTreeTerminationDidFinish() {
        lock.withLock {
            didCompleteProcessTreeTermination = true
        }
        finishIfReady()
    }

    private func finishWithoutLaunching() {
        let error: any Error = lock.withLock {
            switch stopReason {
            case .cancelled:
                CancellationError()
            case .timedOut:
                RunnerCommandExecutorError.timedOut
            case nil:
                CancellationError()
            }
        }
        finishImmediately(throwing: error)
    }

    private func finishImmediately(throwing error: any Error) {
        let completion: CheckedContinuation<RunnerCommandResult, any Error>? = lock.withLock {
            guard !didFinish, let continuation else { return nil }
            didFinish = true
            self.continuation = nil
            return continuation
        }
        guard let completion else { return }

        deadlineTask?.cancel()
        processTreeTerminationTask?.cancel()
        outputDrainTask?.cancel()
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        onFinish(ObjectIdentifier(self))
        completion.resume(throwing: error)
    }

    private func finishIfReady() {
        let completion: (
            CheckedContinuation<RunnerCommandResult, any Error>,
            Result<RunnerCommandResult, any Error>
        )? = lock.withLock {
            guard !didFinish,
                  didStart,
                  let continuation,
                  standardOutput.didReachEOF,
                  standardError.didReachEOF,
                  (terminationStatus != nil || stopReason != nil),
                  (!didBeginProcessTreeTermination
                      || didCompleteProcessTreeTermination) else {
                return nil
            }

            didFinish = true
            self.continuation = nil
            let result: Result<RunnerCommandResult, any Error>
            switch stopReason {
            case .cancelled:
                result = .failure(CancellationError())
            case .timedOut:
                result = .failure(RunnerCommandExecutorError.timedOut)
            case nil:
                guard let terminationStatus else {
                    return nil
                }
                result = .success(
                    RunnerCommandResult(
                        terminationStatus: terminationStatus,
                        standardOutput: standardOutput.data,
                        standardError: standardError.data,
                        didTruncateStandardOutput: standardOutput.isTruncated,
                        didTruncateStandardError: standardError.isTruncated
                    )
                )
            }
            return (continuation, result)
        }
        guard let completion else { return }

        deadlineTask?.cancel()
        processTreeTerminationTask?.cancel()
        outputDrainTask?.cancel()
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        onFinish(ObjectIdentifier(self))
        completion.0.resume(with: completion.1)
    }
}

private final class NullTerminatedCStringArray {
    private var pointers: [UnsafeMutablePointer<CChar>?] = []

    init(_ strings: [String]) throws {
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard !string.utf8.contains(0) else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EINVAL),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Process arguments and environment cannot contain NUL bytes.",
                    ]
                )
            }
            guard let pointer = strdup(string) else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ENOMEM)
                )
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }

    func withUnsafeMutablePointer<Result>(
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> Result
    ) rethrows -> Result {
        try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
