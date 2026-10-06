import Foundation

/// Lingua dell'interfaccia. Scelta dal menu; "automatica" segue macOS sul Mac e il browser
/// su ogni tablet. Le lingue non supportate ricadono sull'inglese.
enum Language: String, CaseIterable {
    case it, en

    private static let defaultsKey = "language"

    /// Scelta dell'utente; nil = automatica.
    static var preference: Language? {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Language.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: defaultsKey) }
    }

    /// Lingua del Mac (menu, finestre, pannelli).
    static var current: Language { preference ?? from(Locale.preferredLanguages) }

    /// Lingua della pagina per un tablet, dall'header Accept-Language del suo browser.
    static func forWeb(acceptLanguage: String?) -> Language {
        if let preference { return preference }
        let codes = (acceptLanguage ?? "").split(separator: ",").map {
            $0.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return from(codes)
    }

    /// La prima lingua supportata nell'elenco, in ordine di preferenza.
    static func from(_ codes: [String]) -> Language {
        for code in codes {
            let c = code.lowercased()
            if c.hasPrefix("it") { return .it }
            if c.hasPrefix("en") { return .en }
        }
        return .en
    }

    func t(_ it: String, _ en: String) -> String { self == .it ? it : en }
}

/// Testo nella lingua del Mac.
func tr(_ it: String, _ en: String) -> String { Language.current.t(it, en) }
