import AppCore
import Foundation
import LauncherAdapters
import Persistence
import RuntimeCatalog

public enum JobEngineError: Error, Equatable {
    case missingContainer(UUID)
    case runtimeNotRunnable(RuntimeStatus)
}

public protocol RunnerClient {
    func run(_ plan: CommandPlan, launcherID: UUID, launcherName: String) throws -> RunSession
}

public struct FakeRunnerClient: RunnerClient {
    public init() {}

    public func run(_ plan: CommandPlan, launcherID: UUID, launcherName: String) throws -> RunSession {
        RunSession(
            launcherID: launcherID,
            launcherName: launcherName,
            endedAt: Date(),
            exitCode: 0,
            outcome: .succeeded
        )
    }
}

public struct JobEngine {
    public var adapters: LauncherAdapterRegistry
    public var runner: any RunnerClient
    public var fontInstaller: ContainerFontInstaller

    public init(
        adapters: LauncherAdapterRegistry = LauncherAdapterRegistry(),
        runner: any RunnerClient = FakeRunnerClient(),
        fontInstaller: ContainerFontInstaller = ContainerFontInstaller()
    ) {
        self.adapters = adapters
        self.runner = runner
        self.fontInstaller = fontInstaller
    }

    public func installPlan(
        launcherKind: LauncherKind,
        container: Container,
        runtime: RuntimeBuild,
        gptkPath: String?,
        installerPath: String
    ) throws -> CommandPlan {
        let adapter = try adapters.adapter(for: launcherKind)
        return adapter.installPlan(container: container, runtime: runtime, gptkPath: gptkPath, installerPath: installerPath)
    }

    public func runPlan(
        launcher: Launcher,
        containers: [Container],
        runtime: RuntimeBuild,
        gptkPath: String?,
        environmentOverrides: [String: String] = [:]
    ) throws -> CommandPlan {
        guard let container = containers.first(where: { $0.id == launcher.containerID }) else {
            throw JobEngineError.missingContainer(launcher.containerID)
        }
        var mergedEnvironmentOverrides = container.environmentOverrides
        for (key, value) in environmentOverrides {
            mergedEnvironmentOverrides[key] = value
        }

        let adapter = try adapters.adapter(for: launcher.kind)
        let profile = LaunchProfile(
            launcher: launcher,
            container: container,
            runtime: runtime,
            useGPTK: gptkPath?.isEmpty == false,
            gptkPath: gptkPath,
            environmentOverrides: mergedEnvironmentOverrides
        )
        return try adapter.runPlan(profile: profile)
    }

    public func run(
        launcher: Launcher,
        containers: [Container],
        runtime: RuntimeBuild,
        gptkPath: String?
    ) throws -> RunSession {
        let plan = try runPlan(launcher: launcher, containers: containers, runtime: runtime, gptkPath: gptkPath)
        return try runner.run(plan, launcherID: launcher.id, launcherName: launcher.name)
    }

    public func installOpenFontPack(into container: Container, from fontCacheRoot: URL) throws -> ContainerFontInstallResult {
        try fontInstaller.installOpenFontPack(into: container, from: fontCacheRoot)
    }
}
