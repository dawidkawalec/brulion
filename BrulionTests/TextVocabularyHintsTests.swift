import Testing
@testable import Brulion

struct TextVocabularyHintsTests {
    @Test func llmListRespectsTermAndCharLimits() {
        let words = (0..<200).map { "słowo\($0)" }
        let list = VocabularyHints.llmList(words)
        #expect(list.components(separatedBy: ", ").count == 150)
        #expect(VocabularyHints.llmList(words, maxTerms: 3) == "słowo0, słowo1, słowo2")
        #expect(VocabularyHints.llmList(["aaaa", "bbbb", "cccc"], maxChars: 10) == "aaaa, bbbb")
        #expect(VocabularyHints.llmList(["A", "a", " A "]) == "A")
        #expect(VocabularyHints.llmList([]) == "")
    }

    @Test func whisperPromptIsNilWhenEmptyAndFitsTheBudget() {
        #expect(VocabularyHints.whisperPrompt([]) == nil)
        #expect(VocabularyHints.whisperPrompt(["Kawalec", "CraftWeb"]) == "Glossary: Kawalec, CraftWeb.")
        let long = VocabularyHints.whisperPrompt((0..<500).map { "termin\($0)" })
        #expect(long != nil)
        #expect((long?.count ?? 0) <= 600)
        #expect(long?.hasSuffix(".") == true)
        #expect(VocabularyHints.whisperPrompt(["Kawalec"], maxChars: 5) == nil)
    }
}
