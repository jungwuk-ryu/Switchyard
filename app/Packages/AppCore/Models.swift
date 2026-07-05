import Foundation

public enum HealthStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case warning
    case missing
    case unsupported
    case unknown
}

public enum ContainerStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case needsSetup
    case queued
    case running
    case failed
    case succeeded
}

public struct Container: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var wineBuildID: String
    public var patchsetID: String
    public var gptkFingerprint: String?
    public var executablePath: String?
    public var executableArguments: [String]
    public var lastRun: Date?
    public var status: ContainerStatus
    public var environmentOverrides: [String: String]
    public var schemaVersion: Int
    public var lastModified: Date

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        wineBuildID: String,
        patchsetID: String,
        gptkFingerprint: String? = nil,
        executablePath: String? = nil,
        executableArguments: [String] = [],
        lastRun: Date? = nil,
        status: ContainerStatus = .needsSetup,
        environmentOverrides: [String: String] = [:],
        schemaVersion: Int = 3,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.wineBuildID = wineBuildID
        self.patchsetID = patchsetID
        self.gptkFingerprint = gptkFingerprint
        self.executablePath = executablePath
        self.executableArguments = executableArguments
        self.lastRun = lastRun
        self.status = status
        self.environmentOverrides = environmentOverrides
        self.schemaVersion = schemaVersion
        self.lastModified = lastModified
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case wineBuildID
        case patchsetID
        case gptkFingerprint
        case executablePath
        case executableArguments
        case lastRun
        case status
        case environmentOverrides
        case schemaVersion
        case lastModified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        wineBuildID = try container.decode(String.self, forKey: .wineBuildID)
        patchsetID = try container.decode(String.self, forKey: .patchsetID)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        gptkFingerprint = try container.decodeIfPresent(String.self, forKey: .gptkFingerprint)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        let decodedArguments = try container.decodeIfPresent([String].self, forKey: .executableArguments)
        if decodedSchemaVersion < 3,
           (decodedArguments?.isEmpty ?? true),
           let executablePath {
            executableArguments = ExecutableArgumentRecommendations.arguments(forExecutablePath: executablePath)
        } else {
            executableArguments = decodedArguments ?? []
        }
        lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
        status = try container.decodeIfPresent(ContainerStatus.self, forKey: .status) ?? .needsSetup
        environmentOverrides = try container.decodeIfPresent([String: String].self, forKey: .environmentOverrides) ?? [:]
        schemaVersion = max(decodedSchemaVersion, 3)
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
    }
}

public enum InstalledProgramSource: String, Codable, Equatable, Sendable {
    case programFiles
    case defaultExecutable
}

public struct InstalledProgram: Identifiable, Codable, Equatable, Sendable {
    public var id: String { executablePath }
    public var name: String
    public var executablePath: String
    public var installDirectory: String
    public var source: InstalledProgramSource

    public init(
        name: String,
        executablePath: String,
        installDirectory: String,
        source: InstalledProgramSource
    ) {
        self.name = name
        self.executablePath = executablePath
        self.installDirectory = installDirectory
        self.source = source
    }
}

public enum LaunchArgumentParser {
    public static func parse(_ commandLine: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in commandLine {
            if isEscaping {
                if character == "\\" || character == "\"" || character == "'" || character.isWhitespace {
                    current.append(character)
                } else {
                    current.append("\\")
                    current.append(character)
                }
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                appendCurrentArgument(&arguments, current: &current)
            } else {
                current.append(character)
            }
        }

        if isEscaping {
            current.append("\\")
        }
        appendCurrentArgument(&arguments, current: &current)
        return arguments
    }

    public static func format(_ arguments: [String]) -> String {
        arguments.map(formatArgument).joined(separator: " ")
    }

    private static func appendCurrentArgument(_ arguments: inout [String], current: inout String) {
        guard !current.isEmpty else { return }
        arguments.append(current)
        current = ""
    }

    private static func formatArgument(_ argument: String) -> String {
        guard !argument.isEmpty else { return "\"\"" }
        guard argument.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" || $0 == "'" }) else {
            return argument
        }

        var escaped = "\""
        for character in argument {
            if character == "\"" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        escaped.append("\"")
        return escaped
    }
}

public enum ExecutableArgumentRecommendations {
    public static func arguments(forExecutablePath executablePath: String) -> [String] {
        let normalizedPath = executablePath.replacingOccurrences(of: "\\", with: "/")
        let executableName = URL(fileURLWithPath: normalizedPath).lastPathComponent.lowercased()
        guard executableName == "steam.exe" else { return [] }
        return ["-cef-disable-gpu", "-cef-disable-sandbox"]
    }
}

public enum EnvironmentOverridePolicy {
    public static func isAllowedKey(_ key: String) -> Bool {
        isValidKey(key) && !isReservedKey(key)
    }

    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              first == "_" || isASCIILetter(first) else {
            return false
        }
        return key.unicodeScalars.allSatisfy { scalar in
            scalar == "_" || isASCIILetter(scalar) || isASCIIDigit(scalar)
        }
    }

    public static func isReservedKey(_ key: String) -> Bool {
        let normalizedKey = key.uppercased()
        return normalizedKey == "WINEPREFIX" || normalizedKey.hasPrefix("SWITCHYARD_")
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(Int(scalar.value))
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
    public var state: OperationState
    public var progress: Double
    public var detail: String

    public init(
        id: UUID = UUID(),
        title: String,
        state: OperationState = .queued,
        progress: Double = 0,
        detail: String = ""
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.progress = progress
        self.detail = detail
    }
}

public struct RunSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var containerID: UUID
    public var containerName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var outcome: OperationState

    public init(
        id: UUID = UUID(),
        containerID: UUID,
        containerName: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        outcome: OperationState = .running
    ) {
        self.id = id
        self.containerID = containerID
        self.containerName = containerName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case containerID
        case containerName
        case legacyRunTargetID = "launcherID"
        case legacyRunTargetName = "launcherName"
        case startedAt
        case endedAt
        case exitCode
        case outcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let decodedContainerID = try container.decodeIfPresent(UUID.self, forKey: .containerID) {
            containerID = decodedContainerID
        } else {
            containerID = try container.decode(UUID.self, forKey: .legacyRunTargetID)
        }
        if let decodedContainerName = try container.decodeIfPresent(String.self, forKey: .containerName) {
            containerName = decodedContainerName
        } else {
            containerName = try container.decode(String.self, forKey: .legacyRunTargetName)
        }
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        outcome = try container.decode(OperationState.self, forKey: .outcome)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(containerID, forKey: .containerID)
        try container.encode(containerName, forKey: .containerName)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encode(outcome, forKey: .outcome)
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
