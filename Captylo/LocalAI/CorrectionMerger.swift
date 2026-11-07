import Foundation

/// Merges a small model's cleanup into the raw dictation word by word, keeping only edits
/// that cannot change the meaning (F0: the 1.5B changed the meaning in 8-15 % of dictations
/// even with a good prompt, "zrób" -> "zrobię", "wyciąć" -> "wyciszyć", "robiliśmy" ->
/// "robiłyśmy", summaries, loops; with this merge the meaning held in 60 of 60 samples).
///
/// Both texts are split into words with their glued punctuation and aligned on the
/// lowercased, punctuation-stripped words (difflib-style opcodes):
/// - equal: the model's token (its punctuation and capitals);
/// - replace of the same length (fillers aside): the model's words only when every pair is
///   safe (`isSafeReplacement`), else the raw words with their own punctuation;
/// - delete: accepted only for fillers and repeats of the word next to them;
/// - insert: dropped.
/// Next to a reverted block or a dropped insertion the model's punctuation is not trusted
/// (no "zadań. to do."), then the first letter and every sentence start get a capital.
/// Pure and nonisolated; the spell check comes in as a closure (`CorrectionSpelling`).
enum CorrectionMerger {
    struct Merge: Equatable, Sendable {
        let text: String
        /// Word changes taken from the model: safe replacements, removed fillers and repeats.
        let acceptedEdits: Int
        /// Raw words put back because the model's change was not safe.
        let revertedWords: Int
        /// Words the model added, left out.
        let droppedWords: Int
    }

    /// Whether a word is spelled correctly in Polish or English.
    typealias SpellCheck = @Sendable (String) -> Bool

    /// Removable when the model drops them.
    static let fillers: Set<String> = ["yyy", "yy", "eee", "ee", "mmm", "hmm", "hm", "um", "uh", "uhm", "eh"]
    /// Rule (c): a character similarity above this is a spelling fix, not another word.
    static let similarWordThreshold = 0.85
    /// Rule (b): a vocabulary term may replace a word at least this similar.
    static let vocabularyThreshold = 0.5
    /// Lowercase letters a corrected word may consist of (plus an inner hyphen or apostrophe).
    static let allowedLetters = Set("abcdefghijklmnopqrstuvwxyząćęłńóśźż-'’")
    /// Sentence-ending characters.
    static let sentenceEnds = Set(".!?…")
    /// Words ending in "." that do not end a sentence.
    static let abbreviations: Set<String> = [
        "np", "itd", "itp", "tzn", "tj", "ok", "godz", "ul", "tel", "nr", "wg", "ds", "dr", "prof", "mgr", "inż",
        "pt", "pon", "wt", "śr", "czw", "sob", "niedz", "ang", "tys", "mln", "mld", "zł", "gr", "min", "cdn", "etc", "vs",
    ]

    // MARK: Tokens

    /// One whitespace-separated word with the punctuation glued to it.
    struct Token: Equatable, Sendable {
        /// Whitespace before the token in its text ("" for the first).
        var separator: String
        var leading: String
        /// From the first to the last letter or digit ("e-mail", "15:00").
        var core: String
        var trailing: String

        /// What the alignment compares: lowercased letters and digits only.
        var key: String {
            String(core.lowercased().filter { $0.isLetter || $0.isNumber })
        }

        var text: String { leading + core + trailing }
    }

    /// Splits on whitespace; a chunk without letters or digits ("-", "...") is glued to the
    /// word before it (or the first word, when it opens the text).
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var opening = ""
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        var index = text.startIndex
        while index < text.endIndex {
            let spaceStart = index
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            let separator = String(text[spaceStart..<index])
            guard index < text.endIndex else { break }
            let chunkStart = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            let chunk = text[chunkStart..<index]
            guard let first = chunk.firstIndex(where: isWordCharacter), let last = chunk.lastIndex(where: isWordCharacter) else {
                if tokens.isEmpty {
                    opening += (opening.isEmpty ? "" : separator) + chunk
                } else {
                    tokens[tokens.count - 1].trailing += separator + chunk
                }
                continue
            }
            var token = Token(
                separator: tokens.isEmpty ? "" : separator,
                leading: String(chunk[chunk.startIndex..<first]),
                core: String(chunk[first...last]),
                trailing: String(chunk[chunk.index(after: last)...])
            )
            if tokens.isEmpty, !opening.isEmpty {
                token.leading = opening + separator + token.leading
            }
            tokens.append(token)
        }
        return tokens
    }

    // MARK: Merge

    private struct Piece {
        var token: Token
        /// The raw token this piece stands for.
        let rawIndex: Int
        /// The model's token it came from (nil for a reverted raw word).
        let outputIndex: Int?
        let reverted: Bool
        var insertionDroppedBefore = false
        var insertionDroppedAfter = false
    }

    static func merge(raw: String, output: String, vocabulary: Set<String> = [], spellCheck: SpellCheck) -> Merge {
        let rawTokens = tokenize(raw)
        let outputTokens = tokenize(output)
        guard !rawTokens.isEmpty else {
            return Merge(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), acceptedEdits: 0, revertedWords: 0, droppedWords: outputTokens.count)
        }
        let rawKeys = rawTokens.map(\.key)
        let vocabularyWords = normalizedVocabulary(vocabulary)

        var pieces: [Piece] = []
        var insertionPending = false
        var accepted = 0
        var reverted = 0
        var dropped = 0

        func append(_ piece: Piece) {
            var piece = piece
            if insertionPending {
                piece.insertionDroppedBefore = true
                insertionPending = false
            }
            pieces.append(piece)
        }
        func takeOutput<Raw: Sequence<Int>>(_ rawIndices: Raw, _ outputRange: Range<Int>) {
            for (i, j) in zip(rawIndices, outputRange) {
                append(Piece(token: outputTokens[j], rawIndex: i, outputIndex: j, reverted: false))
            }
        }
        func revert(_ rawRange: Range<Int>) {
            for i in rawRange {
                append(Piece(token: rawTokens[i], rawIndex: i, outputIndex: nil, reverted: true))
            }
            reverted += rawRange.count
        }

        for opcode in opcodes(rawKeys, outputTokens.map(\.key)) {
            switch opcode.kind {
            case .equal:
                takeOutput(opcode.raw, opcode.output)
            case .replace:
                // Fillers the model left out sit in the same block as the words it fixed
                // ("eee wyslalem" -> "Wysłałem"); they may go, the rest must pair up safely.
                let kept = opcode.raw.filter { !fillers.contains(rawKeys[$0]) }
                let safe = kept.count == opcode.output.count && zip(kept, opcode.output).allSatisfy { i, j in
                    isSafeReplacement(raw: rawTokens[i].core, output: outputTokens[j].core, vocabulary: vocabularyWords, spellCheck: spellCheck)
                }
                if safe {
                    takeOutput(kept, opcode.output)
                    accepted += opcode.raw.count
                } else {
                    revert(opcode.raw)
                }
            case .delete:
                if isRemovableDeletion(opcode.raw, in: rawKeys) {
                    accepted += opcode.raw.count
                } else {
                    revert(opcode.raw)
                }
            case .insert:
                dropped += opcode.output.count
                if !pieces.isEmpty { pieces[pieces.count - 1].insertionDroppedAfter = true }
                insertionPending = true
            }
        }
        guard !pieces.isEmpty else {
            return Merge(text: "", acceptedEdits: accepted, revertedWords: reverted, droppedWords: dropped)
        }

        restoreRawPunctuationAtChanges(&pieces, rawTokens: rawTokens, outputTokens: outputTokens)
        endLikeTheOutput(&pieces, outputTokens: outputTokens)
        capitalizeSentences(&pieces)

        let text = pieces.enumerated().map { index, piece in
            let separator = index == 0 ? "" : (piece.token.separator.isEmpty ? " " : piece.token.separator)
            return separator + piece.token.text
        }.joined()
        return Merge(text: text, acceptedEdits: accepted, revertedWords: reverted, droppedWords: dropped)
    }

    /// Next to a reverted block or a dropped insertion the model's punctuation belonged to a
    /// sentence that is no longer there: the word before takes the raw trailing punctuation,
    /// the word after takes the raw punctuation on both sides and loses a capital the model
    /// gave it only for starting its own sentence.
    private static func restoreRawPunctuationAtChanges(_ pieces: inout [Piece], rawTokens: [Token], outputTokens: [Token]) {
        for index in pieces.indices where !pieces[index].reverted {
            let raw = rawTokens[pieces[index].rawIndex]
            let changeAfter = pieces[index].insertionDroppedAfter || (index + 1 < pieces.count && pieces[index + 1].reverted)
            let changeBefore = pieces[index].insertionDroppedBefore || (index > 0 && pieces[index - 1].reverted)
            if changeAfter {
                pieces[index].token.trailing = raw.trailing
            }
            if changeBefore {
                pieces[index].token.leading = raw.leading
                pieces[index].token.trailing = raw.trailing
                if let outputIndex = pieces[index].outputIndex,
                   outputIndex == 0 || endsSentence(outputTokens[outputIndex - 1]),
                   pieces[index].token.core.first?.isUppercase == true,
                   raw.core.first?.isLowercase == true {
                    pieces[index].token.core = lowercasingFirst(pieces[index].token.core)
                }
            }
        }
    }

    /// When the model ended with ".", "!" or "?" and the merged text lost it, it gets it back.
    private static func endLikeTheOutput(_ pieces: inout [Piece], outputTokens: [Token]) {
        guard let last = pieces.indices.last, !pieces[last].token.trailing.contains(where: sentenceEnds.contains) else { return }
        let ending = String(outputTokens.last?.trailing.filter(sentenceEnds.contains) ?? "")
        guard !ending.isEmpty else { return }
        var trailing = pieces[last].token.trailing
        while let character = trailing.last, ",;:-".contains(character) { trailing.removeLast() }
        pieces[last].token.trailing = trailing + ending
    }

    private static func capitalizeSentences(_ pieces: inout [Piece]) {
        for index in pieces.indices where index == 0 || endsSentence(pieces[index - 1].token) {
            pieces[index].token.core = capitalizingFirst(pieces[index].token.core)
        }
    }

    static func endsSentence(_ token: Token) -> Bool {
        if token.trailing.contains(where: { "!?…".contains($0) }) { return true }
        guard token.trailing.contains(".") else { return false }
        return !abbreviations.contains(token.core.lowercased())
    }

    // MARK: Rules

    /// A model word may replace a raw word when it is (b) a vocabulary term at least 50 %
    /// similar, or (a) the same word once diacritics and "ł" are folded, or (c) more than 85 %
    /// similar by characters; for (a) and (c) it must also be spelled correctly (or be in the
    /// vocabulary) and consist of Polish or English letters only.
    static func isSafeReplacement(raw: String, output: String, vocabulary: Set<String>, spellCheck: SpellCheck) -> Bool {
        let rawWord = raw.lowercased()
        let outputWord = output.lowercased()
        let inVocabulary = vocabulary.contains(outputWord)
        if inVocabulary, characterSimilarity(rawWord, outputWord) >= vocabularyThreshold {
            return true
        }
        guard hasOnlyAllowedLetters(outputWord), inVocabulary || spellCheck(output) else { return false }
        if fold(rawWord) == fold(outputWord) { return true }
        return characterSimilarity(rawWord, outputWord) > similarWordThreshold
    }

    /// Raw words the model left out may stay out when each is a filler or a repeat of the
    /// kept word right next to the block ("to to jest" -> "To jest": difflib drops the first
    /// copy and keeps the second). One copy always stays, so a word never disappears.
    static func isRemovableDeletion(_ range: Range<Int>, in keys: [String]) -> Bool {
        let neighbours = [range.lowerBound - 1, range.upperBound].filter(keys.indices.contains).map { keys[$0] }
        return range.allSatisfy { fillers.contains(keys[$0]) || neighbours.contains(keys[$0]) }
    }

    /// Lowercase, no diacritics, "ł" as "l".
    static func fold(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "ł", with: "l")
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    /// 1 - character edit distance / the longer length (1 for two empty words).
    static func characterSimilarity(_ a: String, _ b: String) -> Double {
        let left = Array(a)
        let right = Array(b)
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(CorrectionGuard.editDistance(left, right)) / Double(longest)
    }

    static func hasOnlyAllowedLetters(_ word: String) -> Bool {
        guard let first = word.first, let last = word.last, first.isLetter, last.isLetter else { return false }
        return word.allSatisfy(allowedLetters.contains)
    }

    /// The vocabulary as lowercased single words (a term of several words adds each word).
    static func normalizedVocabulary(_ terms: Set<String>) -> Set<String> {
        Set(terms.flatMap { tokenize($0).map { $0.core.lowercased() } })
    }

    private static func capitalizingFirst(_ word: String) -> String {
        guard let first = word.first, first.isLowercase else { return word }
        return first.uppercased() + word.dropFirst()
    }

    private static func lowercasingFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.lowercased() + word.dropFirst()
    }

    // MARK: Alignment

    struct Opcode: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case equal, replace, delete, insert
        }

        let kind: Kind
        let raw: Range<Int>
        let output: Range<Int>
    }

    /// Python difflib's `SequenceMatcher.get_opcodes` without junk heuristics: the longest
    /// common run splits the problem, recursively, so repeated words align the intuitive way.
    static func opcodes(_ a: [String], _ b: [String]) -> [Opcode] {
        var result: [Opcode] = []
        var i = 0
        var j = 0
        for block in matchingBlocks(a, b) {
            if i < block.a, j < block.b {
                result.append(Opcode(kind: .replace, raw: i..<block.a, output: j..<block.b))
            } else if i < block.a {
                result.append(Opcode(kind: .delete, raw: i..<block.a, output: j..<j))
            } else if j < block.b {
                result.append(Opcode(kind: .insert, raw: i..<i, output: j..<block.b))
            }
            if block.size > 0 {
                result.append(Opcode(kind: .equal, raw: block.a..<block.a + block.size, output: block.b..<block.b + block.size))
            }
            i = block.a + block.size
            j = block.b + block.size
        }
        return result
    }

    private struct Block {
        var a: Int
        var b: Int
        var size: Int
    }

    private static func matchingBlocks(_ a: [String], _ b: [String]) -> [Block] {
        var positions: [String: [Int]] = [:]
        for (index, word) in b.enumerated() {
            positions[word, default: []].append(index)
        }
        var queue = [(aLow: 0, aHigh: a.count, bLow: 0, bHigh: b.count)]
        var blocks: [Block] = []
        while let range = queue.popLast() {
            let match = longestMatch(a, positions, range.aLow, range.aHigh, range.bLow, range.bHigh)
            guard match.size > 0 else { continue }
            blocks.append(match)
            if range.aLow < match.a, range.bLow < match.b {
                queue.append((range.aLow, match.a, range.bLow, match.b))
            }
            if match.a + match.size < range.aHigh, match.b + match.size < range.bHigh {
                queue.append((match.a + match.size, range.aHigh, match.b + match.size, range.bHigh))
            }
        }
        blocks.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        var merged: [Block] = []
        for block in blocks {
            if let last = merged.last, last.a + last.size == block.a, last.b + last.size == block.b {
                merged[merged.count - 1].size += block.size
            } else {
                merged.append(block)
            }
        }
        merged.append(Block(a: a.count, b: b.count, size: 0))
        return merged
    }

    private static func longestMatch(_ a: [String], _ positions: [String: [Int]], _ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int) -> Block {
        var best = Block(a: aLow, b: bLow, size: 0)
        var lengths: [Int: Int] = [:]
        for i in aLow..<aHigh {
            var next: [Int: Int] = [:]
            for j in positions[a[i]] ?? [] {
                if j < bLow { continue }
                if j >= bHigh { break }
                let length = (lengths[j - 1] ?? 0) + 1
                next[j] = length
                if length > best.size {
                    best = Block(a: i - length + 1, b: j - length + 1, size: length)
                }
            }
            lengths = next
        }
        return best
    }
}
