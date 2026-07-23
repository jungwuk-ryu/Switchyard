import AppKit
import Foundation

struct AppLanguageOption: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum AppLanguagePreference {
    static let systemIdentifier = "system"
    static let storageKey = "switchyardAppLanguage"
    static let appleLanguagesKey = "AppleLanguages"

    static let options = [
        AppLanguageOption(id: "en", displayName: "English"),
        AppLanguageOption(id: "ko", displayName: "한국어"),
        AppLanguageOption(id: "zh-Hans", displayName: "简体中文"),
        AppLanguageOption(id: "zh-Hant", displayName: "繁體中文"),
        AppLanguageOption(id: "ja", displayName: "日本語"),
        AppLanguageOption(id: "ru", displayName: "Русский"),
        AppLanguageOption(id: "de", displayName: "Deutsch"),
        AppLanguageOption(id: "fr", displayName: "Français"),
        AppLanguageOption(id: "es", displayName: "Español"),
        AppLanguageOption(id: "pt-BR", displayName: "Português (Brasil)")
    ]

    static let selectionAtLaunch = selectedIdentifier()

    static func selectedIdentifier(
        defaults: UserDefaults = .standard
    ) -> String {
        guard let identifier = defaults.string(forKey: storageKey),
              identifier == systemIdentifier
                || options.contains(where: { $0.id == identifier }) else {
            return systemIdentifier
        }
        return identifier
    }

    static func apply(
        _ identifier: String,
        defaults: UserDefaults = .standard
    ) {
        let normalizedIdentifier = identifier == systemIdentifier
            || options.contains(where: { $0.id == identifier })
            ? identifier
            : systemIdentifier

        defaults.set(normalizedIdentifier, forKey: storageKey)
        if normalizedIdentifier == systemIdentifier {
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([normalizedIdentifier], forKey: appleLanguagesKey)
        }
        defaults.synchronize()
    }

    @MainActor
    static func restartApplication() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        NSApplication.shared.terminate(nil)
    }
}
