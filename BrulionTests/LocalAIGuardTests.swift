import Foundation
import Testing
@testable import Brulion

/// Synthetic Polish sentences only, nothing from real dictations.
struct LocalAIGuardTests {
    @Test func acceptsPunctuationCaseAndDiacritics() {
        let raw = "jutro o dziesiatej mamy spotkanie z zespolem w sprawie nowego budzetu na reklamy"
        let fixed = "Jutro o dziesiątej mamy spotkanie z zespołem w sprawie nowego budżetu na reklamy."
        #expect(CorrectionGuard.check(input: raw, output: fixed) == nil)
    }

    @Test func acceptsAnUnchangedText() {
        let text = "Proszę przygotować ofertę dla klienta do piątku."
        #expect(CorrectionGuard.check(input: text, output: text) == nil)
        #expect(CorrectionGuard.wordSimilarity(text, text) == 1)
    }

    @Test func rejectsAnAnswerToTheDictatedQuestion() {
        let rejection = CorrectionGuard.check(input: "jaka jest stolica francji", output: "Stolicą Francji jest Paryż.")
        guard case .lowSimilarity(let similarity) = rejection else {
            Issue.record("expected lowSimilarity, got \(String(describing: rejection))")
            return
        }
        #expect(similarity < 0.5)
    }

    @Test func rejectsATranslation() {
        let rejection = CorrectionGuard.check(
            input: "proszę wyślij mi raport sprzedaży do piątku rano",
            output: "Please send me the sales report by Friday morning."
        )
        #expect(rejection?.code == "lowSimilarity")
    }

    @Test func rejectsACutText() {
        let raw = "w przyszłym tygodniu zaczynamy prace nad nową wersją aplikacji a potem przygotujemy prezentację dla zarządu"
        let rejection = CorrectionGuard.check(input: raw, output: "W przyszłym tygodniu zaczynamy.")
        guard case .tooShort(let ratio) = rejection else {
            Issue.record("expected tooShort, got \(String(describing: rejection))")
            return
        }
        #expect(ratio < 0.5)
    }

    @Test func rejectsAddedContent() {
        let raw = "zadzwoń do pana nowaka w sprawie umowy najmu"
        let padded = "Zadzwoń do pana Nowaka w sprawie umowy najmu. Warto przypomnieć mu o terminie płatności, sprawdzić aneks i zapytać o kaucję."
        #expect(CorrectionGuard.check(input: raw, output: padded)?.code == "tooLong")
    }

    @Test func shortInputsSkipTheLengthCheckButNotSimilarity() {
        #expect(CorrectionGuard.check(input: "ok dzięki", output: "OK, dzięki!") == nil)
        #expect(CorrectionGuard.check(input: "tak", output: "Tak, oczywiście, chętnie pomogę w tej sprawie.")?.code == "lowSimilarity")
    }

    @Test func rejectsAnEmptyAnswer() {
        #expect(CorrectionGuard.check(input: "test", output: "  \n") == .empty)
    }

    @Test func boundariesFollowTheThresholds() {
        let raw = String(repeating: "słowo ", count: 10)
        let custom = CorrectionGuard.Thresholds(minimumLengthRatio: 0.9, maximumLengthRatio: 1.1, lengthCheckMinimumCharacters: 10, minimumSimilarity: 0.9)
        #expect(CorrectionGuard.check(input: raw, output: String(repeating: "słowo ", count: 8), thresholds: custom)?.code == "tooShort")
        #expect(CorrectionGuard.check(input: raw, output: raw, thresholds: custom) == nil)
    }

    @Test func wordsIgnoreCaseAndPunctuation() {
        #expect(CorrectionGuard.words("Ala, ma kota! (i psa)") == ["ala", "ma", "kota", "i", "psa"])
        #expect(CorrectionGuard.wordSimilarity("Ala ma kota.", "ala ma kota") == 1)
        #expect(CorrectionGuard.wordSimilarity("", "") == 1)
        #expect(CorrectionGuard.wordSimilarity("a b c d", "a b x d") == 0.75)
    }

    @Test func editDistanceCountsWordOperations() {
        #expect(CorrectionGuard.editDistance(["a", "b", "c"], ["a", "b", "c"]) == 0)
        #expect(CorrectionGuard.editDistance(["a", "b", "c"], ["a", "c"]) == 1)
        #expect(CorrectionGuard.editDistance([], ["a", "b"]) == 2)
        #expect(CorrectionGuard.editDistance(["a", "b"], ["b", "a"]) == 2)
    }
}
