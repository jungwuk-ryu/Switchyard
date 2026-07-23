import AppCore
import Foundation
import SwiftUI

extension HealthStatus {
    var label: String {
        switch self {
        case .ok:
            String(localized: "OK", bundle: SwitchyardStrings.bundle)
        case .warning:
            String(localized: "Warning", bundle: SwitchyardStrings.bundle)
        case .missing:
            String(localized: "Missing", bundle: SwitchyardStrings.bundle)
        case .unsupported:
            String(localized: "Unsupported", bundle: SwitchyardStrings.bundle)
        case .unknown:
            String(localized: "Unknown", bundle: SwitchyardStrings.bundle)
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
        case .ready:
            String(localized: "Ready", bundle: SwitchyardStrings.bundle)
        case .needsSetup:
            String(localized: "Needs Setup", bundle: SwitchyardStrings.bundle)
        case .queued:
            String(localized: "Queued", bundle: SwitchyardStrings.bundle)
        case .running:
            String(localized: "Running", bundle: SwitchyardStrings.bundle)
        case .failed:
            String(localized: "Failed", bundle: SwitchyardStrings.bundle)
        case .succeeded:
            String(localized: "Succeeded", bundle: SwitchyardStrings.bundle)
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
