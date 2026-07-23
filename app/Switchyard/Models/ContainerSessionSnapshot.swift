import Foundation

enum WineServerState: Equatable, Sendable {
    case checking
    case active
    case orphaned
    case inactive
    case unavailable

    var hasRunningProcesses: Bool {
        self == .active || self == .orphaned
    }
}

struct WindowsProcessSnapshot: Identifiable, Equatable, Sendable {
    var id: String { executablePath }
    let executablePath: String

    var name: String {
        executablePath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? executablePath
    }

    var isSystemProcess: Bool {
        let systemProcesses = [
            "explorer.exe", "services.exe", "rpcss.exe", "plugplay.exe",
            "svchost.exe", "winedevice.exe", "wineboot.exe",
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
