import Foundation

public enum L10n {
    public static let supportedLocaleIdentifiers = [
        "en",
        "ko",
        "zh-Hans",
        "zh-Hant",
        "ja",
        "ru",
        "de",
        "fr",
        "es",
        "pt-BR"
    ]

    public static let bundle: Bundle = {
        let bundleName = "Switchyard_SwitchyardLocalization.bundle"
        if let resourcesURL = Bundle.main.resourceURL,
           let installedBundle = Bundle(
               url: resourcesURL.appendingPathComponent(bundleName, isDirectory: true)
           ) {
            return installedBundle
        }
        if let adjacentBundle = Bundle(
            url: Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true)
        ) {
            return adjacentBundle
        }
        return .module
    }()

    public static func string(
        forKey key: String,
        localeIdentifier: String? = nil
    ) -> String {
        let localizationBundle: Bundle
        if let localeIdentifier,
           let bundledIdentifier = bundle.localizations.first(where: {
               Locale.identifier(.bcp47, from: $0)
                   == Locale.identifier(.bcp47, from: localeIdentifier)
           }),
           let localizedPath = bundle.path(
               forResource: bundledIdentifier,
               ofType: "lproj"
           ),
           let localizedBundle = Bundle(path: localizedPath) {
            localizationBundle = localizedBundle
        } else {
            localizationBundle = bundle
        }
        return localizationBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }
}
