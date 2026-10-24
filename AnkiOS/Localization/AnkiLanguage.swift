import Foundation

struct AnkiLanguage: Identifiable, Equatable, Sendable {
    let name: String
    let code: String

    var id: String { code }
    var isRightToLeft: Bool {
        ["ar", "fa", "he", "ug", "yi"].contains(code.split(separator: "_").first.map(String.init) ?? code)
    }

    var locale: Locale {
        Locale(identifier: code == "tl" ? "fil" : code.replacingOccurrences(of: "_", with: "-"))
    }
}

enum AnkiLanguageCatalog {
    static let preferenceKey = "ankios.language"

    static let languages: [AnkiLanguage] = {
        var languages = [
            AnkiLanguage(name: "Afrikaans", code: "af_ZA"),
            AnkiLanguage(name: "Bahasa Melayu", code: "ms_MY"),
            AnkiLanguage(name: "Català", code: "ca_ES"),
            AnkiLanguage(name: "Dansk", code: "da_DK"),
            AnkiLanguage(name: "Deutsch", code: "de_DE"),
            AnkiLanguage(name: "Eesti", code: "et_EE"),
            AnkiLanguage(name: "English (United States)", code: "en_US"),
            AnkiLanguage(name: "English (United Kingdom)", code: "en_GB"),
            AnkiLanguage(name: "Español", code: "es_ES"),
            AnkiLanguage(name: "Esperanto", code: "eo_UY"),
            AnkiLanguage(name: "Euskara", code: "eu_ES"),
            AnkiLanguage(name: "Français", code: "fr_FR"),
            AnkiLanguage(name: "Galego", code: "gl_ES"),
            AnkiLanguage(name: "Hrvatski", code: "hr_HR"),
            AnkiLanguage(name: "Italiano", code: "it_IT"),
            AnkiLanguage(name: "lo jbobau", code: "jbo_EN"),
            AnkiLanguage(name: "Lenga d'òc", code: "oc_FR"),
            AnkiLanguage(name: "Қазақша", code: "kk_KZ"),
            AnkiLanguage(name: "Magyar", code: "hu_HU"),
            AnkiLanguage(name: "Nederlands", code: "nl_NL"),
            AnkiLanguage(name: "Norsk", code: "nb_NO"),
            AnkiLanguage(name: "Polski", code: "pl_PL"),
            AnkiLanguage(name: "Português Brasileiro", code: "pt_BR"),
            AnkiLanguage(name: "Português", code: "pt_PT"),
            AnkiLanguage(name: "Română", code: "ro_RO"),
            AnkiLanguage(name: "Slovenčina", code: "sk_SK"),
            AnkiLanguage(name: "Slovenščina", code: "sl_SI"),
            AnkiLanguage(name: "Suomi", code: "fi_FI"),
            AnkiLanguage(name: "Svenska", code: "sv_SE"),
            AnkiLanguage(name: "Tiếng Việt", code: "vi_VN"),
            AnkiLanguage(name: "Türkçe", code: "tr_TR"),
            AnkiLanguage(name: "简体中文", code: "zh_CN"),
            AnkiLanguage(name: "日本語", code: "ja_JP"),
            AnkiLanguage(name: "繁體中文", code: "zh_TW"),
            AnkiLanguage(name: "한국어", code: "ko_KR"),
            AnkiLanguage(name: "Čeština", code: "cs_CZ"),
            AnkiLanguage(name: "Ελληνικά", code: "el_GR"),
            AnkiLanguage(name: "Български", code: "bg_BG"),
            AnkiLanguage(name: "Монгол хэл", code: "mn_MN"),
            AnkiLanguage(name: "Pусский язык", code: "ru_RU"),
            AnkiLanguage(name: "Српски", code: "sr_SP"),
            AnkiLanguage(name: "Українська мова", code: "uk_UA"),
            AnkiLanguage(name: "Հայերեն", code: "hy_AM"),
            AnkiLanguage(name: "עִבְרִית", code: "he_IL"),
            AnkiLanguage(name: "ייִדיש", code: "yi"),
            AnkiLanguage(name: "العربية", code: "ar_SA"),
            AnkiLanguage(name: "فارسی", code: "fa_IR"),
            AnkiLanguage(name: "ภาษาไทย", code: "th_TH"),
            AnkiLanguage(name: "Latin", code: "la_LA"),
            AnkiLanguage(name: "Gaeilge", code: "ga_IE"),
            AnkiLanguage(name: "Беларуская мова", code: "be_BY"),
            AnkiLanguage(name: "ଓଡ଼ିଆ", code: "or_OR"),
            AnkiLanguage(name: "Filipino", code: "tl"),
            AnkiLanguage(name: "ئۇيغۇر", code: "ug"),
            AnkiLanguage(name: "Oʻzbekcha", code: "uz_UZ")
        ]
        #if os(iOS) || ANKIOS_IOS_LOCALIZATION_CHECK
        languages.append(AnkiLanguage(name: "മലയാളം", code: "ml_IN"))
        #endif
        return languages.sorted {
            Array($0.name.unicodeScalars).lexicographicallyPrecedes(Array($1.name.unicodeScalars))
        }
    }()

    private static let compatibilityCodes: [String: String] = [
        "af": "af_ZA", "ar": "ar_SA", "be": "be_BY", "bg": "bg_BG",
        "ca": "ca_ES", "cs": "cs_CZ", "da": "da_DK", "de": "de_DE",
        "el": "el_GR", "en": "en_US", "eo": "eo_UY", "es": "es_ES",
        "et": "et_EE", "eu": "eu_ES", "fa": "fa_IR", "fi": "fi_FI",
        "fil": "tl", "fr": "fr_FR", "gl": "gl_ES", "he": "he_IL", "hr": "hr_HR",
        "hu": "hu_HU", "hy": "hy_AM", "it": "it_IT", "ja": "ja_JP",
        "jbo": "jbo_EN", "kk": "kk_KZ", "ko": "ko_KR", "la": "la_LA",
        "ml": "ml_IN", "mn": "mn_MN", "ms": "ms_MY", "nl": "nl_NL", "nb": "nb_NL",
        "no": "nb_NL", "oc": "oc_FR", "or": "or_OR", "pl": "pl_PL",
        "pt": "pt_PT", "ru": "ru_RU", "ro": "ro_RO", "sk": "sk_SK",
        "sl": "sl_SI", "sr": "sr_SP", "sv": "sv_SE", "th": "th_TH",
        "tr": "tr_TR", "uk": "uk_UA", "uz": "uz_UZ", "vi": "vi_VN",
        "yi": "yi"
    ]

    static var defaultLanguageCode: String {
        #if os(iOS)
        let preferredLanguages = Locale.preferredLanguages
        #else
        let preferredLanguages: [String] = []
        #endif
        return defaultLanguageCode(
            environment: ProcessInfo.processInfo.environment,
            preferredLanguages: preferredLanguages
        )
    }

    static var appLanguageCode: String {
        #if os(iOS)
        if let code = Bundle.main.preferredLocalizations.first.flatMap(systemLanguageCode(for:)) {
            return code
        }
        #endif
        return defaultLanguageCode
    }

    static func defaultLanguageCode(environment: [String: String], preferredLanguages: [String]) -> String {
        for key in ["LC_ALL", "LC_CTYPE", "LANG"] {
            guard let identifier = environment[key], !identifier.isEmpty else { continue }
            if let code = systemLanguageCode(for: identifier) { return code }
        }
        for identifier in preferredLanguages {
            if let code = systemLanguageCode(for: identifier) { return code }
        }
        return "en_US"
    }

    static func systemLanguageCode(for identifier: String) -> String? {
        let baseIdentifier = identifier
            .split(whereSeparator: { $0 == "." || $0 == "@" })
            .first
            .map(String.init) ?? identifier
        let normalized = baseIdentifier.replacingOccurrences(of: "-", with: "_")
        if let exact = normalizedCode(normalized) { return exact }

        let components = normalized.split(separator: "_")
        guard let language = components.first?.lowercased() else { return nil }
        if language == "zh" {
            let script = components.dropFirst().first(where: { $0.count == 4 })?.lowercased()
            let region = components.dropFirst().first(where: { $0.count == 2 })?.uppercased()
            if script == "hant" || ["HK", "MO", "TW"].contains(region) {
                return normalizedCode("zh_TW")
            }
            return normalizedCode("zh_CN")
        }
        return normalizedCode(language)
    }

    static func normalizedCode(_ rawValue: String) -> String? {
        let normalized = rawValue.replacingOccurrences(of: "-", with: "_")
        let candidate = compatibilityCodes[normalized.lowercased()] ?? normalized
        return languages.first { $0.code.caseInsensitiveCompare(candidate) == .orderedSame }?.code
    }

    static func language(for code: String) -> AnkiLanguage {
        let normalized = normalizedCode(code) ?? "en_US"
        return languages.first { $0.code == normalized } ?? languages.first { $0.code == "en_US" }!
    }

    static func localizedString(_ key: String, for code: String, in bundle: Bundle = .main) -> String {
        let locale = language(for: code).locale.identifier
        let localeBundle = bundle.url(forResource: locale, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? bundle
        return localeBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func localizedPluralSuffix(
        _ value: String.LocalizationValue,
        locale: Locale,
        in bundle: Bundle = .main
    ) -> String {
        let code = systemLanguageCode(for: locale.identifier) ?? "en_US"
        let selectedLocale = language(for: code).locale
        let localeBundle = bundle.url(forResource: selectedLocale.identifier, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? bundle
        let formatted = String(localized: value, table: "Localizable", bundle: localeBundle, locale: selectedLocale)
        guard let marker = formatted.range(of: "\u{2063}") else { return formatted }
        return String(formatted[marker.upperBound...])
    }
}
