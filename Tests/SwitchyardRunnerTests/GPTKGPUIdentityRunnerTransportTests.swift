import AppCore
import Foundation
import JobEngine
import RuntimeCatalog
import Testing
@testable import SwitchyardRunner

@Suite("Runner GPTK GPU Identity Validation")
struct GPTKGPUIdentityRunnerValidationTests {
    @Test("validates every current input and emits bounded transport")
    func validatesCompleteCurrentSnapshot() async throws {
        let fixture = try runnerGPUFixture()
        let builder = RecordingRunnerGPUIdentityEvidenceBuilder(
            response: .evidence(
                fixture.snapshot.cacheKey.runtime
            )
        )
        let validator = RunnerGPUIdentityPlanValidator(
            contextProvider: FixedRunnerGPUIdentityContextProvider(
                context: fixture.context
            ),
            evidenceBuilder: builder
        )

        let transport = try await validator.validate(
            plan: fixture.plan,
            runnerURL: fixture.runnerURL
        )

        #expect(transport.helperPath == fixture.runnerURL.path)
        #expect(
            try GPTKGPUIdentityTransport.decodeIdentity(
                transport.encodedIdentity
            ) == fixture.snapshot.identity
        )
        #expect(await builder.buildCount == 1)
        let invocation = try #require(await builder.invocations.first)
        #expect(invocation.runtimeID == fixture.runtime.id)
        #expect(invocation.runtimeRootURL.path == fixture.runtimeRoot.path)
        #expect(
            invocation.runtimeContentFingerprint
                == fixture.snapshot.cacheKey.runtime
                    .runtimeContentFingerprint
        )
        #expect(
            invocation.helperURL.path
                == "/private/runtime-a/libexec/switchyard-host-gpu-info"
        )
        #expect(
            invocation.policyURL.path
                == "/private/runtime-a/share/switchyard/gpu_capability_policy.sh"
        )
    }

    @Test("validates a production JobEngine launch plan")
    func validatesJobEngineLaunchPlan() async throws {
        let fixture = try runnerGPUFixture()
        let container = Container(
            name: "GPU transport",
            path: "/private/prefix",
            executablePath: "C:\\Games\\game.exe",
            status: .ready
        )
        var plan = try JobEngine().runPlan(
            container: container,
            runtime: fixture.runtime,
            gptkPath: nil
        )
        #expect(
            plan.environment[
                RuntimeGPUIdentityContentFingerprint
                    .sourceRevisionEnvironmentKey
            ] == fixture.runtime.sourceRevision
        )
        plan.environment[
            GPTKGPUIdentityTransport.gptkRootEnvironmentKey
        ] = "/private/gptk"
        plan.gptkGPUIdentitySnapshot = fixture.snapshot

        let transport = try await validRunnerGPUValidator(
            fixture
        ).validate(
            plan: plan,
            runnerURL: fixture.runnerURL
        )

        #expect(transport.helperPath == fixture.runnerURL.path)
        #expect(
            try GPTKGPUIdentityTransport.decodeIdentity(
                transport.encodedIdentity
            ) == fixture.snapshot.identity
        )
    }

    @Test("rejects stale host, runtime, and content identities")
    func rejectsStaleIdentityInputs() async throws {
        let fixture = try runnerGPUFixture()

        var nonGPTKPlan = fixture.plan
        nonGPTKPlan.environment.removeValue(
            forKey:
                GPTKGPUIdentityTransport.gptkRootEnvironmentKey
        )
        await #expect(
            throws:
                RunnerGPUIdentityValidationError.gptkNotEnabled
        ) {
            try await validRunnerGPUValidator(fixture).validate(
                plan: nonGPTKPlan,
                runnerURL: fixture.runnerURL
            )
        }

        let staleOSValidator = RunnerGPUIdentityPlanValidator(
            contextProvider: FixedRunnerGPUIdentityContextProvider(
                context: RunnerGPUIdentitySystemContext(
                    operatingSystemBuild: "24G91",
                    defaultGPURegistryID:
                        fixture.context.defaultGPURegistryID
                )
            ),
            evidenceBuilder:
                RecordingRunnerGPUIdentityEvidenceBuilder(
                    response: .evidence(
                        fixture.snapshot.cacheKey.runtime
                    )
                )
        )
        await #expect(
            throws:
                RunnerGPUIdentityValidationError.operatingSystemChanged
        ) {
            try await staleOSValidator.validate(
                plan: fixture.plan,
                runnerURL: fixture.runnerURL
            )
        }

        let staleGPUValidator = RunnerGPUIdentityPlanValidator(
            contextProvider: FixedRunnerGPUIdentityContextProvider(
                context: RunnerGPUIdentitySystemContext(
                    operatingSystemBuild:
                        fixture.context.operatingSystemBuild,
                    defaultGPURegistryID: 0x101
                )
            ),
            evidenceBuilder:
                RecordingRunnerGPUIdentityEvidenceBuilder(
                    response: .evidence(
                        fixture.snapshot.cacheKey.runtime
                    )
                )
        )
        await #expect(
            throws:
                RunnerGPUIdentityValidationError.defaultGPUChanged
        ) {
            try await staleGPUValidator.validate(
                plan: fixture.plan,
                runnerURL: fixture.runnerURL
            )
        }

        var mismatchedRuntimePlan = fixture.plan
        mismatchedRuntimePlan.environment[
            RuntimeGPUIdentityContentFingerprint.runtimeIDEnvironmentKey
        ] = "runtime-b"
        await #expect(
            throws:
                RunnerGPUIdentityValidationError.runtimeIDMismatch
        ) {
            try await validRunnerGPUValidator(fixture).validate(
                plan: mismatchedRuntimePlan,
                runnerURL: fixture.runnerURL
            )
        }

        var mismatchedRootPlan = fixture.plan
        mismatchedRootPlan.executable =
            "/private/runtime-b/bin/wine"
        await #expect(
            throws:
                RunnerGPUIdentityValidationError.runtimeRootMismatch
        ) {
            try await validRunnerGPUValidator(fixture).validate(
                plan: mismatchedRootPlan,
                runnerURL: fixture.runnerURL
            )
        }

        var invalidExecutablePlan = fixture.plan
        invalidExecutablePlan.executable =
            "/private/runtime-a/bin/untrusted"
        await #expect(
            throws:
                RunnerGPUIdentityValidationError
                    .invalidRuntimeExecutable
        ) {
            try await validRunnerGPUValidator(fixture).validate(
                plan: invalidExecutablePlan,
                runnerURL: fixture.runnerURL
            )
        }

        var changedContentPlan = fixture.plan
        changedContentPlan.environment[
            RuntimeGPUIdentityContentFingerprint
                .sourceRevisionEnvironmentKey
        ] = String(repeating: "b", count: 40)
        await #expect(
            throws:
                RunnerGPUIdentityValidationError
                    .runtimeContentMismatch
        ) {
            try await validRunnerGPUValidator(fixture).validate(
                plan: changedContentPlan,
                runnerURL: fixture.runnerURL
            )
        }
    }

    @Test("requires exact pinned helper, policy, and rebuilt evidence")
    func rejectsRuntimeEvidenceChanges() async throws {
        let helperMismatch = try runnerGPUFixture(
            helperPath:
                "/private/runtime-a/libexec/other-helper"
        )
        await #expect(
            throws:
                RunnerGPUIdentityValidationError.helperPathMismatch
        ) {
            try await validRunnerGPUValidator(helperMismatch).validate(
                plan: helperMismatch.plan,
                runnerURL: helperMismatch.runnerURL
            )
        }

        let policyMismatch = try runnerGPUFixture(
            policyPath:
                "/private/runtime-a/share/switchyard/other-policy.sh"
        )
        await #expect(
            throws:
                RunnerGPUIdentityValidationError.policyPathMismatch
        ) {
            try await validRunnerGPUValidator(policyMismatch).validate(
                plan: policyMismatch.plan,
                runnerURL: policyMismatch.runnerURL
            )
        }

        let fixture = try runnerGPUFixture()
        let changedEvidence = try replacingHelperInode(
            fixture.snapshot.cacheKey.runtime
        )
        let changedValidator = RunnerGPUIdentityPlanValidator(
            contextProvider: FixedRunnerGPUIdentityContextProvider(
                context: fixture.context
            ),
            evidenceBuilder:
                RecordingRunnerGPUIdentityEvidenceBuilder(
                    response: .evidence(changedEvidence)
                )
        )
        await #expect(
            throws:
                RunnerGPUIdentityValidationError
                    .runtimeEvidenceChanged
        ) {
            try await changedValidator.validate(
                plan: fixture.plan,
                runnerURL: fixture.runnerURL
            )
        }

        let unavailableValidator = RunnerGPUIdentityPlanValidator(
            contextProvider: FixedRunnerGPUIdentityContextProvider(
                context: fixture.context
            ),
            evidenceBuilder:
                RecordingRunnerGPUIdentityEvidenceBuilder(
                    response: .failure
                )
        )
        await #expect(
            throws:
                RunnerGPUIdentityValidationError
                    .runtimeEvidenceUnavailable
        ) {
            try await unavailableValidator.validate(
                plan: fixture.plan,
                runnerURL: fixture.runnerURL
            )
        }
    }
}

@Suite("Runner GPTK GPU Identity Environment")
struct RunnerGPUIdentityEnvironmentTests {
    @Test("strips caller values and applies only validated transport")
    func sanitizesAndAppliesValidatedTransport() async throws {
        let fixture = try runnerGPUFixture()
        let transport = try await validRunnerGPUValidator(
            fixture
        ).validate(
            plan: fixture.plan,
            runnerURL: fixture.runnerURL
        )
        let unknownPrivateKey =
            GPTKGPUIdentityTransport.privateEnvironmentKeyPrefix
                + "FUTURE"
        let environment =
            RunnerGPUIdentityLaunchEnvironment.assemble(
                inheritedEnvironment: [
                    "PATH": "/usr/bin",
                    GPTKGPUIdentityTransport.helperEnvironmentKey:
                        "/tmp/inherited-helper",
                    GPTKGPUIdentityTransport
                        .cachedIdentityEnvironmentKey:
                        "inherited",
                    unknownPrivateKey: "inherited",
                ],
                planEnvironment: [
                    "WINEPREFIX": "/private/prefix",
                    GPTKGPUIdentityTransport.helperEnvironmentKey:
                        "/tmp/plan-helper",
                    GPTKGPUIdentityTransport
                        .cachedIdentityEnvironmentKey:
                        "plan",
                    unknownPrivateKey: "plan",
                ],
                validatedTransport: transport
            )

        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["WINEPREFIX"] == "/private/prefix")
        #expect(
            environment[
                GPTKGPUIdentityTransport.helperEnvironmentKey
            ] == fixture.runnerURL.path
        )
        #expect(
            environment[
                GPTKGPUIdentityTransport
                    .cachedIdentityEnvironmentKey
            ] == transport.encodedIdentity
        )
        #expect(environment[unknownPrivateKey] == nil)
    }

    @Test("absent or invalid snapshots leave the external fallback intact")
    func invalidSnapshotOmitsOverrides() throws {
        let unknownPrivateKey =
            GPTKGPUIdentityTransport.privateEnvironmentKeyPrefix
                + "FUTURE"
        let environment =
            RunnerGPUIdentityLaunchEnvironment.assemble(
                inheritedEnvironment: [
                    GPTKGPUIdentityTransport.helperEnvironmentKey:
                        "/tmp/inherited-helper",
                    unknownPrivateKey: "inherited",
                    "PATH": "/usr/bin",
                ],
                planEnvironment: [
                    GPTKGPUIdentityTransport.helperEnvironmentKey:
                        "/tmp/plan-helper",
                    GPTKGPUIdentityTransport
                        .cachedIdentityEnvironmentKey:
                        "plan",
                    "WINEPREFIX": "/private/prefix",
                ],
                validatedTransport: nil
            )

        #expect(
            environment[
                GPTKGPUIdentityTransport.helperEnvironmentKey
            ] == nil
        )
        #expect(
            environment[
                GPTKGPUIdentityTransport
                    .cachedIdentityEnvironmentKey
            ] == nil
        )
        #expect(environment[unknownPrivateKey] == nil)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["WINEPREFIX"] == "/private/prefix")
    }

    @Test("no-argument helper emits only validated canonical TSV")
    func helperOutputIsExactAndFailClosed() async throws {
        let fixture = try runnerGPUFixture()
        let transport = try await validRunnerGPUValidator(
            fixture
        ).validate(
            plan: fixture.plan,
            runnerURL: fixture.runnerURL
        )
        let validEnvironment =
            RunnerGPUIdentityLaunchEnvironment.assemble(
                inheritedEnvironment: ["PATH": "/usr/bin"],
                planEnvironment: [:],
                validatedTransport: transport
            )

        #expect(
            RunnerGPUIdentityLaunchEnvironment.helperOutput(
                arguments: [],
                environment: validEnvironment,
                runnerURL: fixture.runnerURL
            ) == fixture.snapshot.identity.canonicalTSVData
        )
        #expect(
            RunnerGPUIdentityLaunchEnvironment.helperOutput(
                arguments: ["unexpected"],
                environment: validEnvironment,
                runnerURL: fixture.runnerURL
            ) == nil
        )

        var wrongRunnerEnvironment = validEnvironment
        wrongRunnerEnvironment[
            GPTKGPUIdentityTransport.helperEnvironmentKey
        ] = "/private/other-runner"
        #expect(
            RunnerGPUIdentityLaunchEnvironment.helperOutput(
                arguments: [],
                environment: wrongRunnerEnvironment,
                runnerURL: fixture.runnerURL
            ) == nil
        )

        var ambiguousEnvironment = validEnvironment
        ambiguousEnvironment[
            GPTKGPUIdentityTransport.privateEnvironmentKeyPrefix
                + "FUTURE"
        ] = "value"
        #expect(
            RunnerGPUIdentityLaunchEnvironment.helperOutput(
                arguments: [],
                environment: ambiguousEnvironment,
                runnerURL: fixture.runnerURL
            ) == nil
        )

        var malformedEnvironment = validEnvironment
        malformedEnvironment[
            GPTKGPUIdentityTransport.cachedIdentityEnvironmentKey
        ] = "invalid"
        #expect(
            RunnerGPUIdentityLaunchEnvironment.helperOutput(
                arguments: [],
                environment: malformedEnvironment,
                runnerURL: fixture.runnerURL
            ) == nil
        )
    }
}

private struct RunnerGPUIdentityFixture {
    let runtime: RuntimeBuild
    let runtimeRoot: URL
    let runnerURL: URL
    let context: RunnerGPUIdentitySystemContext
    let snapshot: GPTKGPUIdentitySnapshot
    let plan: CommandPlan
}

private struct FixedRunnerGPUIdentityContextProvider:
    RunnerGPUIdentitySystemContextProviding
{
    let context: RunnerGPUIdentitySystemContext

    func currentContext() -> RunnerGPUIdentitySystemContext {
        context
    }
}

private enum RecordingRunnerGPUIdentityEvidenceResponse:
    Sendable
{
    case evidence(RuntimeGPUIdentityEvidence)
    case failure
}

private struct RecordingRunnerGPUIdentityEvidenceInvocation:
    Equatable,
    Sendable
{
    let runtimeID: String
    let runtimeRootURL: URL
    let runtimeContentFingerprint: String
    let helperURL: URL
    let policyURL: URL
}

private actor RecordingRunnerGPUIdentityEvidenceBuilder:
    RunnerGPUIdentityEvidenceBuilding
{
    private let response:
        RecordingRunnerGPUIdentityEvidenceResponse
    private(set) var invocations:
        [RecordingRunnerGPUIdentityEvidenceInvocation] = []

    init(response: RecordingRunnerGPUIdentityEvidenceResponse) {
        self.response = response
    }

    var buildCount: Int {
        invocations.count
    }

    func build(
        runtimeID: String,
        runtimeRootURL: URL,
        runtimeContentFingerprint: String,
        helperURL: URL,
        policyURL: URL
    ) throws -> RuntimeGPUIdentityEvidence {
        invocations.append(
            RecordingRunnerGPUIdentityEvidenceInvocation(
                runtimeID: runtimeID,
                runtimeRootURL: runtimeRootURL,
                runtimeContentFingerprint:
                    runtimeContentFingerprint,
                helperURL: helperURL,
                policyURL: policyURL
            )
        )
        switch response {
        case let .evidence(evidence):
            return evidence
        case .failure:
            throw RunnerGPUIdentityTestError.evidenceUnavailable
        }
    }
}

private enum RunnerGPUIdentityTestError: Error {
    case evidenceUnavailable
}

private func validRunnerGPUValidator(
    _ fixture: RunnerGPUIdentityFixture
) -> RunnerGPUIdentityPlanValidator {
    RunnerGPUIdentityPlanValidator(
        contextProvider: FixedRunnerGPUIdentityContextProvider(
            context: fixture.context
        ),
        evidenceBuilder:
            RecordingRunnerGPUIdentityEvidenceBuilder(
                response: .evidence(
                    fixture.snapshot.cacheKey.runtime
                )
            )
    )
}

private func runnerGPUFixture(
    helperPath: String =
        "/private/runtime-a/libexec/switchyard-host-gpu-info",
    policyPath: String =
        "/private/runtime-a/share/switchyard/gpu_capability_policy.sh"
) throws -> RunnerGPUIdentityFixture {
    let runtimeRoot = URL(
        fileURLWithPath: "/private/runtime-a",
        isDirectory: true
    )
    let runnerURL = URL(
        fileURLWithPath: "/private/app/switchyard-runner"
    )
    let runtime = RuntimeBuild(
        id: "runtime-a",
        winePath: "/private/runtime-a/bin/wine",
        patchsetID: "patchset-a",
        sourceRevision: String(repeating: "a", count: 40)
    )
    let fingerprint =
        try RuntimeGPUIdentityContentFingerprint.make(for: runtime)
    let evidence = try RuntimeGPUIdentityEvidence(
        runtimeID: runtime.id,
        runtimeRoot: runtimeRoot.path,
        runtimeContentFingerprint: fingerprint,
        helper: try RuntimeGPUIdentityFileEvidence(
            canonicalPath: helperPath,
            device: 1,
            inode: 2,
            size: 4_096,
            modificationTimeNanoseconds: 1_000,
            mode: 0o100755,
            sha256: String(repeating: "a", count: 64)
        ),
        policy: try RuntimeGPUIdentityFileEvidence(
            canonicalPath: policyPath,
            device: 1,
            inode: 3,
            size: 1_024,
            modificationTimeNanoseconds: 2_000,
            mode: 0o100644,
            sha256: String(repeating: "b", count: 64)
        )
    )
    let context = RunnerGPUIdentitySystemContext(
        operatingSystemBuild: "24G90",
        defaultGPURegistryID: 0x100
    )
    let snapshot = GPTKGPUIdentitySnapshot(
        cacheKey: try GPTKGPUIdentityCacheKey(
            operatingSystemBuild: context.operatingSystemBuild,
            defaultGPURegistryID: context.defaultGPURegistryID,
            runtime: evidence
        ),
        identity: try HostGPUIdentity(
            vendorID: 0x106B,
            deviceID: 1,
            subsystemID: 0,
            revisionID: 0,
            description: "Apple GPU"
        )
    )
    let environment = [
        RuntimeGPUIdentityContentFingerprint.runtimeIDEnvironmentKey:
            runtime.id,
        RuntimeGPUIdentityContentFingerprint.patchsetIDEnvironmentKey:
            runtime.patchsetID,
        RuntimeGPUIdentityContentFingerprint.sourceRevisionEnvironmentKey:
            runtime.sourceRevision,
        GPTKGPUIdentityTransport.gptkRootEnvironmentKey:
            "/private/gptk",
        "WINEPREFIX": "/private/prefix",
    ]
    let plan = CommandPlan(
        executable: runtime.winePath,
        arguments: ["game.exe"],
        environment: environment,
        workingDirectory: "/private/prefix",
        logSource: "GPU identity runner test",
        gptkGPUIdentitySnapshot: snapshot
    )
    return RunnerGPUIdentityFixture(
        runtime: runtime,
        runtimeRoot: runtimeRoot,
        runnerURL: runnerURL,
        context: context,
        snapshot: snapshot,
        plan: plan
    )
}

private func replacingHelperInode(
    _ evidence: RuntimeGPUIdentityEvidence
) throws -> RuntimeGPUIdentityEvidence {
    try RuntimeGPUIdentityEvidence(
        runtimeID: evidence.runtimeID,
        runtimeRoot: evidence.runtimeRoot,
        runtimeContentFingerprint:
            evidence.runtimeContentFingerprint,
        helper: try RuntimeGPUIdentityFileEvidence(
            canonicalPath: evidence.helper.canonicalPath,
            device: evidence.helper.device,
            inode: evidence.helper.inode + 1,
            size: evidence.helper.size,
            modificationTimeNanoseconds:
                evidence.helper.modificationTimeNanoseconds,
            mode: evidence.helper.mode,
            sha256: evidence.helper.sha256
        ),
        policy: evidence.policy
    )
}
