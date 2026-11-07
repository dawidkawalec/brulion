import AppKit

/// The spell check `CorrectionMerger` needs, from the system dictionaries (Polish and
/// English). `NSSpellChecker` is asked on the main actor once per answer for the words of the
/// model's output; the merger then gets a plain, deterministic lookup:
///
///     let known = await CorrectionSpelling.knownWords(in: output)
///     let outcome = CorrectionGuard.apply(raw: raw, output: output, vocabulary: terms,
///                                         spellCheck: CorrectionSpelling.lookup(known))
enum CorrectionSpelling {
    /// Lowercased words of `text` the system spell checker accepts in Polish or English.
    /// Without either dictionary every word counts as known (like the app's `WordChecker`).
    @MainActor
    static func knownWords(in text: String) -> Set<String> {
        let checker = NSSpellChecker.shared
        let available = Set(checker.availableLanguages)
        let languages = ["pl", "en"].filter(available.contains)
        var known = Set<String>()
        for token in CorrectionMerger.tokenize(text) where token.core.contains(where: \.isLetter) {
            let word = token.core
            let correct = languages.isEmpty || languages.contains { language in
                checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                    .location == NSNotFound
            }
            if correct { known.insert(word.lowercased()) }
        }
        return known
    }

    /// A spell check that answers from `known` (case-insensitive).
    static func lookup(_ known: Set<String>) -> CorrectionMerger.SpellCheck {
        { known.contains($0.lowercased()) }
    }
}
