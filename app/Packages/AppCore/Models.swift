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

public struct ContainerRuntimeRecord: Codable, Equatable, Sendable {
    public var runtimeID: String
    public var patchsetID: String
    public var sourceRevision: String?
    public var gptkFingerprint: String?
    public var usedAt: Date?

    public init(
        runtimeID: String,
        patchsetID: String,
        sourceRevision: String? = nil,
        gptkFingerprint: String? = nil,
        usedAt: Date? = nil
    ) {
        self.runtimeID = runtimeID
        self.patchsetID = patchsetID
        self.sourceRevision = sourceRevision
        self.gptkFingerprint = gptkFingerprint
        self.usedAt = usedAt
    }
}

public struct Container: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var lastRuntime: ContainerRuntimeRecord?
    public var starterApplicationID: String?
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
        lastRuntime: ContainerRuntimeRecord? = nil,
        starterApplicationID: String? = nil,
        executablePath: String? = nil,
        executableArguments: [String] = [],
        lastRun: Date? = nil,
        status: ContainerStatus = .needsSetup,
        environmentOverrides: [String: String] = [:],
        schemaVersion: Int = 5,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.lastRuntime = lastRuntime
        self.starterApplicationID = starterApplicationID
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
        case lastRuntime
        // Schema 1-4 runtime fields were creation-time provenance that ADR 0002
        // incorrectly described as pins. Decode them into the last-use record.
        case wineBuildID
        case patchsetID
        case gptkFingerprint
        case starterApplicationID
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
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        starterApplicationID = try container.decodeIfPresent(String.self, forKey: .starterApplicationID)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        executableArguments = try container.decodeIfPresent([String].self, forKey: .executableArguments) ?? []
        lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
        if let decodedRecord = try container.decodeIfPresent(
            ContainerRuntimeRecord.self,
            forKey: .lastRuntime
        ) {
            lastRuntime = decodedRecord
        } else if let legacyRuntimeID = try container.decodeIfPresent(
            String.self,
            forKey: .wineBuildID
        ), let legacyPatchsetID = try container.decodeIfPresent(
            String.self,
            forKey: .patchsetID
        ) {
            lastRuntime = ContainerRuntimeRecord(
                runtimeID: legacyRuntimeID,
                patchsetID: legacyPatchsetID,
                gptkFingerprint: try container.decodeIfPresent(
                    String.self,
                    forKey: .gptkFingerprint
                )
            )
        } else {
            lastRuntime = nil
        }
        status = try container.decodeIfPresent(ContainerStatus.self, forKey: .status) ?? .needsSetup
        environmentOverrides = try container.decodeIfPresent([String: String].self, forKey: .environmentOverrides) ?? [:]
        schemaVersion = max(decodedSchemaVersion, 5)
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(lastRuntime, forKey: .lastRuntime)
        try container.encodeIfPresent(starterApplicationID, forKey: .starterApplicationID)
        try container.encodeIfPresent(executablePath, forKey: .executablePath)
        try container.encode(executableArguments, forKey: .executableArguments)
        try container.encodeIfPresent(lastRun, forKey: .lastRun)
        try container.encode(status, forKey: .status)
        try container.encode(environmentOverrides, forKey: .environmentOverrides)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(lastModified, forKey: .lastModified)
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

public struct RecentProgramLaunch: Identifiable, Codable, Equatable, Sendable {
    public var id: String { executablePath }
    public var executablePath: String
    public var launchedAt: Date

    public init(executablePath: String, launchedAt: Date) {
        self.executablePath = executablePath
        self.launchedAt = launchedAt
    }
}

public enum RecentProgramLaunchPolicy {
    public static func recording(
        executablePath: String,
        at launchedAt: Date = Date(),
        in launches: [RecentProgramLaunch],
        limit: Int = 8
    ) -> [RecentProgramLaunch] {
        guard limit > 0 else { return [] }
        let trimmedPath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return Array(launches.sorted { $0.launchedAt > $1.launchedAt }.prefix(limit))
        }
        let normalizedPath = URL(fileURLWithPath: trimmedPath).standardizedFileURL.path

        let remainingLaunches = launches
            .filter {
                URL(fileURLWithPath: $0.executablePath).standardizedFileURL.path != normalizedPath
            }
            .sorted { $0.launchedAt > $1.launchedAt }
        return Array(
            ([RecentProgramLaunch(executablePath: normalizedPath, launchedAt: launchedAt)]
                + remainingLaunches).prefix(limit)
        )
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

public enum RuntimeIdentityComparison: Equatable, Sendable {
    case matches
    case differs
    case unavailable
}

public enum ContainerRuntimePreparation: Equatable, Sendable {
    case none
    case initialize
    case refresh
}

public struct RuntimeBuild: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var winePath: String
    public var patchsetID: String
    public var sourceRevision: String
    public var createdAt: Date
    public var versionDate: Date?

    public init(
        id: String,
        winePath: String,
        patchsetID: String,
        sourceRevision: String,
        createdAt: Date = Date(),
        versionDate: Date? = nil
    ) {
        self.id = id
        self.winePath = winePath
        self.patchsetID = patchsetID
        self.sourceRevision = sourceRevision
        self.createdAt = createdAt
        self.versionDate = versionDate
    }

    /// A chronological, user-facing build number derived from the immutable
    /// pinned source revision time. Internal runtime identity continues to use
    /// `id`.
    public var buildNumber: String? {
        guard let versionDate else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: versionDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute else {
            return nil
        }

        return String(
            format: "%04d%02d%02d.%02d%02d",
            year,
            month,
            day,
            hour,
            minute
        )
    }

    public func comparison(
        toLastRuntime record: ContainerRuntimeRecord?
    ) -> RuntimeIdentityComparison {
        guard !sourceRevision.isEmpty,
              let record,
              let recordedSourceRevision = record.sourceRevision else {
            return .unavailable
        }
        return id == record.runtimeID
            && patchsetID == record.patchsetID
            && sourceRevision == recordedSourceRevision
            ? .matches
            : .differs
    }
}

public extension Container {
    func runtimePreparation(
        for runtime: RuntimeBuild,
        hasInitializedRegistry: Bool
    ) -> ContainerRuntimePreparation {
        guard hasInitializedRegistry else { return .initialize }
        guard let lastRuntime else { return .refresh }
        let activeSourceRevision = runtime.sourceRevision.isEmpty
            ? nil
            : runtime.sourceRevision
        return lastRuntime.runtimeID == runtime.id
            && lastRuntime.patchsetID == runtime.patchsetID
            && lastRuntime.sourceRevision == activeSourceRevision
            ? .none
            : .refresh
    }

    mutating func recordRuntimeUsage(
        _ runtime: RuntimeBuild,
        gptkFingerprint: String?,
        at usedAt: Date = Date()
    ) {
        lastRuntime = ContainerRuntimeRecord(
            runtimeID: runtime.id,
            patchsetID: runtime.patchsetID,
            sourceRevision: runtime.sourceRevision.isEmpty ? nil : runtime.sourceRevision,
            gptkFingerprint: gptkFingerprint,
            usedAt: usedAt
        )
    }
}

public struct RuntimeStatus: Codable, Equatable, Sendable {
    public var architecture: HealthStatus
    public var macOS: HealthStatus
    public var rosetta: HealthStatus
    public var gptk: HealthStatus
    public var wine: HealthStatus
    public var patchset: HealthStatus
    public var summary: String
    public var gptkFingerprint: String?

    public init(
        architecture: HealthStatus = .unknown,
        macOS: HealthStatus = .unknown,
        rosetta: HealthStatus = .unknown,
        gptk: HealthStatus = .unknown,
        wine: HealthStatus = .unknown,
        patchset: HealthStatus = .unknown,
        summary: String = "Runtime has not been checked yet.",
        gptkFingerprint: String? = nil
    ) {
        self.architecture = architecture
        self.macOS = macOS
        self.rosetta = rosetta
        self.gptk = gptk
        self.wine = wine
        self.patchset = patchset
        self.summary = summary
        self.gptkFingerprint = gptkFingerprint
    }

    public var canLaunch: Bool {
        architecture == .ok
            && macOS == .ok
            && rosetta == .ok
            && gptk == .ok
            && wine == .ok
            && patchset == .ok
    }

    private enum CodingKeys: String, CodingKey {
        case architecture
        case macOS
        case rosetta
        case gptk
        case wine
        case patchset
        case summary
        case gptkFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        architecture = try container.decode(HealthStatus.self, forKey: .architecture)
        macOS = try container.decode(HealthStatus.self, forKey: .macOS)
        rosetta = try container.decodeIfPresent(HealthStatus.self, forKey: .rosetta) ?? .unknown
        gptk = try container.decode(HealthStatus.self, forKey: .gptk)
        wine = try container.decode(HealthStatus.self, forKey: .wine)
        patchset = try container.decode(HealthStatus.self, forKey: .patchset)
        summary = try container.decode(String.self, forKey: .summary)
        gptkFingerprint = try container.decodeIfPresent(String.self, forKey: .gptkFingerprint)
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
    public var containerID: UUID?
    public var level: String
    public var source: String
    public var message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        containerID: UUID? = nil,
        level: String,
        source: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.containerID = containerID
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
    public var debugLogPath: String?
    public var terminateExistingPrefixSession: Bool?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        logSource: String,
        debugLogPath: String? = nil,
        terminateExistingPrefixSession: Bool? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logSource = logSource
        self.debugLogPath = debugLogPath
        self.terminateExistingPrefixSession = terminateExistingPrefixSession
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
