import Foundation

enum WineServerState: Equatable, Sendable {
    case checking
    case active
    case inactive
    case unavailable
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

    var kind: String {
        let systemProcesses = [
            "explorer.exe", "services.exe", "rpcss.exe", "plugplay.exe",
            "svchost.exe", "winedevice.exe", "wineboot.exe",
        ]
        return systemProcesses.contains(name.lowercased()) ? "System" : "Application"
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
