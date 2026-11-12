import Foundation

enum AppText {
    nonisolated(unsafe) static var locale: Locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    static var formattingLocale: Locale { .current }

    static func text(_ value: String.LocalizationValue, in locale: Locale? = nil) -> String {
        let locale = locale ?? AppText.locale
        guard let table = table(for: locale) else {
            return String(localized: value, bundle: .main, locale: locale)
        }
        return String(localized: value, bundle: table, locale: locale)
    }

    private static func table(for locale: Locale) -> Bundle? {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = locale.language.languageCode?.identifier
        return tables.withLock { cache in
            if let cached = cache[identifier] { return cached }
            let available = Bundle.main.localizations
            let match = available.first { $0.caseInsensitiveCompare(identifier) == .orderedSame }
                ?? available.first { sameLanguageAndScript($0, locale) }
                ?? available.first { Locale(identifier: $0).language.languageCode?.identifier == language }
            let bundle = match.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:))
            cache[identifier] = bundle
            return bundle
        }
    }

    private static let tables = NSLockedValue<[String: Bundle?]>([:])

    static func sameLanguageAndScript(_ localization: String, _ locale: Locale) -> Bool {
        let a = Locale.Language(identifier: Locale.Language(identifier: localization).maximalIdentifier)
        let b = Locale.Language(identifier: locale.language.maximalIdentifier)
        return a.languageCode == b.languageCode && a.script == b.script
    }
}
