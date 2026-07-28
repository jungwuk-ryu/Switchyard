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
            ?? "path:\(executablePath.lowercased())"
    }
    let executablePath: String
    let processID: UInt32?

    init(executablePath: String, processID: UInt32? = nil) {
        self.executablePath = executablePath
        self.processID = processID
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
}

struct ContainerSessionSnapshot: Equatable, Sendable {
    var wineServerState: WineServerState
    var processes: [WindowsProcessSnapshot]
    var refreshedAt: Date?
    var message: String?

    static let checking = ContainerSessionSnapshot(
        wineServerState: .checking,
        processes: [],
        refreshedAt: nil,
        message: nil
    )
}
