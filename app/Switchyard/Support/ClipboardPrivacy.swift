import AppKit
import Foundation

enum PrivacyRedactor {
    static func redact(_ text: String) -> String {
        var redacted = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let patterns = [
            #"(?i)(token|password|secret|authorization)\s*[:=]\s*[^,\s}\]]+"#,
            #"(?i)(bearer)\s+[A-Za-z0-9._\-]+"#
        ]

        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "$1: [redacted]",
                options: [.regularExpression]
            )
        }
        return redacted
    }
}

enum ClipboardPrivacy {
    @MainActor
    static func confirmAndCopy(title: String, message: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Copy Redacted")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PrivacyRedactor.redact(text), forType: .string)
    }
}
