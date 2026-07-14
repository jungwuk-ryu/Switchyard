import AppCore
import Foundation
import SwiftUI

extension HealthStatus {
    var label: String {
        switch self {
        case .ok: "OK"
        case .warning: "Warning"
        case .missing: "Missing"
        case .unsupported: "Unsupported"
        case .unknown: "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .missing: "xmark.circle.fill"
        case .unsupported: "nosign"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ok: .green
        case .warning: .yellow
        case .missing, .unsupported: .red
        case .unknown: .secondary
        }
    }
}

extension ContainerStatus {
    var label: String {
        switch self {
        case .ready: "Ready"
        case .needsSetup: "Needs Setup"
        case .queued: "Queued"
        case .running: "Running"
        case .failed: "Failed"
        case .succeeded: "Succeeded"
        }
    }

    var health: HealthStatus {
        switch self {
        case .ready, .succeeded: .ok
        case .needsSetup, .queued, .running: .warning
        case .failed: .missing
        }
    }
}

let switchyardDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()
