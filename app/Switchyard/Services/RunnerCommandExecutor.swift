import Darwin
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

    private let process = Process()
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
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
    private var didRequestTermination = false
    private var activeOutputCallbackCount = 0
    private var isForcingOutputClosure = false
    private var didCloseOutputHandles = false
    private var didFinish = false
    private var deadlineTask: Task<Void, Never>?
    private var hardKillTask: Task<Void, Never>?
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
        self.deadline = deadline
        self.terminationGrace = terminationGrace
        self.outputDrainGrace = outputDrainGrace
        self.outputByteLimit = outputByteLimit
        self.onFinish = onFinish
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
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
        process.terminationHandler = { [weak self] process in
            self?.processDidExit(status: process.terminationStatus)
        }
        deadlineTask = Task { [weak self, deadline] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            self?.requestStop(.timedOut)
        }

        do {
            try process.run()
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()
        } catch {
            finishImmediately(throwing: error)
            return
        }

        let shouldStop = lock.withLock {
            didStart = true
            return stopReason != nil
        }
        if shouldStop {
            beginTerminationIfNeeded()
        }
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
        if needsBoundedDrain {
            scheduleBoundedOutputDrain()
        } else {
            finishIfReady()
        }
    }

    private func requestStop(_ reason: StopReason) {
        let shouldContinue = lock.withLock {
            guard !didFinish else { return false }
            if stopReason == nil {
                stopReason = reason
            }
            return true
        }
        guard shouldContinue else { return }

        forceOutputClosure()
        beginTerminationIfNeeded()
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
        let shouldClose = lock.withLock {
            guard !didCloseOutputHandles else { return false }
            didCloseOutputHandles = true
            standardOutput.didReachEOF = true
            standardError.didReachEOF = true
            return true
        }
        guard shouldClose else { return }

        try? standardOutputPipe.fileHandleForReading.close()
        try? standardErrorPipe.fileHandleForReading.close()
        finishIfReady()
    }

    private func beginTerminationIfNeeded() {
        let shouldTerminate = lock.withLock {
            guard didStart, !didFinish, !didRequestTermination else {
                return false
            }
            didRequestTermination = true
            return true
        }
        guard shouldTerminate else { return }

        if process.isRunning {
            process.terminate()
        }
        let process = process
        let task = Task { [terminationGrace] in
            do {
                try await Task.sleep(for: terminationGrace)
            } catch {
                return
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        let shouldRetainTask = lock.withLock {
            guard !didFinish else { return false }
            hardKillTask = task
            return true
        }
        if !shouldRetainTask {
            task.cancel()
        }
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
        hardKillTask?.cancel()
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
                  let continuation,
                  let terminationStatus,
                  standardOutput.didReachEOF,
                  standardError.didReachEOF else {
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
        hardKillTask?.cancel()
        outputDrainTask?.cancel()
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        onFinish(ObjectIdentifier(self))
        completion.0.resume(with: completion.1)
    }
}
