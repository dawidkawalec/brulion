import Foundation

/// Decides what replaces the raw dictation after a local model's cleanup (PRD 7.2). A small
/// model sometimes answers the dictated question, translates it, cuts it, adds to it or
/// changes single words; `apply` first keeps only the model's safe word edits
/// (`CorrectionMerger`), then rejects the merged text when its length or word similarity
/// strays too far from the raw text, and the raw text is pasted instead. Pure.
enum CorrectionGuard {
    /// What `apply` decided.
    struct Outcome: Equatable, Sendable {
        /// What to paste: the merged correction, or the raw text when it was rejected.
        let text: String
        /// nil when the merged correction was accepted.
        let rejection: Rejection?
        /// The word-level merge (nil when the model answered nothing).
        let merge: CorrectionMerger.Merge?

        var isAccepted: Bool { rejection == nil }
    }

    /// The one entry point for a cleanup answer: merge the model's safe edits into the raw
    /// text, then check the merged text. `vocabulary` holds the user's terms (dictionary and
    /// learned forms); `spellCheck` answers whether a word is spelled right in Polish or
    /// English (`CorrectionSpelling.lookup`).
    static func apply(
        raw: String,
        output: String,
        vocabulary: Set<String> = [],
        spellCheck: CorrectionMerger.SpellCheck,
        thresholds: Thresholds = .standard
    ) -> Outcome {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(text: raw, rejection: .empty, merge: nil)
        }
        let merge = CorrectionMerger.merge(raw: raw, output: output, vocabulary: vocabulary, spellCheck: spellCheck)
        if let rejection = check(input: raw, output: merge.text, thresholds: thresholds) {
            return Outcome(text: raw, rejection: rejection, merge: merge)
        }
        return Outcome(text: merge.text, rejection: nil, merge: merge)
    }

    enum Rejection: Equatable, Sendable {
        case empty
        /// Output length / input length (characters) under the minimum.
        case tooShort(ratio: Double)
        /// Output length / input length over the maximum.
        case tooLong(ratio: Double)
        /// Word similarity under the threshold.
        case lowSimilarity(Double)

        /// Short stable name for counters and logs (never the text).
        var code: String {
            switch self {
            case .empty: "empty"
            case .tooShort: "tooShort"
            case .tooLong: "tooLong"
            case .lowSimilarity: "lowSimilarity"
            }
        }
    }

    struct Thresholds: Equatable, Sendable {
        var minimumLengthRatio = LocalAITuning.guardMinimumLengthRatio
        var maximumLengthRatio = LocalAITuning.guardMaximumLengthRatio
        /// The length check skips inputs this short (a few words may legitimately shrink a lot).
        var lengthCheckMinimumCharacters = LocalAITuning.guardLengthCheckMinimumCharacters
        var minimumSimilarity = LocalAITuning.guardMinimumSimilarity

        static let standard = Thresholds()
    }

    /// nil = accept the correction.
    static func check(input: String, output: String, thresholds: Thresholds = .standard) -> Rejection? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return .empty }

        if input.count > thresholds.lengthCheckMinimumCharacters {
            let ratio = Double(output.count) / Double(input.count)
            if ratio < thresholds.minimumLengthRatio { return .tooShort(ratio: ratio) }
            if ratio > thresholds.maximumLengthRatio { return .tooLong(ratio: ratio) }
        }

        let similarity = wordSimilarity(input, output)
        if similarity < thresholds.minimumSimilarity { return .lowSimilarity(similarity) }
        return nil
    }

    /// 1 - word edit distance / the larger word count, over lowercased words with punctuation
    /// stripped. 1 for identical word sequences (also two empty ones), 0 for nothing shared.
    static func wordSimilarity(_ a: String, _ b: String) -> Double {
        let left = words(a)
        let right = words(b)
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(left, right)) / Double(longest)
    }

    /// Lowercased runs of letters and digits; everything else separates words.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Levenshtein distance over words or characters (insert, delete, substitute = 1), two
    /// rows of memory.
    static func editDistance<Element: Equatable>(_ a: [Element], _ b: [Element]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
