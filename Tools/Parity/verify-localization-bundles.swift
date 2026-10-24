import Foundation

@main
struct VerifyLocalizationBundles {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("Uso: verify-localization-bundles <AnkiOS.app> <Localizable.xcstrings>\n".utf8))
            exit(2)
        }

        let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let appBundle = Bundle(url: appURL) else {
            throw NSError(domain: "VerifyLocalizationBundles", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundle do app inválido"])
        }

        let catalogURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try JSONSerialization.jsonObject(with: catalogData) as! [String: Any]
        let strings = catalog["strings"] as! [String: [String: Any]]
        var checked = 0
        var pluralsChecked = 0
        let sampleCounts = [0, 1, 2, 3, 4, 5, 11, 21, 22, 25]
        let languages = AnkiLanguageCatalog.languages

        for language in languages {
            let bundleLocale = language.locale.identifier
            guard AnkiLanguageCatalog.systemLanguageCode(for: bundleLocale) == language.code else {
                throw NSError(
                    domain: "VerifyLocalizationBundles",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Locale não normalizado para \(language.code) (\(bundleLocale))"]
                )
            }
            guard appBundle.url(forResource: bundleLocale, withExtension: "lproj") != nil else {
                throw NSError(
                    domain: "VerifyLocalizationBundles",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Bundle ausente para \(language.code) (\(bundleLocale))"]
                )
            }

            for (key, entry) in strings {
                let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
                if localizations[bundleLocale]?["variations"] is [String: Any] {
                    continue
                }
                let unit = localizations[bundleLocale]? ["stringUnit"] as? [String: Any]
                let expected = unit?["state"] as? String == "translated"
                    ? unit?["value"] as? String ?? key
                    : key
                let actual = AnkiLanguageCatalog.localizedString(key, for: language.code, in: appBundle)
                guard actual == expected else {
                    throw NSError(
                        domain: "VerifyLocalizationBundles",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "\(language.code) / \(key): esperado=\(expected), obtido=\(actual)"]
                    )
                }
                checked += 1
            }

            for count in sampleCounts {
                let cards = AnkiLanguageCatalog.localizedPluralSuffix(
                    "\(count) custom-study.cards",
                    locale: language.locale,
                    in: appBundle
                )
                let days = AnkiLanguageCatalog.localizedPluralSuffix(
                    "\(count) custom-study.days",
                    locale: language.locale,
                    in: appBundle
                )
                let cardsFromDeck = AnkiLanguageCatalog.localizedPluralSuffix(
                    "\(count) custom-study.cards-from-the-deck",
                    locale: language.locale,
                    in: appBundle
                )
                for (key, value) in [
                    ("custom-study.cards", cards),
                    ("custom-study.days", days),
                    ("custom-study.cards-from-the-deck", cardsFromDeck),
                ] {
                    guard !value.isEmpty, !value.contains("\u{2063}"), !value.contains(key) else {
                        throw NSError(
                            domain: "VerifyLocalizationBundles",
                            code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "Forma plural inválida para \(language.code), \(count), \(key): \(value)"]
                        )
                    }
                    pluralsChecked += 1
                }

                if language.code == "ru_RU", count == 2, days != "дня" {
                    throw NSError(domain: "VerifyLocalizationBundles", code: 6, userInfo: [NSLocalizedDescriptionKey: "Plural russo de 2 dias incorreto: \(days)"])
                }
                if language.code == "ru_RU", count == 5, days != "дней" {
                    throw NSError(domain: "VerifyLocalizationBundles", code: 7, userInfo: [NSLocalizedDescriptionKey: "Plural russo de 5 dias incorreto: \(days)"])
                }
                if language.code == "pl_PL", count == 2, days != "dni" {
                    throw NSError(domain: "VerifyLocalizationBundles", code: 8, userInfo: [NSLocalizedDescriptionKey: "Plural polonês de 2 dias incorreto: \(days)"])
                }
                if language.code == "en_US", count == 1, days != "day" {
                    throw NSError(domain: "VerifyLocalizationBundles", code: 9, userInfo: [NSLocalizedDescriptionKey: "Plural inglês singular incorreto: \(days)"])
                }
                if language.code == "en_US", count == 2, days != "days" {
                    throw NSError(domain: "VerifyLocalizationBundles", code: 10, userInfo: [NSLocalizedDescriptionKey: "Plural inglês não singular incorreto: \(days)"])
                }
            }
            checked += 3
        }

        print("\(checked) combinações chave/idioma verificadas em \(languages.count) idiomas, incluindo \(pluralsChecked) renderizações plurais")
    }
}
