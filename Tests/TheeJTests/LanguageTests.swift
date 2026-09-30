import Foundation
import Testing
@testable import TheeJ

/// "knobs_found.one" and "knobs_found.few" are forms of "knobs_found".
private func base(_ key: String) -> String {
    let parts = key.split(separator: ".")
    return ["one", "few", "many", "other"].contains(String(parts.last ?? "")) ? parts.dropLast().joined(separator: ".") : key
}

private func placeholders(_ text: String) -> Set<String> {
    Set(text.matches(of: #/\{[a-z]+\}/#).map { String($0.output) })
}

@Test func everyLanguageHasEveryString() {
    let english = Set(Strings.en.keys.map(base))
    for language in Language.allCases {
        let keys = Set((Strings.all[language] ?? [:]).keys.map(base))
        #expect(keys == english, "\(language.rawValue): \(keys.symmetricDifference(english).sorted())")
    }
}

// A translation that drops or misspells {letter} would show the braces, or lose the knob.
@Test func everyTranslationKeepsItsPlaceholders() {
    for language in Language.allCases {
        for (key, text) in Strings.all[language] ?? [:] {
            let english = Strings.en[key] ?? Strings.en[base(key) + ".other"] ?? ""
            #expect(placeholders(text) == placeholders(english), "\(language.rawValue) \(key): \(text)")
        }
    }
}

// A knob's popup lists its jobs under section headers by their short names, which must still tell them apart.
@Test func jobNamesStayApartInEveryLanguage() {
    for language in Language.allCases {
        let short = ["short.builtin_display", "short.screen", "short.warmth", "short.builtin", "short.external"]
        let names = short.map { tr($0, ["n": 1], in: language) } + ["job.master", "job.microphone"].map { tr($0, in: language) }
        #expect(Set(names).count == names.count, "\(language.rawValue): \(names)")
    }
}

@Test func pluralForms() {
    #expect(plural("seconds_left", 1, in: .en) == "1 second left" && plural("seconds_left", 20, in: .en) == "20 seconds left")
    #expect([1, 3, 5, 21].map { plural("knobs_found", $0, in: .ru) } == ["Найдена 1 ручка", "Найдено 3 ручки", "Найдено 5 ручек", "Найдена 21 ручка"])
    #expect([1, 2, 5, 22].map { plural("seconds_left", $0, in: .pl) } == ["Została 1 sekunda", "Zostały 2 sekundy", "Zostało 5 sekund", "Zostały 22 sekundy"])
    #expect(plural("knobs_found", 1, in: .ja) == "1 個のノブが見つかりました")
}

@Test func everyLanguageHasANameAndAFlag() {
    #expect(Language.allCases.count == 12)
    #expect(Set(Language.allCases.map(\.name)).count == 12 && Set(Language.allCases.map(\.flag)).count == 12)
    #expect(Language.pt.flag == "🇧🇷")
}
