import XCTest
@testable import SwitchyardLocalization

final class SwitchyardLocalizationTests: XCTestCase {
    func testSupportedLocalesAreAvailableInTheResourceBundle() {
        XCTAssertEqual(
            Set(L10n.bundle.localizations.map {
                Locale.identifier(.bcp47, from: $0)
            }),
            Set(L10n.supportedLocaleIdentifiers.map {
                Locale.identifier(.bcp47, from: $0)
            })
        )
        XCTAssertEqual(L10n.bundle.developmentLocalization, "en")
    }

    func testEverySupportedLocaleTranslatesRepresentativeInterfaceText() {
        for localeIdentifier in L10n.supportedLocaleIdentifiers where localeIdentifier != "en" {
            XCTAssertNotEqual(
                L10n.string(forKey: "Add Container", localeIdentifier: localeIdentifier),
                "Add Container",
                "Expected Add Container to be translated for \(localeIdentifier)"
            )
        }
    }

    func testContextSensitiveTermsUseInterfaceMeanings() {
        let expectedTranslations = [
            "ko": [
                "Running": "실행 중",
                "Missing": "누락",
                "Open": "열기",
                "Copy Redacted": "민감 정보 가리고 복사"
            ],
            "zh-Hans": [
                "Running": "运行中",
                "Missing": "缺失",
                "Open": "打开",
                "Copy Redacted": "隐去敏感信息后复制"
            ],
            "zh-Hant": [
                "Running": "執行中",
                "Missing": "缺少",
                "Open": "打開",
                "Copy Redacted": "隱藏敏感資訊後複製"
            ],
            "ja": [
                "Running": "実行中",
                "Missing": "不足",
                "Open": "開く",
                "Copy Redacted": "機密情報を伏せてコピー"
            ],
            "ru": [
                "Running": "Выполняется",
                "Missing": "Отсутствует",
                "Open": "Открыть",
                "Copy Redacted": "Копировать с маскированием данных"
            ],
            "de": [
                "Running": "Wird ausgeführt",
                "Missing": "Fehlt",
                "Open": "Öffnen",
                "Copy Redacted": "Geschwärzt kopieren"
            ],
            "fr": [
                "Running": "En cours d’exécution",
                "Missing": "Manquant",
                "Open": "Ouvrir",
                "Copy Redacted": "Copier en masquant les données sensibles"
            ],
            "es": [
                "Running": "En ejecución",
                "Missing": "Falta",
                "Open": "Abrir",
                "Copy Redacted": "Copiar con datos sensibles ocultos"
            ],
            "pt-BR": [
                "Running": "Em execução",
                "Missing": "Ausente",
                "Open": "Abrir",
                "Copy Redacted": "Copiar com dados sensíveis ocultos"
            ]
        ]

        for (localeIdentifier, translations) in expectedTranslations {
            for (key, expectedValue) in translations {
                XCTAssertEqual(
                    L10n.string(forKey: key, localeIdentifier: localeIdentifier),
                    expectedValue,
                    "\(key) must use its interface meaning in \(localeIdentifier)"
                )
            }
        }
    }

    func testEnglishFallsBackToTheSourceText() {
        XCTAssertEqual(
            L10n.string(forKey: "Add Container", localeIdentifier: "en"),
            "Add Container"
        )
    }
}
