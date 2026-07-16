import AppCore
import Foundation

struct RecentInstalledProgram: Identifiable, Equatable, Sendable {
    var id: String { program.id }
    let program: InstalledProgram
    let launchedAt: Date

    var relativeLaunchDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: launchedAt, relativeTo: Date())
    }
}
