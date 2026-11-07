import Foundation
import Testing
@testable import Captylo

/// The open meeting AI prompts (`MeetingPrompts`, `MeetingNotesSkeleton`): every template has
/// its sections, every prompt states the answer layout the app's parsers read, the citation
/// rule and the exact "not found" sentences, and no prompt carries a long dash.
struct MeetingInstructionsTests {
    private static let builtInIDs = BuiltInMeetingTemplates.all.map(\.id)

    /// Every prompt the meeting AI can send, for the checks that apply to all of them.
    private static var allPrompts: [String] {
        builtInIDs.flatMap { id in
            [
                MeetingPrompts.notesSystem(templateID: id, customInstructions: nil),
                MeetingPrompts.notesMergeSystem(templateID: id, customInstructions: nil),
            ]
        } + [
            MeetingPrompts.notesSystem(templateID: "custom-1", customInstructions: "Skup się na ryzykach."),
            MeetingPrompts.notesMergeSystem(templateID: "custom-1", customInstructions: "Skup się na ryzykach."),
            MeetingPrompts.correctionSystem(),
            MeetingPrompts.askSystem(),
            MeetingPrompts.libraryAskSystem(),
        ] + reminders
    }

    private static var reminders: [String] {
        builtInIDs.flatMap { id in
            [MeetingPrompts.notesReminder(templateID: id), MeetingPrompts.notesMergeReminder(templateID: id)]
        } + [MeetingPrompts.askReminder(), MeetingPrompts.libraryAskReminder()]
    }

    // MARK: Notes

    @Test func everyBuiltInTemplateHasItsOwnSkeleton() {
        #expect(MeetingNotesSkeleton.all.map(\.templateID) == Self.builtInIDs)
        for id in Self.builtInIDs {
            let skeleton = MeetingNotesSkeleton.forTemplate(id: id)
            #expect(skeleton.templateID == id)
            #expect(!skeleton.sections.isEmpty)
            #expect(skeleton.sections.first?.heading == "Podsumowanie")
            #expect(Set(skeleton.sections.map(\.heading)).count == skeleton.sections.count)
            #expect(skeleton.sections.allSatisfy { !$0.guide.isEmpty })
        }
    }

    @Test func unknownTemplateWritesTheGeneralSections() {
        #expect(MeetingNotesSkeleton.forTemplate(id: "nope") == MeetingNotesSkeleton.general)
        #expect(MeetingNotesSkeleton.general.sections.map(\.heading) == ["Podsumowanie", "Decyzje", "Zadania", "Otwarte pytania", "Następne kroki"])
    }

    @Test func notesPromptsCarryEverySectionHeadingInOrder() {
        for id in Self.builtInIDs {
            let skeleton = MeetingNotesSkeleton.forTemplate(id: id)
            for prompt in [
                MeetingPrompts.notesSystem(templateID: id, customInstructions: nil),
                MeetingPrompts.notesMergeSystem(templateID: id, customInstructions: nil),
            ] {
                var cursor = prompt.startIndex
                for section in skeleton.sections {
                    let heading = prompt.range(of: "\n## \(section.heading)\n", range: cursor..<prompt.endIndex)
                    #expect(heading != nil, "\(id): ## \(section.heading)")
                    if let heading { cursor = heading.upperBound }
                }
            }
        }
    }

    /// The layout in the prompt, with its `[czas]` filled in, reads back through the app's own
    /// parsers as the template's sections, every row cited, the tasks where the parser finds them.
    @Test func promptLayoutReadsBackThroughTheParsers() throws {
        for id in Self.builtInIDs {
            let skeleton = MeetingNotesSkeleton.forTemplate(id: id)
            let prompt = MeetingPrompts.notesSystem(templateID: id, customInstructions: nil)
            let start = try #require(prompt.range(of: "\n## \(skeleton.sections[0].heading)\n"))
            let layout = String(prompt[start.lowerBound...]).replacingOccurrences(of: "[czas]", with: "[1:05]")
            let document = MeetingNotesDocument(markdown: layout)
            #expect(document.sections.map(\.title) == skeleton.sections.map { Optional($0.heading) })
            #expect(document.sections.allSatisfy { section in
                section.items.allSatisfy { $0.line.citations == [65] && !$0.line.text.contains("[") }
            })
            // Two sample tasks of one person: one task per row.
            let taskRows = 2 * skeleton.sections.filter(\.isTasks).count
            #expect(document.tasks.count == taskRows)
            #expect(MeetingNotesParser.actionItems(in: layout).count == taskRows)
            // Short points: two sample rows under the first heading.
            #expect(document.sections.first?.items.count == 2)
        }
    }

    @Test func notesPromptsStateTheCitationAndFactRules() {
        for id in Self.builtInIDs {
            let notes = MeetingPrompts.notesSystem(templateID: id, customInstructions: nil)
            #expect(notes.contains("[12:34]"))
            #expect(notes.contains("[1:02:03]"))
            #expect(notes.contains("Nie wymyślaj"))
            #expect(notes.contains("<transcript>"))
            #expect(notes.contains("<user_notes>"))
            #expect(notes.contains("w języku transkryptu"))
            let merge = MeetingPrompts.notesMergeSystem(templateID: id, customInstructions: nil)
            #expect(merge.contains("[12:34]"))
            #expect(merge.contains("<part>"))
            #expect(merge.contains("tylko raz"))
        }
    }

    @Test func notesRemindersRepeatTheSectionsAndTheCitationRule() {
        for id in Self.builtInIDs {
            let headings = MeetingNotesSkeleton.forTemplate(id: id).sections.map(\.heading).joined(separator: ", ")
            for reminder in [MeetingPrompts.notesReminder(templateID: id), MeetingPrompts.notesMergeReminder(templateID: id)] {
                #expect(reminder.contains("z sekcjami: \(headings)."))
                #expect(reminder.contains("[12:34]"))
            }
        }
    }

    /// The worked example in the notes prompt shows rows the parsers read as cited points.
    @Test func notesExampleRowsAreCitedPoints() throws {
        let prompt = MeetingPrompts.notesSystem(templateID: "general", customInstructions: nil)
        let start = try #require(prompt.range(of: "Punkty:\n"))
        let end = try #require(prompt.range(of: "\n\n", range: start.upperBound..<prompt.endIndex))
        let rows = MeetingNotesDocument(markdown: String(prompt[start.upperBound..<end.lowerBound])).sections.flatMap(\.items)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.line.citations == [198] })
    }

    @Test func customInstructionsGoLastAndTrimmed() {
        let prompt = MeetingPrompts.notesSystem(templateID: "custom-7", customInstructions: "  Zapisz każde ryzyko.\n ")
        #expect(prompt.hasSuffix("<custom_instructions>\nZapisz każde ryzyko.\n</custom_instructions>"))
        // A custom template writes the general sections under its own instructions.
        #expect(prompt.contains("## Następne kroki"))
        let merge = MeetingPrompts.notesMergeSystem(templateID: "custom-7", customInstructions: "Zapisz każde ryzyko.")
        #expect(merge.contains("<custom_instructions>\nZapisz każde ryzyko.\n</custom_instructions>"))
        for blank in [nil, "", "  \n"] {
            #expect(!MeetingPrompts.notesSystem(templateID: "general", customInstructions: blank).contains("custom_instructions"))
        }
        #expect(MeetingPrompts.notesSystem(templateID: "general", customInstructions: nil)
            == MeetingPrompts.notesSystem(templateID: "general", customInstructions: " "))
    }

    @Test func interviewNotesNeverJudgePersonalTraits() {
        let prompt = MeetingPrompts.notesSystem(templateID: "interview", customInstructions: nil)
        #expect(prompt.contains("Nie oceniaj wieku"))
        #expect(!MeetingPrompts.notesSystem(templateID: "general", customInstructions: nil).contains("Nie oceniaj wieku"))
    }

    // MARK: Fixes and asks

    @Test func correctionPromptAsksForTheParsedLineFormat() {
        let prompt = MeetingPrompts.correctionSystem()
        #expect(prompt.contains("numer|tekst"))
        #expect(prompt.contains("Nie zmieniaj sensu"))
        #expect(prompt.contains("Nie łącz i nie dziel linii"))
        // The example answer is what `MeetingCorrectionPrompt.parse` reads.
        let parts = prompt.components(separatedBy: "Odpowiedź:\n")
        #expect(parts.count == 2)
        #expect(MeetingCorrectionPrompt.parse(parts.last ?? "") == [1: "No to w piątek wysyłamy ofertę do pana Kowalskiego.", 2: "Dobrze."])
    }

    @Test func askPromptCitesStampsAndEndsWithTheExactNotFound() {
        let prompt = MeetingPrompts.askSystem()
        #expect(prompt.contains("[12:34]"))
        #expect(prompt.contains("Każdy czas w osobnym nawiasie"))
        #expect(prompt.contains("napisz tylko jedno zdanie: \(MeetingAskPrompt.notFound)"))
        #expect(prompt.contains("to zdanie brzmi: \(MeetingAskPrompt.notFoundEnglish)"))
        #expect(prompt.contains("<previous_questions>"))
        // The worked example: the exact not-found sentence, and a cited answer.
        #expect(prompt.contains("Odpowiedź: \(MeetingAskPrompt.notFound)\n"))
        #expect(MeetingCitations.split("W programie Stock [2:10].").citations == [130])
        let reminder = MeetingPrompts.askReminder()
        #expect(reminder.hasSuffix("napisz tylko: \(MeetingAskPrompt.notFound)"))
        #expect(reminder.contains("[12:34]"))
    }

    @Test func libraryPromptCitesSourcesTheWayLibraryCitationReads() {
        let prompt = MeetingPrompts.libraryAskSystem()
        #expect(prompt.contains("napisz tylko jedno zdanie: \(LibraryAskPrompt.notFound)"))
        #expect(prompt.contains("to zdanie brzmi: \(LibraryAskPrompt.notFoundEnglish)"))
        #expect(MeetingPrompts.libraryAskReminder().hasSuffix("napisz tylko: \(LibraryAskPrompt.notFound)"))
        for tag in ["<meetings>", "<excerpts>", "<ai_notes>", "<notes>", "Dzisiaj"] {
            #expect(prompt.contains(tag))
        }
        // The rule's forms, then the worked example's answer.
        let citations = LibraryCitation.parse(prompt, meetings: [UUID(), UUID()], notes: [UUID()])
        #expect(citations.map(\.label) == ["S1 12:34", "S1", "N1", "S2 14:05", "N1"])
    }

    // MARK: Citation repair

    /// Forms the 7B model wrote in the trials, back in the forms the parsers read.
    @Test func citationListsAndSpansBecomeOneBracketEach() {
        #expect(CitationNormalizer.normalize("- Program poleceń po starcie [26:23, 27:40].") == "- Program poleceń po starcie [26:23] [27:40].")
        #expect(CitationNormalizer.normalize("- Kasia skończyła ekran [0:00-1:45]") == "- Kasia skończyła ekran [0:00]")
        #expect(CitationNormalizer.normalize("Tak [4:52; 1:05:10]") == "Tak [4:52] [1:05:10]")
        #expect(CitationNormalizer.normalize("Start 15 marca [S2 41:13, 41:29]") == "Start 15 marca [S2 41:13] [S2 41:29]")
        #expect(CitationNormalizer.normalize("Kod [N1, S1 2:29]") == "Kod [N1] [S1 2:29]")
        #expect(CitationNormalizer.normalize("Beta [S1, 12:34, 15:00]") == "Beta [S1 12:34] [S1 15:00]")
        #expect(CitationNormalizer.normalize("Zakres [S1 12:34-13:00]") == "Zakres [S1 12:34]")
        let parsed = MeetingCitations.split(CitationNormalizer.normalize("Punkt [26:23, 27:40]"))
        #expect(parsed == MeetingNotesDocument.Line(text: "Punkt", citations: [1583, 1660]))
    }

    @Test func otherBracketsStayAsTheyAre() {
        for text in [
            "- [ ] zadanie [1:05]", "- [x] gotowe", "[link](https://example.com)", "Plan [czas]",
            "Jedna [12:34]", "Zła [37:60, x]", "Źródło [S1, 12:34]", "Bez nawiasów", "[S1] i [N2]",
        ] {
            #expect(CitationNormalizer.normalize(text) == text)
        }
        #expect(LibraryCitation.parse("[S1, 12:34]", meetings: [UUID()]).map(\.label) == ["S1 12:34"])
    }

    // MARK: Every prompt

    @Test func noPromptHasALongDash() {
        for prompt in Self.allPrompts {
            #expect(!prompt.contains("\u{2014}"))
            #expect(!prompt.contains("\u{2013}"))
        }
    }

    @Test func promptsStayShortForASmallModel() {
        // About 1.1k real tokens at most (1.2k estimated), so the data keeps the context.
        for prompt in Self.allPrompts {
            #expect(TranscriptChunker.estimatedTokens(prompt) < 1_400)
        }
        #expect(MeetingPrompts.correctionSystem().utf8.count < 1_200)
    }
}
