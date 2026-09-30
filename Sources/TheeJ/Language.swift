import Foundation

/// The languages the app speaks, in the website's order.
enum Language: String, CaseIterable {
    case de, en, es, fr, it, pl, pt, ru, uk, zh, ja, ko

    var name: String {
        switch self {
        case .de: "Deutsch"
        case .en: "English"
        case .es: "Español"
        case .fr: "Français"
        case .it: "Italiano"
        case .pl: "Polski"
        case .pt: "Português"
        case .ru: "Русский"
        case .uk: "Українська"
        case .zh: "中文"
        case .ja: "日本語"
        case .ko: "한국어"
        }
    }

    /// An emoji, not a drawn flag. Portuguese shows Brazil's.
    var flag: String {
        switch self {
        case .de: "🇩🇪"
        case .en: "🇬🇧"
        case .es: "🇪🇸"
        case .fr: "🇫🇷"
        case .it: "🇮🇹"
        case .pl: "🇵🇱"
        case .pt: "🇧🇷"
        case .ru: "🇷🇺"
        case .uk: "🇺🇦"
        case .zh: "🇨🇳"
        case .ja: "🇯🇵"
        case .ko: "🇰🇷"
        }
    }

    /// The one picked in the menu or in Settings, else the Mac's.
    static var current: Language {
        UserDefaults.standard.string(forKey: "language").flatMap(Language.init) ?? system
    }

    /// The first of the Mac's preferred languages the app speaks, else English.
    static var system: Language {
        Locale.preferredLanguages.lazy.compactMap { Language(rawValue: String($0.prefix(2)).lowercased()) }.first ?? .en
    }
}

/// Every string the app shows, by language and then by key. A key ending in .one, .few, .many or
/// .other is a plural form. Each language's table is in Strings/.
enum Strings {
    static let all: [Language: [String: String]] = [.de: de, .en: en, .es: es, .fr: fr, .it: it, .pl: pl,
                                                    .pt: pt, .ru: ru, .uk: uk, .zh: zh, .ja: ja, .ko: ko]
}

/// The string for `key` in the current language, English if that language lacks it, with each {name} filled in.
func tr(_ key: String, _ values: [String: Any] = [:], in language: Language = .current) -> String {
    var text = Strings.all[language]?[key] ?? Strings.en[key] ?? key
    for (name, value) in values { text = text.replacingOccurrences(of: "{\(name)}", with: "\(value)") }
    return text
}

/// "{n} minutes" in the form the language uses for `n`. Polish, Russian and Ukrainian have a few and
/// a many form, French counts 0 as one, and Chinese, Japanese and Korean have a single form.
func plural(_ key: String, _ n: Int, in language: Language = .current) -> String {
    let one = n % 10 == 1 && n % 100 != 11
    let few = (2...4).contains(n % 10) && !(12...14).contains(n % 100)
    let form = switch language {
    case .zh, .ja, .ko: "other"
    case .fr: n < 2 ? "one" : "other"
    case .pl: n == 1 ? "one" : few ? "few" : "many"
    case .ru, .uk: one ? "one" : few ? "few" : "many"
    default: n == 1 ? "one" : "other"
    }
    let table = Strings.all[language] ?? Strings.en
    return tr(table["\(key).\(form)"] == nil ? "\(key).other" : "\(key).\(form)", ["n": n], in: language)
}
