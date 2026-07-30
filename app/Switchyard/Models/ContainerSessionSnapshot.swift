import Foundation

enum WineServerState: Equatable, Sendable {
    case checking
    case active
    case orphaned
    case inactive
    case unavailable

    var isWineServerRunning: Bool {
        self == .active
    }

    var hasRunningProcesses: Bool {
        self == .active || self == .orphaned
    }
}

struct WindowsProcessSnapshot: Identifiable, Equatable, Sendable {
    var id: String {
        processID.map { "pid:\($0)" }
            ?? legacyProcessID
    }
    let executablePath: String
    let processID: UInt32?
    private let legacyOccurrence: Int

    init(executablePath: String, processID: UInt32? = nil) {
        self.executablePath = executablePath
        self.processID = processID
        legacyOccurrence = 0
    }

    private init(
        executablePath: String,
        processID: UInt32?,
        legacyOccurrence: Int
    ) {
        self.executablePath = executablePath
        self.processID = processID
        self.legacyOccurrence = legacyOccurrence
    }

    var name: String {
        executablePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? executablePath
    }

    var isSystemProcess: Bool {
        let systemProcesses = [
            "conhost.exe", "explorer.exe", "msiexec.exe", "plugplay.exe",
            "rpcss.exe", "rundll32.exe", "services.exe", "start.exe",
            "svchost.exe", "taskkill.exe", "wineboot.exe", "wineconsole.exe",
            "winedevice.exe", "winemenubuilder.exe", "wmic.exe",
        ]
        return systemProcesses.contains(name.lowercased())
    }

    var kind: String {
        isSystemProcess
            ? String(localized: "System", bundle: SwitchyardStrings.bundle)
            : String(localized: "Application", bundle: SwitchyardStrings.bundle)
    }

    fileprivate func assigningLegacyOccurrence(
        _ occurrence: Int
    ) -> WindowsProcessSnapshot {
        guard processID == nil else {
            return self
        }
        return WindowsProcessSnapshot(
            executablePath: executablePath,
            processID: nil,
            legacyOccurrence: occurrence
        )
    }

    private var legacyProcessID: String {
        let normalizedPath = executablePath.lowercased()
        return "path:\(normalizedPath.utf8.count):\(normalizedPath):\(legacyOccurrence)"
    }

    static func == (
        lhs: WindowsProcessSnapshot,
        rhs: WindowsProcessSnapshot
    ) -> Bool {
        lhs.executablePath == rhs.executablePath
            && lhs.processID == rhs.processID
    }
}

struct ContainerSessionSnapshot: Equatable, Sendable {
    var wineServerState: WineServerState
    var processes: [WindowsProcessSnapshot]
    var hostProcessIDs: Set<Int32> = []
    var refreshedAt: Date?
    var message: String?

    init(
        wineServerState: WineServerState,
        processes: [WindowsProcessSnapshot],
        hostProcessIDs: Set<Int32> = [],
        refreshedAt: Date? = nil,
        message: String? = nil
    ) {
        self.wineServerState = wineServerState
        self.processes = Self.assigningLegacyOccurrences(in: processes)
        self.hostProcessIDs = hostProcessIDs
        self.refreshedAt = refreshedAt
        self.message = message
    }

    static let checking = ContainerSessionSnapshot(
        wineServerState: .checking,
        processes: [],
        hostProcessIDs: [],
        refreshedAt: nil,
        message: nil
    )

    func hasSamePublishedMeaning(
        as other: ContainerSessionSnapshot
    ) -> Bool {
        wineServerState == other.wineServerState
            && processes == other.processes
            && hostProcessIDs == other.hostProcessIDs
            && message == other.message
    }

    private static func assigningLegacyOccurrences(
        in processes: [WindowsProcessSnapshot]
    ) -> [WindowsProcessSnapshot] {
        var occurrencesByPath: [String: Int] = [:]
        return processes.map { process in
            guard process.processID == nil else {
                return process
            }
            let pathKey = process.executablePath.lowercased()
            let occurrence = occurrencesByPath[pathKey, default: 0]
            occurrencesByPath[pathKey] = occurrence + 1
            return process.assigningLegacyOccurrence(occurrence)
        }
    }
}
