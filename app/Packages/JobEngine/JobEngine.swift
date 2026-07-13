import AppCore
import Foundation

public enum JobEngineError: Error, Equatable {
    case missingExecutable(UUID)
    case runtimeNotRunnable(RuntimeStatus)
}

extension JobEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "Choose a Windows executable for this container before running."
        case let .runtimeNotRunnable(status):
            status.summary
        }
    }
}

public protocol RunnerClient {
    func run(_ plan: CommandPlan, containerID: UUID, containerName: String) throws -> RunSession
}

public struct FakeRunnerClient: RunnerClient {
    public init() {}

    public func run(_ plan: CommandPlan, containerID: UUID, containerName: String) throws -> RunSession {
        RunSession(
            containerID: containerID,
            containerName: containerName,
            endedAt: Date(),
            exitCode: 0,
            outcome: .succeeded
        )
    }
}

public struct JobEngine {
    public var runner: any RunnerClient
    public var fontInstaller: ContainerFontInstaller

    public init(
        runner: any RunnerClient = FakeRunnerClient(),
        fontInstaller: ContainerFontInstaller = ContainerFontInstaller()
    ) {
        self.runner = runner
        self.fontInstaller = fontInstaller
    }

    public func installPlan(
        container: Container,
        runtime: RuntimeBuild,
        gptkPath: String?,
        installerPath: String
    ) throws -> CommandPlan {
        commandPlan(
            runtime: runtime,
            container: container,
            executablePath: installerPath,
            gptkPath: gptkPath,
            logSource: "\(container.name)-install"
        )
    }

    public func runPlan(
        container: Container,
        executablePath: String? = nil,
        executableArguments: [String] = [],
        runtime: RuntimeBuild,
        gptkPath: String?,
        environmentOverrides: [String: String] = [:],
        terminateExistingPrefixSession: Bool = false
    ) throws -> CommandPlan {
        let selectedExecutablePath = executablePath ?? container.executablePath
        guard let preparedExecutablePath = selectedExecutablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preparedExecutablePath.isEmpty else {
            throw JobEngineError.missingExecutable(container.id)
        }

        var mergedEnvironmentOverrides = container.environmentOverrides
        for (key, value) in environmentOverrides {
            mergedEnvironmentOverrides[key] = value
        }

        return commandPlan(
            runtime: runtime,
            container: container,
            executablePath: preparedExecutablePath,
            executableArguments: executablePath == nil && executableArguments.isEmpty ? container.executableArguments : executableArguments,
            gptkPath: gptkPath,
            overrides: mergedEnvironmentOverrides,
            logSource: container.name,
            terminateExistingPrefixSession: terminateExistingPrefixSession
        )
    }

    public func run(
        container: Container,
        executablePath: String? = nil,
        executableArguments: [String] = [],
        runtime: RuntimeBuild,
        gptkPath: String?
    ) throws -> RunSession {
        let plan = try runPlan(
            container: container,
            executablePath: executablePath,
            executableArguments: executableArguments,
            runtime: runtime,
            gptkPath: gptkPath
        )
        return try runner.run(plan, containerID: container.id, containerName: container.name)
    }

    public func installOpenFontPack(into container: Container, from fontCacheRoot: URL) throws -> ContainerFontInstallResult {
        try fontInstaller.installOpenFontPack(into: container, from: fontCacheRoot)
    }
}

private func commandPlan(
    runtime: RuntimeBuild,
    container: Container,
    executablePath: String,
    executableArguments: [String] = [],
    gptkPath: String?,
    overrides: [String: String] = [:],
    logSource: String,
    terminateExistingPrefixSession: Bool = false
) -> CommandPlan {
    var environment = [
        "WINEPREFIX": container.path,
        "SWITCHYARD_WINE_BUILD_ID": runtime.id,
        "SWITCHYARD_PATCHSET_ID": runtime.patchsetID
    ]

    if let gptkPath, !gptkPath.isEmpty {
        environment["SWITCHYARD_GPTK_PATH"] = gptkPath
        environment["MTL_HUD_ENABLED"] = environment["MTL_HUD_ENABLED", default: "0"]
    }

    for (key, value) in overrides where EnvironmentOverridePolicy.isAllowedKey(key) {
        environment[key] = value
    }

    return CommandPlan(
        executable: runtime.winePath,
        arguments: [executablePath] + executableArguments,
        environment: environment,
        workingDirectory: container.path,
        logSource: logSource,
        terminateExistingPrefixSession: terminateExistingPrefixSession
    )
}
