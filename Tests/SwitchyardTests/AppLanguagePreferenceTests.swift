import Foundation
import Testing
@testable import Switchyard

@Test func appLanguagePreferencePersistsManualAndSystemSelections() throws {
    let suiteName = "AppLanguagePreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    AppLanguagePreference.apply("ko", defaults: defaults)
    #expect(AppLanguagePreference.selectedIdentifier(defaults: defaults) == "ko")
    #expect(
        defaults.stringArray(
            forKey: AppLanguagePreference.appleLanguagesKey
        ) == ["ko"]
    )

    AppLanguagePreference.apply(
        AppLanguagePreference.systemIdentifier,
        defaults: defaults
    )
    #expect(
        AppLanguagePreference.selectedIdentifier(defaults: defaults)
            == AppLanguagePreference.systemIdentifier
    )
    #expect(
        defaults.persistentDomain(forName: suiteName)?[
            AppLanguagePreference.appleLanguagesKey
        ] == nil
    )
}

@Test func appLanguagePreferenceRejectsUnsupportedIdentifiers() throws {
    let suiteName = "AppLanguagePreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    AppLanguagePreference.apply("unsupported", defaults: defaults)

    #expect(
        AppLanguagePreference.selectedIdentifier(defaults: defaults)
            == AppLanguagePreference.systemIdentifier
    )
    #expect(
        defaults.persistentDomain(forName: suiteName)?[
            AppLanguagePreference.appleLanguagesKey
        ] == nil
    )
}
