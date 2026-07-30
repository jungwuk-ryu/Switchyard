import AppCore
import Foundation
import RuntimeCatalog
import Testing
@testable import Switchyard

@Suite("GPTK GPU Identity Snapshot Service")
struct GPTKGPUIdentitySnapshotServiceTests {
    @Test("non-GPTK launches skip all GPU identity work")
    func skipsNonGPTKLaunches() async throws {
        let context = MutableGPUIdentityContextProvider()
        let builder = SyntheticGPUIdentityEvidenceBuilder()
        let executor = RepeatingGPUIdentityExecutor(
            response: .result(successfulGPUIdentityResult())
        )
        let service = GPTKGPUIdentitySnapshotService(
            contextProvider: context,
            evidenceBuilder: builder,
            commandExecutor: executor
        )

        let snapshot = try await service.snapshotIfNeeded(
            forGPTKLaunch: false,
            runtime: testRuntime(),
            runtimeRootURL: testRuntimeRoot(),
            runtimeContentFingerprint: "runtime-content-a"
        )

        #expect(snapshot == nil)
        #expect(await context.requestCount == 0)
        #expect(await builder.buildCount == 0)
        #expect(await executor.executionCount == 0)
    }

    @Test("runtime root must match the root derived from the Wine path")
    func rejectsMismatchedRuntimeRootBeforeExecutingHelper() async throws {
        let context = MutableGPUIdentityContextProvider()
        let builder = SyntheticGPUIdentityEvidenceBuilder()
        let executor = RepeatingGPUIdentityExecutor(
            response: .result(successfulGPUIdentityResult())
        )
        let service = GPTKGPUIdentitySnapshotService(
            contextProvider: context,
            evidenceBuilder: builder,
            commandExecutor: executor
        )

        await #expect(
            throws:
                GPTKGPUIdentitySnapshotServiceError.runtimeRootMismatch
        ) {
            _ = try await service.snapshotIfNeeded(
                forGPTKLaunch: true,
                runtime: testRuntime(),
                runtimeRootURL: URL(
                    fileURLWithPath: "/private/runtime-b",
                    isDirectory: true
                ),
                runtimeContentFingerprint: "runtime-content-a"
            )
        }

        #expect(await context.requestCount == 0)
        #expect(await builder.buildCount == 0)
        #expect(await executor.executionCount == 0)
    }

    @Test(
        "same-key concurrent requests execute the exact helper once",
        .timeLimit(.minutes(1))
    )
    func coalescesSameKeyRequests() async throws {
        let context = MutableGPUIdentityContextProvider()
        let builder = SyntheticGPUIdentityEvidenceBuilder()
        let executor = ControlledGPUIdentityExecutor()
        let counters = PerformanceCounters()
        let service = GPTKGPUIdentitySnapshotService(
            contextProvider: context,
            evidenceBuilder: builder,
            commandExecutor: executor,
            helperDeadline: .seconds(30),
            counters: counters
        )

        let first = Task {
            try await service.snapshotIfNeeded(
                forGPTKLaunch: true,
                runtime: testRuntime(),
                runtimeRootURL: testRuntimeRoot(),
                runtimeContentFingerprint: "runtime-content-a"
            )
        }
        await waitForExecutionCount(1, executor: executor)
        let second = Task {
            try await service.snapshotIfNeeded(
                forGPTKLaunch: true,
                runtime: testRuntime(),
                runtimeRootURL: testRuntimeRoot(),
                runtimeContentFingerprint: "runtime-content-a"
            )
        }
        await waitForCounter(
            .gptkGPUIdentityRequests,
            toReach: 2,
            counters: counters
        )

        await executor.succeed()
        let firstSnapshot = try #require(try await first.value)
        let secondSnapshot = try #require(try await second.value)

        #expect(firstSnapshot == secondSnapshot)
        #expect(await executor.executionCount == 1)
        #expect(await builder.buildCount == 3)
        let invocation = try #require(await executor.invocations.first)
        #expect(
            invocation.executableURL.path
                == "/private/runtime-a/libexec/switchyard-host-gpu-info"
        )
        #expect(invocation.arguments.isEmpty)
        #expect(
            invocation.deadline
                == GPTKGPUIdentitySnapshotService.maximumHelperDeadline
        )
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 2)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 1)
    }

    @Test("every result dependency produces a cache miss")
    func isolatesCompleteCacheKey() async throws {
        let context = MutableGPUIdentityContextProvider()
        let builder = SyntheticGPUIdentityEvidenceBuilder()
        let executor = RepeatingGPUIdentityExecutor(
            response: .result(successfulGPUIdentityResult())
        )
        let counters = PerformanceCounters()
        let service = GPTKGPUIdentitySnapshotService(
            contextProvider: context,
            evidenceBuilder: builder,
            commandExecutor: executor,
            counters: counters
        )
        let baseRuntime = testRuntime()
        let baseRoot = testRuntimeRoot()

        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: baseRuntime,
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-a"
        )

        await context.set(
            operatingSystemBuild: "24G91",
            defaultGPURegistryID: 0x100
        )
        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: baseRuntime,
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-a"
        )

        await context.set(
            operatingSystemBuild: "24G90",
            defaultGPURegistryID: 0x101
        )
        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: baseRuntime,
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-a"
        )

        await context.set(
            operatingSystemBuild: "24G90",
            defaultGPURegistryID: 0x100
        )
        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: testRuntime(id: "runtime-b"),
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-a"
        )
        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: baseRuntime,
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-b"
        )

        await builder.set(helperRevision: 1)
        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: baseRuntime,
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-a"
        )

        await builder.set(policyRevision: 1)
        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: baseRuntime,
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-a"
        )

        await builder.set(helperRevision: 0, policyRevision: 0)
        _ = try await service.snapshotIfNeeded(
            forGPTKLaunch: true,
            runtime: baseRuntime,
            runtimeRootURL: baseRoot,
            runtimeContentFingerprint: "runtime-content-a"
        )

        #expect(await executor.executionCount == 7)
        let metrics = counters.snapshot()
        #expect(metrics[.gptkGPUIdentityRequests] == 8)
        #expect(metrics[.gptkGPUIdentityHelperExecutions] == 7)
        #expect(metrics[.gptkGPUIdentityCacheHits] == 1)
    }

    @Test("invalid helper results are retried instead of cached")
    func rejectsInvalidHelperResults() async throws {
        let canonical = successfulGPUIdentityResult().standardOutput
        let scenarios: [GPUIdentityFailureScenario] = [
            GPUIdentityFailureScenario(
                response: .result(
                    runnerResult(output: Data("invalid".utf8))
                ),
                expected: .invalidHelperOutput(.invalidLineTermination)
            ),
            GPUIdentityFailureScenario(
                response: .result(
                    runnerResult(output: canonical + canonical)
                ),
                expected: .invalidHelperOutput(.invalidLineCount)
            ),
            GPUIdentityFailureScenario(
                response: .result(
                    runnerResult(
                        output: Data(
                            repeating: 0x61,
                            count: HostGPUIdentity
                                .maximumCanonicalTSVBytes + 1
                        )
                    )
                ),
                expected: .helperOutputTooLarge
            ),
            GPUIdentityFailureScenario(
                response: .result(
                    runnerResult(
                        output: canonical,
                        error: Data("warning".utf8)
                    )
                ),
                expected: .helperStandardError
            ),
            GPUIdentityFailureScenario(
                response: .result(
                    runnerResult(
                        output: canonical,
                        didTruncateOutput: true
                    )
                ),
                expected: .helperOutputTruncated
            ),
            GPUIdentityFailureScenario(
                response: .result(
                    runnerResult(status: 7, output: canonical)
                ),
                expected: .helperExited(7)
            ),
            GPUIdentityFailureScenario(
                response: .timedOut,
                expected: .helperTimedOut
            ),
        ]

        for scenario in scenarios {
            let builder = SyntheticGPUIdentityEvidenceBuilder()
            let executor = RepeatingGPUIdentityExecutor(
                response: scenario.response
            )
            let service = GPTKGPUIdentitySnapshotService(
                contextProvider: MutableGPUIdentityContextProvider(),
                evidenceBuilder: builder,
                commandExecutor: executor
            )

            for _ in 0..<2 {
                await #expect(
                    throws: scenario.expected
                ) {
                    _ = try await service.snapshotIfNeeded(
                        forGPTKLaunch: true,
                        runtime: testRuntime(),
                        runtimeRootURL: testRuntimeRoot(),
                        runtimeContentFingerprint: "runtime-content-a"
                    )
                }
            }
            #expect(await executor.executionCount == 2)
        }
    }

    @Test("cancelled helper executions are retried instead of cached")
    func rejectsCancelledHelperResults() async throws {
        let executor = RepeatingGPUIdentityExecutor(response: .cancelled)
        let service = GPTKGPUIdentitySnapshotService(
            contextProvider: MutableGPUIdentityContextProvider(),
            evidenceBuilder: SyntheticGPUIdentityEvidenceBuilder(),
            commandExecutor: executor
        )

        for _ in 0..<2 {
            await #expect(throws: CancellationError.self) {
                _ = try await service.snapshotIfNeeded(
                    forGPTKLaunch: true,
                    runtime: testRuntime(),
                    runtimeRootURL: testRuntimeRoot(),
                    runtimeContentFingerprint: "runtime-content-a"
                )
            }
        }
        #expect(await executor.executionCount == 2)
    }

    @Test("post-execution evidence changes reject and retry the result")
    func rejectsPostExecutionEvidenceChange() async throws {
        let builder = SyntheticGPUIdentityEvidenceBuilder(
            alternateEvidenceEveryBuild: true
        )
        let executor = RepeatingGPUIdentityExecutor(
            response: .result(successfulGPUIdentityResult())
        )
        let service = GPTKGPUIdentitySnapshotService(
            contextProvider: MutableGPUIdentityContextProvider(),
            evidenceBuilder: builder,
            commandExecutor: executor
        )

        for _ in 0..<2 {
            await #expect(
                throws:
                    GPTKGPUIdentitySnapshotServiceError
                        .runtimeEvidenceChanged
            ) {
                _ = try await service.snapshotIfNeeded(
                    forGPTKLaunch: true,
                    runtime: testRuntime(),
                    runtimeRootURL: testRuntimeRoot(),
                    runtimeContentFingerprint: "runtime-content-a"
                )
            }
        }

        #expect(await executor.executionCount == 2)
        #expect(await builder.buildCount == 4)
    }

    @Test("missing trusted evidence is a typed error and skips the helper")
    func reportsUntrustedEvidence() async throws {
        let executor = RepeatingGPUIdentityExecutor(
            response: .result(successfulGPUIdentityResult())
        )
        let service = GPTKGPUIdentitySnapshotService(
            contextProvider: MutableGPUIdentityContextProvider(),
            evidenceBuilder: FailingGPUIdentityEvidenceBuilder(
                error: .unavailable(.helper)
            ),
            commandExecutor: executor
        )

        await #expect(
            throws:
                GPTKGPUIdentitySnapshotServiceError
                    .untrustedRuntimeEvidence(.unavailable(.helper))
        ) {
            _ = try await service.snapshotIfNeeded(
                forGPTKLaunch: true,
                runtime: testRuntime(),
                runtimeRootURL: testRuntimeRoot(),
                runtimeContentFingerprint: "runtime-content-a"
            )
        }
        #expect(await executor.executionCount == 0)
    }
}

private struct GPUIdentityFailureScenario {
    let response: RepeatingGPUIdentityExecutor.Response
    let expected: GPTKGPUIdentitySnapshotServiceError
}

private actor MutableGPUIdentityContextProvider:
    GPTKGPUIdentitySystemContextProviding
{
    private var context = GPTKGPUIdentitySystemContext(
        operatingSystemBuild: "24G90",
        defaultGPURegistryID: 0x100
    )
    private(set) var requestCount = 0

    func currentContext() -> GPTKGPUIdentitySystemContext {
        requestCount += 1
        return context
    }

    func set(
        operatingSystemBuild: String,
        defaultGPURegistryID: UInt64
    ) {
        context = GPTKGPUIdentitySystemContext(
            operatingSystemBuild: operatingSystemBuild,
            defaultGPURegistryID: defaultGPURegistryID
        )
    }
}

private actor SyntheticGPUIdentityEvidenceBuilder:
    RuntimeGPUIdentityEvidenceBuilding
{
    private var helperRevision = 0
    private var policyRevision = 0
    private let alternateEvidenceEveryBuild: Bool
    private(set) var buildCount = 0

    init(alternateEvidenceEveryBuild: Bool = false) {
        self.alternateEvidenceEveryBuild = alternateEvidenceEveryBuild
    }

    func set(
        helperRevision: Int? = nil,
        policyRevision: Int? = nil
    ) {
        if let helperRevision {
            self.helperRevision = helperRevision
        }
        if let policyRevision {
            self.policyRevision = policyRevision
        }
    }

    func build(
        runtimeID: String,
        runtimeRootURL: URL,
        runtimeContentFingerprint: String,
        helperURL: URL,
        policyURL: URL
    ) throws -> RuntimeGPUIdentityEvidence {
        buildCount += 1
        let alternatingRevision =
            alternateEvidenceEveryBuild && buildCount.isMultiple(of: 2)
                ? 1
                : 0
        return try syntheticGPUIdentityEvidence(
            runtimeID: runtimeID,
            runtimeRootURL: runtimeRootURL,
            runtimeContentFingerprint: runtimeContentFingerprint,
            helperURL: helperURL,
            policyURL: policyURL,
            helperRevision: helperRevision + alternatingRevision,
            policyRevision: policyRevision
        )
    }
}

private struct FailingGPUIdentityEvidenceBuilder:
    RuntimeGPUIdentityEvidenceBuilding
{
    let error: RuntimeGPUIdentityEvidenceBuilderError

    func build(
        runtimeID: String,
        runtimeRootURL: URL,
        runtimeContentFingerprint: String,
        helperURL: URL,
        policyURL: URL
    ) async throws -> RuntimeGPUIdentityEvidence {
        throw error
    }
}

private struct GPUIdentityExecutorInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let deadline: Duration
}

private actor RepeatingGPUIdentityExecutor: RunnerCommandExecuting {
    enum Response: Sendable {
        case result(RunnerCommandResult)
        case timedOut
        case cancelled
    }

    private let response: Response
    private(set) var invocations: [GPUIdentityExecutorInvocation] = []

    init(response: Response) {
        self.response = response
    }

    var executionCount: Int {
        invocations.count
    }

    func execute(
        executableURL: URL,
        arguments: [String],
        deadline: Duration
    ) throws -> RunnerCommandResult {
        invocations.append(
            GPUIdentityExecutorInvocation(
                executableURL: executableURL,
                arguments: arguments,
                deadline: deadline
            )
        )
        switch response {
        case let .result(result):
            return result
        case .timedOut:
            throw RunnerCommandExecutorError.timedOut
        case .cancelled:
            throw CancellationError()
        }
    }

    nonisolated func cancelAll() {}
}

private actor ControlledGPUIdentityExecutor: RunnerCommandExecuting {
    private(set) var invocations: [GPUIdentityExecutorInvocation] = []
    private var continuation:
        CheckedContinuation<RunnerCommandResult, any Error>?

    var executionCount: Int {
        invocations.count
    }

    func execute(
        executableURL: URL,
        arguments: [String],
        deadline: Duration
    ) async throws -> RunnerCommandResult {
        invocations.append(
            GPUIdentityExecutorInvocation(
                executableURL: executableURL,
                arguments: arguments,
                deadline: deadline
            )
        )
        return try await withCheckedThrowingContinuation {
            continuation = $0
        }
    }

    func succeed() {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: successfulGPUIdentityResult())
    }

    nonisolated func cancelAll() {}
}

private func testRuntime(id: String = "runtime-a") -> RuntimeBuild {
    RuntimeBuild(
        id: id,
        winePath: "/private/runtime-a/bin/wine",
        patchsetID: "switchyard",
        sourceRevision: "abc123"
    )
}

private func testRuntimeRoot() -> URL {
    URL(fileURLWithPath: "/private/runtime-a", isDirectory: true)
}

private func successfulGPUIdentityResult() -> RunnerCommandResult {
    runnerResult(
        output: Data(
            "0000106b\t00000001\t00000000\t00000000\tApple GPU\n".utf8
        )
    )
}

private func runnerResult(
    status: Int32 = 0,
    output: Data,
    error: Data = Data(),
    didTruncateOutput: Bool = false,
    didTruncateError: Bool = false
) -> RunnerCommandResult {
    RunnerCommandResult(
        terminationStatus: status,
        standardOutput: output,
        standardError: error,
        didTruncateStandardOutput: didTruncateOutput,
        didTruncateStandardError: didTruncateError
    )
}

private func syntheticGPUIdentityEvidence(
    runtimeID: String,
    runtimeRootURL: URL,
    runtimeContentFingerprint: String,
    helperURL: URL,
    policyURL: URL,
    helperRevision: Int,
    policyRevision: Int
) throws -> RuntimeGPUIdentityEvidence {
    let helper = try RuntimeGPUIdentityFileEvidence(
        canonicalPath: helperURL.path,
        device: 1,
        inode: UInt64(10 + helperRevision),
        size: 4_096,
        modificationTimeNanoseconds: Int64(1_000 + helperRevision),
        mode: 0o100755,
        sha256: String(
            repeating: helperRevision == 0 ? "a" : "b",
            count: 64
        )
    )
    let policy = try RuntimeGPUIdentityFileEvidence(
        canonicalPath: policyURL.path,
        device: 1,
        inode: UInt64(20 + policyRevision),
        size: 1_024,
        modificationTimeNanoseconds: Int64(2_000 + policyRevision),
        mode: 0o100644,
        sha256: String(
            repeating: policyRevision == 0 ? "c" : "d",
            count: 64
        )
    )
    return try RuntimeGPUIdentityEvidence(
        runtimeID: runtimeID,
        runtimeRoot: runtimeRootURL.path,
        runtimeContentFingerprint: runtimeContentFingerprint,
        helper: helper,
        policy: policy
    )
}

private func waitForExecutionCount(
    _ expectedCount: Int,
    executor: ControlledGPUIdentityExecutor
) async {
    while await executor.executionCount < expectedCount {
        await Task.yield()
    }
}

private func waitForCounter(
    _ counter: PerformanceCounter,
    toReach expectedValue: UInt64,
    counters: PerformanceCounters
) async {
    while counters.snapshot()[counter] < expectedValue {
        await Task.yield()
    }
}
