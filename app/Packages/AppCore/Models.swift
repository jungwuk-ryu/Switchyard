import Foundation

public enum HealthStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case warning
    case missing
    case unsupported
    case unknown
}

public enum LauncherKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case steam
    case epicGames
    case gogGalaxy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .steam: "Steam"
        case .epicGames: "Epic Games Launcher"
        case .gogGalaxy: "GOG Galaxy"
        }
    }
}

public enum LauncherStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case needsSetup
    case queued
    case running
    case failed
    case succeeded
}

public struct Bottle: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var wineBuildID: String
    public var patchsetID: String
    public var gptkFingerprint: String?
    public var schemaVersion: Int
    public var lastModified: Date

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        wineBuildID: String,
        patchsetID: String,
        gptkFingerprint: String? = nil,
        schemaVersion: Int = 1,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.wineBuildID = wineBuildID
        self.patchsetID = patchsetID
        self.gptkFingerprint = gptkFingerprint
        self.schemaVersion = schemaVersion
        self.lastModified = lastModified
    }
}

public struct Launcher: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: LauncherKind
    public var bottleID: UUID
    public var executablePath: String?
    public var lastRun: Date?
    public var status: LauncherStatus

    public init(
        id: UUID = UUID(),
        name: String,
        kind: LauncherKind,
        bottleID: UUID,
        executablePath: String? = nil,
        lastRun: Date? = nil,
        status: LauncherStatus = .needsSetup
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bottleID = bottleID
        self.executablePath = executablePath
        self.lastRun = lastRun
        self.status = status
    }
}

public struct RuntimeBuild: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var winePath: String
    public var patchsetID: String
    public var sourceRevision: String
    public var createdAt: Date

    public init(
        id: String,
        winePath: String,
        patchsetID: String,
        sourceRevision: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.winePath = winePath
        self.patchsetID = patchsetID
        self.sourceRevision = sourceRevision
        self.createdAt = createdAt
    }
}

public struct RuntimeStatus: Codable, Equatable, Sendable {
    public var architecture: HealthStatus
    public var macOS: HealthStatus
    public var gptk: HealthStatus
    public var wine: HealthStatus
    public var patchset: HealthStatus
    public var summary: String
    public var gptkFingerprint: String?

    public init(
        architecture: HealthStatus = .unknown,
        macOS: HealthStatus = .unknown,
        gptk: HealthStatus = .unknown,
        wine: HealthStatus = .unknown,
        patchset: HealthStatus = .unknown,
        summary: String = "Runtime has not been checked yet.",
        gptkFingerprint: String? = nil
    ) {
        self.architecture = architecture
        self.macOS = macOS
        self.gptk = gptk
        self.wine = wine
        self.patchset = patchset
        self.summary = summary
        self.gptkFingerprint = gptkFingerprint
    }

    public var canLaunch: Bool {
        architecture == .ok && macOS == .ok && gptk == .ok && wine == .ok && patchset == .ok
    }
}

public struct DiagnosticCheck: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: HealthStatus
    public var result: String
    public var recoveryAction: String?

    public init(
        id: String,
        title: String,
        status: HealthStatus,
        result: String,
        recoveryAction: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.result = result
        self.recoveryAction = recoveryAction
    }
}

public enum OperationState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public struct InstallJob: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var launcherKind: LauncherKind
    public var state: OperationState
    public var progress: Double
    public var detail: String

    public init(
        id: UUID = UUID(),
        title: String,
        launcherKind: LauncherKind,
        state: OperationState = .queued,
        progress: Double = 0,
        detail: String = ""
    ) {
        self.id = id
        self.title = title
        self.launcherKind = launcherKind
        self.state = state
        self.progress = progress
        self.detail = detail
    }
}

public struct RunSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var launcherID: UUID
    public var launcherName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var outcome: OperationState

    public init(
        id: UUID = UUID(),
        launcherID: UUID,
        launcherName: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        outcome: OperationState = .running
    ) {
        self.id = id
        self.launcherID = launcherID
        self.launcherName = launcherName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.outcome = outcome
    }
}

public struct LogLine: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var level: String
    public var source: String
    public var message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: String,
        source: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
    }
}

public struct CommandPlan: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var logSource: String

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        logSource: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logSource = logSource
    }
}

public struct LaunchProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var launcher: Launcher
    public var bottle: Bottle
    public var runtime: RuntimeBuild
    public var useGPTK: Bool
    public var gptkPath: String?
    public var environmentOverrides: [String: String]

    public init(
        id: UUID = UUID(),
        launcher: Launcher,
        bottle: Bottle,
        runtime: RuntimeBuild,
        useGPTK: Bool,
        gptkPath: String?,
        environmentOverrides: [String: String] = [:]
    ) {
        self.id = id
        self.launcher = launcher
        self.bottle = bottle
        self.runtime = runtime
        self.useGPTK = useGPTK
        self.gptkPath = gptkPath
        self.environmentOverrides = environmentOverrides
    }
}

public struct DiagnosticBundle: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var runtimeStatus: RuntimeStatus
    public var checks: [DiagnosticCheck]
    public var recentLogs: [LogLine]

    public init(
        createdAt: Date = Date(),
        runtimeStatus: RuntimeStatus,
        checks: [DiagnosticCheck],
        recentLogs: [LogLine]
    ) {
        self.createdAt = createdAt
        self.runtimeStatus = runtimeStatus
        self.checks = checks
        self.recentLogs = recentLogs
    }
}
