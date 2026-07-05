import AppCore
import Foundation

public enum LauncherAdapterError: Error, Equatable {
    case unsupportedLauncher(LauncherKind)
    case missingExecutable(LauncherKind)
}

public protocol LauncherAdapter {
    var kind: LauncherKind { get }
    var displayName: String { get }
    func installPlan(container: Container, runtime: RuntimeBuild, gptkPath: String?, installerPath: String) -> CommandPlan
    func runPlan(profile: LaunchProfile) throws -> CommandPlan
}

public struct SteamAdapter: LauncherAdapter {
    public let kind: LauncherKind = .steam
    public let displayName = "Steam"

    public init() {}

    public func installPlan(container: Container, runtime: RuntimeBuild, gptkPath: String?, installerPath: String) -> CommandPlan {
        commandPlan(
            runtime: runtime,
            container: container,
            executablePath: installerPath,
            gptkPath: gptkPath,
            logSource: "steam-install"
        )
    }

    public func runPlan(profile: LaunchProfile) throws -> CommandPlan {
        guard let executablePath = profile.launcher.executablePath else {
            throw LauncherAdapterError.missingExecutable(.steam)
        }

        return commandPlan(
            runtime: profile.runtime,
            container: profile.container,
            executablePath: executablePath,
            gptkPath: profile.gptkPath,
            overrides: profile.environmentOverrides,
            logSource: "steam"
        )
    }
}

public struct EpicGamesAdapter: LauncherAdapter {
    public let kind: LauncherKind = .epicGames
    public let displayName = "Epic Games Launcher"

    public init() {}

    public func installPlan(container: Container, runtime: RuntimeBuild, gptkPath: String?, installerPath: String) -> CommandPlan {
        commandPlan(
            runtime: runtime,
            container: container,
            executablePath: installerPath,
            gptkPath: gptkPath,
            logSource: "epic-install"
        )
    }

    public func runPlan(profile: LaunchProfile) throws -> CommandPlan {
        guard let executablePath = profile.launcher.executablePath else {
            throw LauncherAdapterError.missingExecutable(.epicGames)
        }

        return commandPlan(
            runtime: profile.runtime,
            container: profile.container,
            executablePath: executablePath,
            gptkPath: profile.gptkPath,
            overrides: profile.environmentOverrides,
            logSource: "epic"
        )
    }
}

public struct GOGGalaxyAdapter: LauncherAdapter {
    public let kind: LauncherKind = .gogGalaxy
    public let displayName = "GOG Galaxy"

    public init() {}

    public func installPlan(container: Container, runtime: RuntimeBuild, gptkPath: String?, installerPath: String) -> CommandPlan {
        commandPlan(
            runtime: runtime,
            container: container,
            executablePath: installerPath,
            gptkPath: gptkPath,
            logSource: "gog-install"
        )
    }

    public func runPlan(profile: LaunchProfile) throws -> CommandPlan {
        guard let executablePath = profile.launcher.executablePath else {
            throw LauncherAdapterError.missingExecutable(.gogGalaxy)
        }

        return commandPlan(
            runtime: profile.runtime,
            container: profile.container,
            executablePath: executablePath,
            gptkPath: profile.gptkPath,
            overrides: profile.environmentOverrides,
            logSource: "gog"
        )
    }
}

public struct LauncherAdapterRegistry {
    private let adapters: [LauncherKind: any LauncherAdapter]

    public init(adapters: [any LauncherAdapter] = [SteamAdapter(), EpicGamesAdapter(), GOGGalaxyAdapter()]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.kind, $0) })
    }

    public func adapter(for kind: LauncherKind) throws -> any LauncherAdapter {
        guard let adapter = adapters[kind] else {
            throw LauncherAdapterError.unsupportedLauncher(kind)
        }
        return adapter
    }
}

private func commandPlan(
    runtime: RuntimeBuild,
    container: Container,
    executablePath: String,
    gptkPath: String?,
    overrides: [String: String] = [:],
    logSource: String
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
        arguments: [executablePath],
        environment: environment,
        workingDirectory: container.path,
        logSource: logSource
    )
}
