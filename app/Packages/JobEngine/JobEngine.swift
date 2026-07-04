import AppCore
import Foundation
import LauncherAdapters
import Persistence
import RuntimeCatalog

public enum JobEngineError: Error, Equatable {
    case missingBottle(UUID)
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
    public var fontInstaller: BottleFontInstaller

    public init(
        adapters: LauncherAdapterRegistry = LauncherAdapterRegistry(),
        runner: any RunnerClient = FakeRunnerClient(),
        fontInstaller: BottleFontInstaller = BottleFontInstaller()
    ) {
        self.adapters = adapters
        self.runner = runner
        self.fontInstaller = fontInstaller
    }

    public func installPlan(
        launcherKind: LauncherKind,
        bottle: Bottle,
        runtime: RuntimeBuild,
        gptkPath: String?,
        installerPath: String
    ) throws -> CommandPlan {
        let adapter = try adapters.adapter(for: launcherKind)
        return adapter.installPlan(bottle: bottle, runtime: runtime, gptkPath: gptkPath, installerPath: installerPath)
    }

    public func runPlan(
        launcher: Launcher,
        bottles: [Bottle],
        runtime: RuntimeBuild,
        gptkPath: String?,
        environmentOverrides: [String: String] = [:]
    ) throws -> CommandPlan {
        guard let bottle = bottles.first(where: { $0.id == launcher.bottleID }) else {
            throw JobEngineError.missingBottle(launcher.bottleID)
        }

        let adapter = try adapters.adapter(for: launcher.kind)
        let profile = LaunchProfile(
            launcher: launcher,
            bottle: bottle,
            runtime: runtime,
            useGPTK: gptkPath?.isEmpty == false,
            gptkPath: gptkPath,
            environmentOverrides: environmentOverrides
        )
        return try adapter.runPlan(profile: profile)
    }

    public func run(
        launcher: Launcher,
        bottles: [Bottle],
        runtime: RuntimeBuild,
        gptkPath: String?
    ) throws -> RunSession {
        let plan = try runPlan(launcher: launcher, bottles: bottles, runtime: runtime, gptkPath: gptkPath)
        return try runner.run(plan, launcherID: launcher.id, launcherName: launcher.name)
    }

    public func installOpenFontPack(into bottle: Bottle, from fontCacheRoot: URL) throws -> BottleFontInstallResult {
        try fontInstaller.installOpenFontPack(into: bottle, from: fontCacheRoot)
    }
}
