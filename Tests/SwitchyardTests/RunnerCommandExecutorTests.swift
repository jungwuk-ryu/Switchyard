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
        var fixtureProcessIDs: [pid_t] = []
        defer {
            terminateFixturesIfNeeded(fixtureProcessIDs)
            try? FileManager.default.removeItem(at: readinessURL)
        }
        let task = Task {
            try await executor.execute(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-e",
                    """
                    use POSIX qw(pause);
                    $SIG{TERM} = 'IGNORE';
                    pipe(my $readyReader, my $readyWriter) or die;
                    my $child = fork();
                    die unless defined($child);
                    if ($child == 0) {
                        close($readyReader);
                        print $readyWriter "ready";
                        close($readyWriter);
                        pause() while 1;
                    }
                    close($readyWriter);
                    <$readyReader>;
                    close($readyReader);
                    open(my $fh, '>', $ARGV[0]) or die;
                    print $fh "$$ $child";
                    close($fh);
                    waitpid($child, 0);
                    """,
                    readinessURL.path,
                    "switchyard-runner-executor-deadline-fixture",
                ],
                deadline: .seconds(1)
            )
        }
        fixtureProcessIDs = try await waitForFixtureProcesses(
            at: readinessURL,
            expectedCount: 2
        )

        do {
            _ = try await task.value
            Issue.record("Expected the helper to time out")
        } catch let error as RunnerCommandExecutorError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        try await waitForFixtureExit(fixtureProcessIDs)
        #expect(executor.activeExecutionCount == 0)
        #expect(fixtureProcessIDs.allSatisfy { !isProcessRunning($0) })
        fixtureProcessIDs.removeAll()
    }

    @Test("task cancellation terminates and waits for the helper")
    func cancellationStopsHelper() async throws {
        let executor = RunnerCommandExecutor(
            terminationGrace: .milliseconds(100)
        )
        let readinessURL = fixtureReadinessURL()
        var fixtureProcessIDs: [pid_t] = []
        defer {
            terminateFixturesIfNeeded(fixtureProcessIDs)
            try? FileManager.default.removeItem(at: readinessURL)
        }
        let task = Task {
            try await executor.execute(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-e",
                    """
                    use POSIX qw(pause);
                    my $child;
                    $SIG{TERM} = sub {
                        kill('TERM', $child) if $child;
                    };
                    pipe(my $readyReader, my $readyWriter) or die;
                    $child = fork();
                    die unless defined($child);
                    if ($child == 0) {
                        close($readyReader);
                        $SIG{TERM} = sub { exit(0); };
                        print $readyWriter "ready";
                        close($readyWriter);
                        pause() while 1;
                    }
                    close($readyWriter);
                    <$readyReader>;
                    close($readyReader);
                    open(my $fh, '>', $ARGV[0]) or die;
                    print $fh "$$ $child";
                    close($fh);
                    waitpid($child, 0);
                    """,
                    readinessURL.path,
                    "switchyard-runner-executor-cancellation-fixture",
                ],
                deadline: .seconds(10)
            )
        }

        fixtureProcessIDs = try await waitForFixtureProcesses(
            at: readinessURL,
            expectedCount: 2
        )
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        try await waitForFixtureExit(fixtureProcessIDs)
        #expect(executor.activeExecutionCount == 0)
        #expect(fixtureProcessIDs.allSatisfy { !isProcessRunning($0) })
        fixtureProcessIDs.removeAll()
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

    @Test("immediate direct child exit cleans inherited pipe descendants")
    func immediateDirectChildExitCleansInheritedPipeDescendant() async throws {
        let executor = RunnerCommandExecutor(
            terminationGrace: .milliseconds(100),
            outputDrainGrace: .seconds(3)
        )
        let readinessURL = fixtureReadinessURL()
        var fixtureProcessIDs: [pid_t] = []
        let unrelatedProcess = Process()
        unrelatedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        unrelatedProcess.arguments = [
            "-MPOSIX=pause",
            "-e",
            "pause() while 1",
            "switchyard-runner-executor-unrelated-fixture",
        ]
        try unrelatedProcess.run()
        let unrelatedProcessID = unrelatedProcess.processIdentifier
        defer {
            terminateFixturesIfNeeded(fixtureProcessIDs)
            terminateProcessIfNeeded(unrelatedProcess)
            try? FileManager.default.removeItem(at: readinessURL)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let task = Task {
            try await executor.execute(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-e",
                    """
                    use POSIX qw(pause);
                    $SIG{TERM} = 'IGNORE';
                    my $child = fork();
                    die unless defined($child);
                    if ($child == 0) {
                        pause() while 1;
                    }
                    open(my $fh, '>', $ARGV[0]) or die;
                    print $fh "$$ $child";
                    close($fh);
                    print "done";
                    exit(0);
                    """,
                    readinessURL.path,
                    "switchyard-runner-executor-pipe-descendant-fixture",
                ],
                deadline: .seconds(2)
            )
        }
        fixtureProcessIDs = try await waitForFixtureProcesses(
            at: readinessURL,
            expectedCount: 2
        )
        let result = try await task.value

        #expect(result.terminationStatus == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "done")
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
        try await waitForFixtureExit(fixtureProcessIDs)
        #expect(fixtureProcessIDs.allSatisfy { !isProcessRunning($0) })
        fixtureProcessIDs.removeAll()
        #expect(unrelatedProcess.isRunning)
        #expect(executor.activeExecutionCount == 0)
        terminateProcessIfNeeded(unrelatedProcess)
        #expect(!isProcessRunning(unrelatedProcessID))
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

private func waitForFixtureProcesses(
    at url: URL,
    expectedCount: Int
) async throws -> [pid_t] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if let data = try? Data(contentsOf: url),
           let rawValue = String(data: data, encoding: .utf8) {
            let processIDs = rawValue
                .split(whereSeparator: \.isWhitespace)
                .compactMap { pid_t($0) }
                .filter { $0 > 0 }
            if processIDs.count == expectedCount {
                return processIDs
            }
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RunnerCommandFixtureError.didNotBecomeReady
}

private func waitForFixtureExit(_ processIDs: [pid_t]) async throws {
    for processID in processIDs {
        try await waitForFixtureExit(processID)
    }
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
    errno = 0
    return Darwin.kill(processID, 0) == 0 || errno == EPERM
}

private func terminateFixturesIfNeeded(_ processIDs: [pid_t]) {
    for processID in processIDs where isProcessRunning(processID) {
        Darwin.kill(processID, SIGTERM)
    }
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline,
          processIDs.contains(where: { isProcessRunning($0) }) {
        Thread.sleep(forTimeInterval: 0.01)
    }
    for processID in processIDs where isProcessRunning(processID) {
        Darwin.kill(processID, SIGKILL)
    }
    let killDeadline = Date().addingTimeInterval(1)
    while Date() < killDeadline,
          processIDs.contains(where: { isProcessRunning($0) }) {
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func terminateProcessIfNeeded(_ process: Process) {
    if process.isRunning {
        process.terminate()
    }
    let deadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
    let killDeadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < killDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
}
