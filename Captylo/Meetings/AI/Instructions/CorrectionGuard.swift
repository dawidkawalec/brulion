import Foundation

/// The strict check of an AI-fixed transcript line from the small correction model, next to
/// `MeetingCorrectionPrompt.accepts` (which only compares lengths): word by word, the fixed
/// line may differ from the original only in punctuation, letter case, Polish letters added
/// ("prosze" -> "proszę", never "ł" -> "l"), words joined ("w tedy" -> "wtedy") or the glossary
/// spelling of up to three words that sound like it ("bram tek" -> "BramTech", not "kasą" ->
/// "Kasa Plus"). Any other word change is refused: in trials Bielik 1.5B swapped correct words
/// ("czat" -> "Czas"), split names ("Kasa" -> "Kas a"), dropped Polish letters, changed tenses
/// and typed typos into clean lines, all within the length check.
enum CorrectionGuard {
    /// Original words a glossary spelling may replace.
    static let maxGlossaryWords = 3

    static func isSafe(original: String, fixed: String, glossary: [String]) -> Bool {
        let before = tokens(original)
        let fixedTokens = tokens(fixed)
        guard !fixedTokens.isEmpty else { return false }
        let termWords = glossary.map { tokens($0).map(\.folded) }.filter { !$0.isEmpty }
        let terms = Set(termWords.map { $0.joined() })
        // A glossary term of several words ("Agnieszka Mazur"), spelled as in the glossary,
        // counts as one word.
        let after = joiningTerms(fixedTokens, terms: termWords.filter { $0.count > 1 })
        let (pairs, hunks) = align(before, after)
        for (old, new) in pairs where !keepsPolishLetters(old.plain, new.plain) {
            return false
        }
        for hunk in hunks {
            let removed = hunk.removed.map(\.folded).joined()
            let added = hunk.added.map(\.folded).joined()
            // Words split by mistake, joined ("w tedy" -> "wtedy"); never a word split in two.
            if !removed.isEmpty, removed == added, hunk.added.count < hunk.removed.count,
               keepsPolishLetters(hunk.removed.map(\.plain).joined(), hunk.added.map(\.plain).joined()) {
                continue
            }
            // A glossary spelling, as one term, for a few misheard words that sound like it.
            if hunk.added.count == 1, terms.contains(added), !hunk.removed.isEmpty,
               hunk.removed.count <= maxGlossaryWords, distance(removed, added) * 2 < added.count {
                continue
            }
            return false
        }
        return true
    }

    // MARK: Pieces

    /// One word: lowercase letters and digits as written (`plain`) and without diacritics (`folded`).
    struct Token: Equatable {
        let plain: String
        let folded: String
    }

    /// A run where the two word lists differ.
    private struct Hunk {
        var removed: [Token] = []
        var added: [Token] = []
    }

    /// The folded words of `text`.
    static func words(_ text: String) -> [String] {
        tokens(text).map(\.folded)
    }

    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let plain = String(String(raw).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            return plain.isEmpty ? nil : Token(plain: plain, folded: fold(plain))
        }
    }

    /// Lowercase, no diacritics ("ł" too), letters and digits only (spaces dropped).
    static func fold(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pl_PL"))
            .lowercased()
            .replacingOccurrences(of: "ł", with: "l")
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Two spellings of the same folded word: every letter the same, or a plain letter of the
    /// original given its Polish form ("e" -> "ę"); a Polish letter never loses its mark.
    static func keepsPolishLetters(_ original: String, _ fixed: String) -> Bool {
        let old = Array(original)
        let new = Array(fixed)
        guard old.count == new.count else { return fold(original) == fold(fixed) && original == fixed }
        for (a, b) in zip(old, new) where a != b {
            guard a.isASCII, fold(String(a)) == fold(String(b)) else { return false }
        }
        return true
    }

    /// Edit distance (insertions, deletions, substitutions) between two folded words.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// `tokens` with each run that is exactly the words of a glossary term joined into that one
    /// term (longest term first).
    private static func joiningTerms(_ tokens: [Token], terms: [[String]]) -> [Token] {
        let longestFirst = terms.sorted { $0.count > $1.count }
        var result: [Token] = []
        var index = 0
        while index < tokens.count {
            let match = longestFirst.first { term in
                index + term.count <= tokens.count && tokens[index..<index + term.count].map(\.folded) == term
            }
            if let term = match {
                let run = tokens[index..<index + term.count]
                result.append(Token(plain: run.map(\.plain).joined(), folded: term.joined()))
                index += term.count
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }

    /// The words matched by folded form (pairs) and the differing runs between them, from the
    /// longest common subsequence of the folded words.
    private static func align(_ a: [Token], _ b: [Token]) -> (pairs: [(Token, Token)], hunks: [Hunk]) {
        let n = a.count
        let m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].folded == b[j].folded ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [(Token, Token)] = []
        var hunks: [Hunk] = []
        var current = Hunk()
        var i = 0
        var j = 0
        func flush() {
            if !current.removed.isEmpty || !current.added.isEmpty {
                hunks.append(current)
                current = Hunk()
            }
        }
        while i < n || j < m {
            if i < n, j < m, a[i].folded == b[j].folded {
                flush()
                pairs.append((a[i], b[j]))
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                current.added.append(b[j])
                j += 1
            } else {
                current.removed.append(a[i])
                i += 1
            }
        }
        flush()
        return (pairs, hunks)
    }
}
