import Foundation
import Testing
import AppCore
import Darwin
@testable import Switchyard

@Suite("Runner Command Executor")
struct RunnerCommandExecutorTests {
    @Test("captures stdout and stderr without truncation")
    func capturesOutput() async throws {
        let executor = RunnerCommandExecutor()

        let result = try await executor.execute(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf output; printf error >&2"],
            deadline: .seconds(2)
        )

        #expect(result.terminationStatus == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "output")
        #expect(String(decoding: result.standardError, as: UTF8.self) == "error")
        #expect(!result.didTruncateStandardOutput)
        #expect(!result.didTruncateStandardError)
        #expect(executor.activeExecutionCount == 0)
    }

    @Test("bounds both output streams")
    func boundsOutput() async throws {
        let executor = RunnerCommandExecutor(outputByteLimit: 32)

        let result = try await executor.execute(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf 1234567890123456789012345678901234567890; "
                    + "printf abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN >&2",
            ],
            deadline: .seconds(2)
        )

        #expect(result.standardOutput.count == 32)
        #expect(result.standardError.count == 32)
        #expect(result.didTruncateStandardOutput)
        #expect(result.didTruncateStandardError)
        #expect(executor.activeExecutionCount == 0)
    }

    @Test("deadline hard-kills a helper that ignores SIGTERM")
    func deadlineKillsUncooperativeHelper() async throws {
        let executor = RunnerCommandExecutor(
            terminationGrace: .milliseconds(50)
        )
        let readinessURL = fixtureReadinessURL()
        var processID: pid_t?
        defer {
            terminateFixtureIfNeeded(processID)
            try? FileManager.default.removeItem(at: readinessURL)
        }
        let task = Task {
            try await executor.execute(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-e",
                    "$SIG{TERM} = 'IGNORE';"
                        + "open(my $fh, '>', $ARGV[0]) or die;"
                        + "print $fh $$;"
                        + "close($fh);"
                        + "sleep(30);",
                    readinessURL.path,
                    "switchyard-runner-executor-deadline-fixture",
                ],
                deadline: .seconds(1)
            )
        }
        processID = try await waitForFixtureProcess(at: readinessURL)

        do {
            _ = try await task.value
            Issue.record("Expected the helper to time out")
        } catch let error as RunnerCommandExecutorError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(executor.activeExecutionCount == 0)
        #expect(processID.map { !isProcessRunning($0) } == true)
    }

    @Test("task cancellation terminates and waits for the helper")
    func cancellationStopsHelper() async throws {
        let executor = RunnerCommandExecutor(
            terminationGrace: .milliseconds(100)
        )
        let readinessURL = fixtureReadinessURL()
        var processID: pid_t?
        defer {
            terminateFixtureIfNeeded(processID)
            try? FileManager.default.removeItem(at: readinessURL)
        }
        let task = Task {
            try await executor.execute(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-e",
                    "open(my $fh, '>', $ARGV[0]) or die;"
                        + "print $fh $$;"
                        + "close($fh);"
                        + "sleep(30);",
                    readinessURL.path,
                    "switchyard-runner-executor-cancellation-fixture",
                ],
                deadline: .seconds(10)
            )
        }

        processID = try await waitForFixtureProcess(at: readinessURL)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(executor.activeExecutionCount == 0)
        #expect(processID.map { !isProcessRunning($0) } == true)
    }

    @Test("pre-cancelled tasks do not retain an execution")
    func preCancelledTaskDoesNotLeak() async {
        let executor = RunnerCommandExecutor()
        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await executor.execute(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                deadline: .seconds(2)
            )
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(executor.activeExecutionCount == 0)
    }

    @Test("direct child exit bounds inherited pipe drain time")
    func directChildExitBoundsPipeDrain() async throws {
        let executor = RunnerCommandExecutor(
            outputDrainGrace: .milliseconds(50)
        )
        let readinessURL = fixtureReadinessURL()
        var descendantProcessID: pid_t?
        defer {
            terminateFixtureIfNeeded(descendantProcessID)
            try? FileManager.default.removeItem(at: readinessURL)
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let result = try await executor.execute(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-e",
                "my $pid = fork();"
                    + "die unless defined($pid);"
                    + "if ($pid == 0) {"
                    + "open(my $fh, '>', $ARGV[0]) or die;"
                    + "print $fh $$;"
                    + "close($fh);"
                    + "select(undef, undef, undef, 0.25);"
                    + "exit(0);"
                    + "}"
                    + "print 'done';",
                readinessURL.path,
                "switchyard-runner-executor-pipe-descendant-fixture",
            ],
            deadline: .seconds(2)
        )
        descendantProcessID = try await waitForFixtureProcess(at: readinessURL)

        #expect(result.terminationStatus == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "done")
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
        try await waitForFixtureExit(descendantProcessID!)
        #expect(!isProcessRunning(descendantProcessID!))
        #expect(executor.activeExecutionCount == 0)
    }
}

@Suite("Async Runner Client Queries")
struct AsyncRunnerClientQueryTests {
    @Test("session inspection uses the combined JSON command")
    func sessionInspectionUsesCombinedCommand() async throws {
        let inspection = WinePrefixSessionInspection(
            state: .active,
            hostProcessIDs: [9, 3]
        )
        let executor = RecordingRunnerCommandExecutor(results: [
            RunnerCommandResult(
                terminationStatus: 0,
                standardOutput: try JSONEncoder().encode(inspection),
                standardError: Data(),
                didTruncateStandardOutput: false,
                didTruncateStandardError: false
            ),
        ])
        let client = SwitchyardRunnerClient(commandExecutor: executor)

        let result = try await client.inspectSession(
            winePath: "/runtime/bin/wine",
            prefixPath: "/prefix"
        )

        #expect(result == inspection)
        #expect(executor.invocations.count == 1)
        #expect(executor.invocations.first?.arguments == [
            "inspect-session",
            "--wine", "/runtime/bin/wine",
            "--prefix", "/prefix",
        ])
        #expect(executor.invocations.first?.deadline == .seconds(5))
    }

    @Test("process detail failures do not trigger a legacy retry")
    func detailFailureDoesNotRetry() async {
        let executor = RecordingRunnerCommandExecutor(results: [
            RunnerCommandResult(
                terminationStatus: 1,
                standardOutput: Data(),
                standardError: Data(),
                didTruncateStandardOutput: false,
                didTruncateStandardError: false
            ),
        ])
        let client = SwitchyardRunnerClient(commandExecutor: executor)

        do {
            _ = try await client.runningWindowsProcessesAsync(
                winePath: "/runtime/bin/wine",
                prefixPath: "/prefix"
            )
            Issue.record("Expected process inspection to fail")
        } catch SwitchyardRunnerClientError.couldNotListWindowsProcesses(let status) {
            #expect(status == 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(executor.invocations.count == 1)
        #expect(executor.invocations.first?.arguments.first == "list-process-details")
    }

    @Test("unsupported detail command falls back once")
    func unsupportedDetailCommandFallsBack() async throws {
        let executor = RecordingRunnerCommandExecutor(results: [
            RunnerCommandResult(
                terminationStatus: 2,
                standardOutput: Data(),
                standardError: Data(),
                didTruncateStandardOutput: false,
                didTruncateStandardError: false
            ),
            RunnerCommandResult(
                terminationStatus: 0,
                standardOutput: try JSONEncoder().encode([
                    #"C:\Games\Example.exe"#,
                ]),
                standardError: Data(),
                didTruncateStandardOutput: false,
                didTruncateStandardError: false
            ),
        ])
        let client = SwitchyardRunnerClient(commandExecutor: executor)

        let processes = try await client.runningWindowsProcessesAsync(
            winePath: "/runtime/bin/wine",
            prefixPath: "/prefix"
        )

        #expect(processes == [
            RunningWindowsProcess(
                executablePath: #"C:\Games\Example.exe"#,
                processID: nil
            ),
        ])
        #expect(executor.invocations.map { $0.arguments.first } == [
            "list-process-details",
            "list-processes",
        ])
    }
}

private struct RecordedRunnerCommandInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let deadline: Duration
}

private final class RecordingRunnerCommandExecutor:
    RunnerCommandExecuting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var queuedResults: [RunnerCommandResult]
    private var recordedInvocations: [RecordedRunnerCommandInvocation] = []

    init(results: [RunnerCommandResult]) {
        queuedResults = results
    }

    var invocations: [RecordedRunnerCommandInvocation] {
        lock.withLock { recordedInvocations }
    }

    func execute(
        executableURL: URL,
        arguments: [String],
        deadline: Duration
    ) async throws -> RunnerCommandResult {
        try lock.withLock {
            recordedInvocations.append(
                RecordedRunnerCommandInvocation(
                    executableURL: executableURL,
                    arguments: arguments,
                    deadline: deadline
                )
            )
            guard !queuedResults.isEmpty else {
                throw RecordingRunnerCommandExecutorError.missingResult
            }
            return queuedResults.removeFirst()
        }
    }

    func cancelAll() {}
}

private enum RecordingRunnerCommandExecutorError: Error {
    case missingResult
}

private enum RunnerCommandFixtureError: Error {
    case didNotBecomeReady
    case didNotExit
}

private func fixtureReadinessURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("switchyard-runner-executor-\(UUID().uuidString).pid")
}

private func waitForFixtureProcess(at url: URL) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if let data = try? Data(contentsOf: url),
           let rawValue = String(data: data, encoding: .utf8),
           let processID = pid_t(rawValue),
           processID > 0 {
            return processID
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RunnerCommandFixtureError.didNotBecomeReady
}

private func waitForFixtureExit(_ processID: pid_t) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if !isProcessRunning(processID) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RunnerCommandFixtureError.didNotExit
}

private func isProcessRunning(_ processID: pid_t) -> Bool {
    Darwin.kill(processID, 0) == 0 || errno == EPERM
}

private func terminateFixtureIfNeeded(_ processID: pid_t?) {
    guard let processID, isProcessRunning(processID) else { return }
    Darwin.kill(processID, SIGKILL)
}
