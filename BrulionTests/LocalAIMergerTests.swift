import Foundation
import Testing
@testable import Brulion

/// Synthetic Polish sentences only. The spell check is a fixed closure, so nothing depends
/// on the Mac's dictionaries.
struct LocalAIMergerTests {
    private let anyWord: CorrectionMerger.SpellCheck = { _ in true }

    private func known(_ words: String...) -> CorrectionMerger.SpellCheck {
        CorrectionSpelling.lookup(Set(words.map { $0.lowercased() }))
    }

    private func merge(_ raw: String, _ output: String, vocabulary: Set<String> = [], spellCheck: CorrectionMerger.SpellCheck? = nil) -> CorrectionMerger.Merge {
        CorrectionMerger.merge(raw: raw, output: output, vocabulary: vocabulary, spellCheck: spellCheck ?? anyWord)
    }

    // MARK: Equal

    @Test func keepsTheModelsPunctuationAndCapitalsOnEqualWords() {
        let result = merge("jutro mamy spotkanie z zespołem", "Jutro mamy spotkanie z zespołem.")
        #expect(result.text == "Jutro mamy spotkanie z zespołem.")
        #expect(result == CorrectionMerger.Merge(text: "Jutro mamy spotkanie z zespołem.", acceptedEdits: 0, revertedWords: 0, droppedWords: 0))
    }

    // MARK: Replace

    @Test func acceptsFoldedDiacriticsAndBarredL() {
        let result = merge("zolw i zaba ida do domu", "Żółw i żaba idą do domu.")
        #expect(result.text == "Żółw i żaba idą do domu.")
        #expect(result.acceptedEdits == 3)
    }

    @Test func diacriticFixMustBeSpelledRight() {
        let result = merge("zolw idzie", "Żółw idzie.", spellCheck: known("idzie"))
        #expect(result.text == "Zolw idzie.")
        #expect(result.revertedWords == 1)
    }

    @Test func acceptsAVocabularyTerm() {
        let result = merge("wdrożyłem to na supabejs wczoraj", "Wdrożyłem to na Supabase wczoraj.", vocabulary: ["Supabase"], spellCheck: known("wdrożyłem", "to", "na", "wczoraj"))
        #expect(result.text == "Wdrożyłem to na Supabase wczoraj.")
        #expect(result.acceptedEdits == 1)
    }

    @Test func vocabularyTermMustResembleTheWord() {
        let result = merge("zapisz to w bazie", "Zapisz to w Supabase.", vocabulary: ["Supabase"])
        #expect(result.text == "Zapisz to w bazie.")
        #expect(result.revertedWords == 1)
    }

    @Test func acceptsACloseSpellingFix() {
        let result = merge("wdrażamy na kubernetis", "Wdrażamy na Kubernetes.", spellCheck: known("wdrażamy", "na", "kubernetes"))
        #expect(result.text == "Wdrażamy na Kubernetes.")
        #expect(result.acceptedEdits == 1)
    }

    @Test func closeSpellingFixMustBeSpelledRight() {
        let result = merge("wdrażamy na kubernetis", "Wdrażamy na Kubernetes.", spellCheck: known("wdrażamy", "na"))
        #expect(result.text == "Wdrażamy na kubernetis.")
    }

    @Test func revertsChangesOfMeaning() {
        #expect(merge("zrób to jutro", "Zrobię to jutro.").text == "Zrób to jutro.")
        #expect(merge("trzeba wyciąć ten fragment", "Trzeba wyciszyć ten fragment.").text == "Trzeba wyciąć ten fragment.")
        #expect(merge("wczoraj robiliśmy przegląd", "Wczoraj robiłyśmy przegląd.").text == "Wczoraj robiliśmy przegląd.")
    }

    @Test func revertsAReplacementOfAnotherLength() {
        let result = merge("to jest w ogóle bez sensu", "To jest wcale bez sensu.")
        #expect(result.text == "To jest w ogóle bez sensu.")
        #expect(result.revertedWords == 2)
    }

    @Test func rejectsCharactersOutsidePolishAndEnglish() {
        #expect(merge("dokument gotowy", "Dokumént gotowy.").text == "Dokument gotowy.")
        #expect(merge("spotkajmy się o piętnastej", "Spotkajmy się o 15:00.").text == "Spotkajmy się o piętnastej.")
        #expect(merge("kot śpi", "Кот śpi.").text == "Kot śpi.")
    }

    @Test func everyPairOfABlockMustBeSafe() {
        // "zolw" alone would pass, "zaba" -> "żabka" would not: the whole block goes back.
        let result = merge("zolw zaba ida", "Żółw żabka idą.")
        #expect(result.text == "Zolw zaba ida.")
        #expect(result.revertedWords == 3)
    }

    // MARK: Delete and insert

    @Test func dropsFillers() {
        let result = merge("yyy no to eee zaczynamy", "No to zaczynamy.")
        #expect(result.text == "No to zaczynamy.")
        #expect(result.acceptedEdits == 2)
    }

    @Test func dropsARepeatedWord() {
        #expect(merge("to to jest dobry pomysł", "To jest dobry pomysł.").text == "To jest dobry pomysł.")
        #expect(merge("jest jest jest gotowe", "Jest gotowe.").text == "Jest gotowe.")
    }

    @Test func putsBackContentTheModelLeftOut() {
        let result = merge("nie zgadzam się z tym", "Zgadzam się z tym.")
        #expect(result.text == "Nie zgadzam się z tym.")
        #expect(result.revertedWords == 1)
        #expect(merge("kup mleko i chleb", "Kup chleb.").text == "Kup mleko i chleb.")
    }

    @Test func dropsWordsTheModelAdded() {
        let loop = merge("dzięki za pomoc", "Dzięki za pomoc. Dzięki za pomoc. Dzięki za pomoc.")
        #expect(loop.text == "Dzięki za pomoc.")
        #expect(loop.droppedWords == 6)
        #expect(merge("jutro mamy spotkanie", "Oczywiście! Jutro mamy spotkanie.").text == "Jutro mamy spotkanie.")
    }

    @Test func undoesASummary() {
        let result = merge("w przyszłym tygodniu zaczynamy prace nad nową wersją aplikacji", "Zaczynamy prace nad aplikacją.")
        #expect(result.text == "W przyszłym tygodniu zaczynamy prace nad nową wersją aplikacji.")
    }

    @Test func fillerNextToAFixedWordStillGoes() {
        let result = merge("eee wyslalem raport do szefa", "Wysłałem raport do szefa. Pozdrawiam.")
        #expect(result == CorrectionMerger.Merge(text: "Wysłałem raport do szefa.", acceptedEdits: 2, revertedWords: 0, droppedWords: 1))
    }

    // MARK: Punctuation and capitals

    @Test func noSentenceBreakLeftInsideAReversion() {
        let result = merge("dodaj do listy zadań to do kupić mleko", "Dodaj do listy zadań. Do zrobienia: kupić mleko.")
        #expect(result.text == "Dodaj do listy zadań to do kupić mleko.")
    }

    @Test func noCommaLeftNextToAReversion() {
        let result = merge("czy ty jesteś na innym spotkaniu", "Czy jesteś, na innym spotkaniu?")
        #expect(result.text == "Czy ty jesteś na innym spotkaniu?")
    }

    @Test func capitalizesSentenceStartsButNotAfterAbbreviations() {
        #expect(merge("zrób to. potem idź np. do sklepu", "Zrobię to. Potem idź np. do sklepu.").text == "Zrób to. Potem idź np. do sklepu.")
        #expect(merge("koniec. potem zrób to", "Koniec. Potem zrobię to.").text == "Koniec. Potem zrób to.")
        #expect(merge("ok", "ok").text == "Ok")
    }

    @Test func keepsParagraphs() {
        #expect(merge("pierwszy akapit\n\ndrugi akapit", "Pierwszy akapit.\n\nDrugi akapit.").text == "Pierwszy akapit.\n\nDrugi akapit.")
    }

    // MARK: Pieces

    @Test func tokensKeepTheirPunctuation() {
        let tokens = CorrectionMerger.tokenize("- tak , e-mail o 15:00, ok?")
        #expect(tokens.map(\.core) == ["tak", "e-mail", "o", "15:00", "ok"])
        #expect(tokens.map(\.key) == ["tak", "email", "o", "1500", "ok"])
        #expect(tokens[0].leading == "- ")
        #expect(tokens[0].trailing == " ,")
        #expect(tokens[3].trailing == ",")
        #expect(tokens[4].trailing == "?")
    }

    @Test func opcodesFollowDifflib() {
        let codes = CorrectionMerger.opcodes(["a", "b", "c", "d"], ["a", "x", "c", "e", "d"])
        #expect(codes.map(\.kind) == [.equal, .replace, .equal, .insert, .equal])
        #expect(codes[1].raw == 1..<2 && codes[1].output == 1..<2)
        #expect(codes[3].output == 3..<4)
        #expect(CorrectionMerger.opcodes([], ["a"]).map(\.kind) == [.insert])
        #expect(CorrectionMerger.opcodes(["a"], []).map(\.kind) == [.delete])
    }

    @Test func helpers() {
        #expect(CorrectionMerger.fold("Żółć") == "zolc")
        #expect(CorrectionMerger.fold("Łódź") == "lodz")
        #expect(CorrectionMerger.characterSimilarity("abcd", "abcd") == 1)
        #expect(CorrectionMerger.characterSimilarity("abcd", "abxd") == 0.75)
        #expect(CorrectionMerger.hasOnlyAllowedLetters("źdźbło"))
        #expect(CorrectionMerger.hasOnlyAllowedLetters("e-mail"))
        #expect(!CorrectionMerger.hasOnlyAllowedLetters("café"))
        #expect(!CorrectionMerger.hasOnlyAllowedLetters("x2"))
        #expect(CorrectionMerger.normalizedVocabulary(["Jan Kowalski", "Supabase"]) == ["jan", "kowalski", "supabase"])
        #expect(CorrectionMerger.isRemovableDeletion(1..<3, in: ["a", "b", "b", "c"]) == false)
        #expect(CorrectionMerger.isRemovableDeletion(0..<1, in: ["to", "to", "jest"]))
    }

    // MARK: The guard's entry point

    @Test func applyReturnsTheMergedText() {
        let outcome = CorrectionGuard.apply(raw: "zolw idzie do domu", output: "Żółw idzie do domu.", spellCheck: anyWord)
        #expect(outcome.isAccepted)
        #expect(outcome.text == "Żółw idzie do domu.")
        #expect(outcome.merge?.acceptedEdits == 1)
    }

    @Test func applyKeepsTheRawTextForAnEmptyAnswer() {
        let outcome = CorrectionGuard.apply(raw: "zolw idzie", output: "  ", spellCheck: anyWord)
        #expect(outcome == CorrectionGuard.Outcome(text: "zolw idzie", rejection: .empty, merge: nil))
    }

    @Test func applyStillChecksTheMergedText() {
        let raw = String(repeating: "yyy ", count: 11) + "tak"
        let outcome = CorrectionGuard.apply(raw: raw, output: "Tak.", spellCheck: anyWord)
        #expect(outcome.rejection?.code == "tooShort")
        #expect(outcome.text == raw)
    }

    @Test func applyTurnsATranslationBackIntoTheRawWords() {
        let outcome = CorrectionGuard.apply(raw: "proszę wyślij mi raport", output: "Please send me the report.", spellCheck: anyWord)
        #expect(outcome.isAccepted)
        #expect(outcome.text == "Proszę wyślij mi raport.")
        #expect(outcome.merge?.revertedWords == 4)
    }
}
