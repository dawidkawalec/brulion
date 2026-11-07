import Foundation
import os
import Testing
@testable import Captylo

/// Splitting a long meeting for the AI notes (`TranscriptChunker`, `MeetingNotesPlan`) and
/// running the plan (`MeetingNotesWriter`) with a fake chat call. Invented meetings only.
struct TranscriptChunkerTests {
    private static let system = MeetingPrompts.notesSystem(templateID: "general", customInstructions: nil)

    /// A meeting of `count` lines, every one about `words` words, alternating "Ja" and Anna,
    /// 12 s apart, with two typed note lines and one echo line.
    private static func meeting(lines count: Int, words: Int = 25) -> (MeetingRecord, [MeetingSegmentRecord]) {
        let id = UUID()
        var meeting = MeetingRecord(id: id, title: "Plan wdrożenia w Zielonym Ogrodzie")
        meeting.participants = ["Anna Kowal", " ", "Piotr Lis"]
        meeting.speakerNames = ["1": "Anna"]
        meeting.noteLines = [
            MeetingNoteLine(text: "budżet 40 tys.", at: 30),
            MeetingNoteLine(text: "  ", at: 40),
            MeetingNoteLine(text: "termin startu", at: Double(count - 2) * 12),
        ]
        var segments = (0..<count).map { index in
            let text = (0..<words).map { "słowo\(index)x\($0)" }.joined(separator: " ")
            return MeetingSegmentRecord(
                meetingID: id, track: index.isMultiple(of: 2) ? .me : .them,
                start: Double(index) * 12, end: Double(index) * 12 + 11, text: text,
                speaker: index.isMultiple(of: 2) ? nil : "1"
            )
        }
        segments.append(MeetingSegmentRecord(meetingID: id, track: .me, start: 50, end: 52, text: "ECHO-LINE", isEcho: true))
        return (meeting, segments.shuffled())
    }

    /// The transcript lines of a part's data, in order.
    private static func transcriptLines(_ user: String) -> [String] {
        guard let open = user.range(of: "<transcript>\n"), let close = user.range(of: "\n</transcript>") else { return [] }
        return user[open.upperBound..<close.lowerBound].split(separator: "\n").map(String.init)
    }

    private static func noteLines(_ user: String) -> [String] {
        guard let open = user.range(of: "<user_notes>\n"), let close = user.range(of: "\n</user_notes>") else { return [] }
        return user[open.upperBound..<close.lowerBound].split(separator: "\n").map(String.init)
    }

    // MARK: Estimate

    @Test func tokensAreEstimatedFromUTF8Length() {
        #expect(TranscriptChunker.bytesPerToken == 2.3)
        #expect(TranscriptChunker.defaultInputBudget == 20_000)
        #expect(TranscriptChunker.estimatedTokens("") == 0)
        #expect(TranscriptChunker.estimatedTokens("ab") == 1)
        #expect(TranscriptChunker.estimatedTokens("abcd") == 2)
        #expect(TranscriptChunker.estimatedTokens("abcde") == 3)
        // Polish letters are two bytes each: 8 bytes.
        #expect(TranscriptChunker.estimatedTokens("żółć") == 4)
    }

    // MARK: Ranges

    @Test func rangesCoverEveryItemInOrderWithinTheLimit() {
        let costs = [5, 9, 3, 12, 7, 7, 1, 20, 4, 6, 11, 2]
        for limit in [20, 25, 33, 50, 1_000] {
            let ranges = TranscriptChunker.ranges(costs: costs, limit: limit)
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == costs.count)
            #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
            #expect(ranges.allSatisfy { !$0.isEmpty && costs[$0].reduce(0, +) <= limit })
        }
        #expect(TranscriptChunker.ranges(costs: costs, limit: 1_000) == [0..<costs.count])
        #expect(TranscriptChunker.ranges(costs: [], limit: 10).isEmpty)
    }

    @Test func rangesAreAboutEven() {
        let ranges = TranscriptChunker.ranges(costs: Array(repeating: 10, count: 10), limit: 40)
        #expect(ranges.count == 3)
        let sizes = ranges.map(\.count)
        #expect(sizes.max()! - sizes.min()! <= 1)
        // Never a sliver left at the end.
        let many = TranscriptChunker.ranges(costs: Array(repeating: 7, count: 100), limit: 300)
        #expect(many.count == 3)
        #expect(many.allSatisfy { $0.count >= 30 })
    }

    @Test func anItemBiggerThanTheLimitIsAloneAndWhole() {
        let ranges = TranscriptChunker.ranges(costs: [10, 10, 500, 10, 10], limit: 50)
        #expect(ranges.contains(2..<3))
        #expect(ranges.allSatisfy { $0 == 2..<3 || !$0.contains(2) })
        #expect(TranscriptChunker.ranges(costs: [500], limit: 50) == [0..<1])
        // A limit of nothing still gives every item its own range.
        #expect(TranscriptChunker.ranges(costs: [3, 4], limit: 0) == [0..<1, 1..<2])
    }

    // MARK: Plan

    @Test func aMeetingThatFitsIsOneCallWithTodaysData() {
        let (meeting, segments) = Self.meeting(lines: 20)
        let plan = TranscriptChunker.plan(meeting: meeting, segments: segments, system: Self.system)
        let expected = MeetingNotesPrompt.user(meeting: meeting, segments: segments.filter { !$0.isEcho })
        #expect(plan == .single(user: expected))
    }

    @Test func planSwitchesToPartsRightAtTheBudget() {
        let (meeting, segments) = Self.meeting(lines: 60)
        let whole = MeetingNotesPrompt.user(meeting: meeting, segments: segments.filter { !$0.isEcho })
        let exact = TranscriptChunker.estimatedTokens(Self.system) + TranscriptChunker.estimatedTokens(whole) + TranscriptChunker.overheadTokens
        #expect(TranscriptChunker.fits(system: Self.system, user: whole, budget: exact))
        #expect(!TranscriptChunker.fits(system: Self.system, user: whole, budget: exact - 1))
        #expect(TranscriptChunker.plan(meeting: meeting, segments: segments, system: Self.system, budget: exact) == .single(user: whole))
        guard case .parts(let parts) = TranscriptChunker.plan(meeting: meeting, segments: segments, system: Self.system, budget: exact - 1) else {
            Issue.record("expected parts")
            return
        }
        #expect(parts.count == 2)
    }

    @Test func partsKeepEveryLineOnceInOrderWithinTheBudget() throws {
        let (meeting, segments) = Self.meeting(lines: 240)
        let budget = 4_000
        guard case .parts(let parts) = TranscriptChunker.plan(meeting: meeting, segments: segments, system: Self.system, budget: budget) else {
            Issue.record("expected parts")
            return
        }
        #expect(parts.count >= 3)
        #expect(parts.map(\.number) == Array(1...parts.count))
        #expect(parts.allSatisfy { $0.count == parts.count })

        // Every spoken line exactly once, in time order, never cut; the echo never.
        let spoken = segments.filter { !$0.isEcho }.sorted { $0.start < $1.start }
        let expected = spoken.map { "\(MeetingTime.stamp($0.start)) \(meeting.promptLabel(for: $0)): \($0.text)" }
        #expect(parts.flatMap { Self.transcriptLines($0.user) } == expected)
        #expect(parts.map(\.segmentCount).reduce(0, +) == spoken.count)
        #expect(parts.allSatisfy { !$0.user.contains("ECHO-LINE") })

        for part in parts {
            // Self-contained: the meeting header and which part it is.
            #expect(part.user.hasPrefix("Tytuł: Plan wdrożenia w Zielonym Ogrodzie\nUczestnicy: Anna Kowal, Piotr Lis\nCzęść \(part.number) z \(parts.count) "))
            #expect(part.user.contains("od \(MeetingTime.stamp(part.start)) do \(MeetingTime.stamp(part.end))"))
            #expect(TranscriptChunker.fits(system: Self.system, user: part.user, budget: budget))
            let lines = Self.transcriptLines(part.user)
            #expect(lines.first?.hasPrefix(MeetingTime.stamp(part.start)) == true)
            #expect(lines.last?.hasPrefix(MeetingTime.stamp(part.end)) == true)
        }
        #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.end < $1.start })

        // The typed notes go once, with the part of their time; blank ones never.
        let notes = parts.flatMap { Self.noteLines($0.user) }
        #expect(notes == ["[0:30] budżet 40 tys.", "\(MeetingTime.stamp(238 * 12)) termin startu"])
        #expect(Self.noteLines(parts[0].user) == ["[0:30] budżet 40 tys."])
        #expect(try #require(parts.last).user.contains("termin startu"))
    }

    @Test func theClosingEndsEveryPartAndCountsInTheBudget() {
        let (meeting, segments) = Self.meeting(lines: 240)
        let closing = MeetingPrompts.notesReminder(templateID: "general")
        let budget = 4_000
        guard case .parts(let parts) = TranscriptChunker.plan(meeting: meeting, segments: segments, system: Self.system, closing: closing, budget: budget) else {
            Issue.record("expected parts")
            return
        }
        #expect(parts.allSatisfy { $0.user.hasSuffix("</transcript>\n\n" + closing) })
        #expect(parts.allSatisfy { TranscriptChunker.fits(system: Self.system, user: $0.user, budget: budget) })
        // A meeting that fits gets today's data with the closing after it.
        let (short, few) = Self.meeting(lines: 10)
        let single = TranscriptChunker.plan(meeting: short, segments: few, system: Self.system, closing: closing)
        #expect(single == .single(user: MeetingNotesPrompt.user(meeting: short, segments: few.filter { !$0.isEcho }) + "\n\n" + closing))
        #expect(TranscriptChunker.appending("", to: "x") == "x")
    }

    @Test func oneGiantSegmentGetsAPartOfItsOwnAndStaysWhole() {
        let id = UUID()
        let meeting = MeetingRecord(id: id, title: "Monolog")
        let giant = String(repeating: "bardzo długa wypowiedź ", count: 2_000)
        let segments = [
            MeetingSegmentRecord(meetingID: id, track: .me, start: 0, end: 5, text: "Zaczynamy."),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 6, end: 900, text: giant),
            MeetingSegmentRecord(meetingID: id, track: .me, start: 901, end: 905, text: "Dziękuję."),
        ]
        guard case .parts(let parts) = TranscriptChunker.plan(meeting: meeting, segments: segments, system: Self.system, budget: 3_000) else {
            Issue.record("expected parts")
            return
        }
        #expect(parts.count == 3)
        #expect(Self.transcriptLines(parts[1].user) == ["[0:06] Rozmówcy: \(giant)"])
        #expect(parts[1].segmentCount == 1)
        #expect(Self.transcriptLines(parts[0].user) == ["[0:00] Ja: Zaczynamy."])
        #expect(Self.transcriptLines(parts[2].user) == ["[15:01] Ja: Dziękuję."])
    }

    // MARK: Merge

    @Test func mergeDataNamesThePartsInOrder() {
        var meeting = MeetingRecord(title: "Przegląd kwartału")
        meeting.participants = ["Ewa Nowak"]
        let user = TranscriptChunker.mergeUser(meeting: meeting, parts: [
            MeetingNotesPlan.PartNotes(start: 0, end: 1_190, markdown: "## Podsumowanie\n- Pierwsza [0:10]\n"),
            MeetingNotesPlan.PartNotes(start: 1_200, end: 3_725, markdown: "## Zadania\n- Ewa: raport [1:02:05]"),
        ])
        #expect(user == """
        Tytuł: Przegląd kwartału
        Uczestnicy: Ewa Nowak
        Notatki z 2 części spotkania, w kolejności czasu.
        <part>
        Część 1 z 2, od [0:00] do [19:50]:
        ## Podsumowanie
        - Pierwsza [0:10]
        </part>
        <part>
        Część 2 z 2, od [20:00] do [1:02:05]:
        ## Zadania
        - Ewa: raport [1:02:05]
        </part>
        """)
        let closed = TranscriptChunker.mergeUser(meeting: meeting, parts: [], closing: "Scal.")
        #expect(closed.hasSuffix("w kolejności czasu.\n\nScal."))
    }

    @Test func mergeGroupsAlwaysShrink() {
        let meeting = MeetingRecord(title: "Długie")
        let mergeSystem = MeetingPrompts.notesMergeSystem(templateID: "general", customInstructions: nil)
        let small = (0..<5).map { MeetingNotesPlan.PartNotes(start: Double($0), end: Double($0), markdown: "- punkt \($0) [0:0\($0)]") }
        #expect(TranscriptChunker.mergeGroups(small, meeting: meeting, system: mergeSystem) == [0..<5])
        #expect(TranscriptChunker.mergeGroups(Array(small.prefix(1)), meeting: meeting, system: mergeSystem) == [0..<1])
        #expect(TranscriptChunker.mergeGroups([], meeting: meeting, system: mergeSystem).isEmpty)

        let big = String(repeating: "- długi punkt notatek [1:00]\n", count: 200)
        let large = (0..<6).map { MeetingNotesPlan.PartNotes(start: Double($0), end: Double($0), markdown: big) }
        let groups = TranscriptChunker.mergeGroups(large, meeting: meeting, system: mergeSystem, budget: 8_000)
        #expect(groups.count > 1 && groups.count < large.count)
        #expect(groups.flatMap { Array($0) } == Array(0..<6))
        // No two fit at all: pairs, so a round still halves them.
        let pairs = TranscriptChunker.mergeGroups(large, meeting: meeting, system: mergeSystem, budget: 1_000)
        #expect(pairs == [0..<2, 2..<4, 4..<6])
    }

    // MARK: Writer

    private actor Calls {
        private(set) var made: [(system: String, user: String, maxTokens: Int)] = []
        func add(_ system: String, _ user: String, _ maxTokens: Int) -> Int {
            made.append((system, user, maxTokens))
            return made.count
        }
    }

    private final class ProgressLog: Sendable {
        private let lock = OSAllocatedUnfairLock<[[Int]]>(initialState: [])
        func add(_ done: Int, _ total: Int) { lock.withLock { $0.append([done, total]) } }
        var steps: [[Int]] { lock.withLock { $0 } }
    }

    @Test func writerMakesOneCallWhenTheMeetingFits() async throws {
        let (meeting, segments) = Self.meeting(lines: 10)
        let calls = Calls()
        let log = ProgressLog()
        let notes = try await MeetingNotesWriter.write(
            meeting: meeting, segments: segments, templateID: "client",
            progress: { log.add($0, $1) }
        ) { system, user, maxTokens in
            _ = await calls.add(system, user, maxTokens)
            return "## Podsumowanie\n- ok [0:00]"
        }
        #expect(notes == "## Podsumowanie\n- ok [0:00]")
        let made = await calls.made
        #expect(made.count == 1)
        #expect(made.first?.system == MeetingPrompts.notesSystem(templateID: "client", customInstructions: nil))
        // Today's data, then the reminder of the sections and the citations.
        let reminder = MeetingPrompts.notesReminder(templateID: "client")
        #expect(made.first?.user == MeetingNotesPrompt.user(meeting: meeting, segments: segments.filter { !$0.isEcho }) + "\n\n" + reminder)
        #expect(made.first?.maxTokens == MeetingNotesWriter.wholeMaxTokens)
        #expect(log.steps == [[0, 1], [1, 1]])
    }

    @Test func writerNotesEveryPartThenMerges() async throws {
        let (meeting, segments) = Self.meeting(lines: 240)
        let calls = Calls()
        let log = ProgressLog()
        let notes = try await MeetingNotesWriter.write(
            meeting: meeting, segments: segments, templateID: "standup", customInstructions: "Krótko.", budget: 4_000,
            progress: { log.add($0, $1) }
        ) { system, user, maxTokens in
            let number = await calls.add(system, user, maxTokens)
            return "## Podsumowanie\n- notatki \(number) [0:00]"
        }
        let made = await calls.made
        let partSystem = MeetingPrompts.notesSystem(templateID: "standup", customInstructions: "Krótko.")
        let mergeSystem = MeetingPrompts.notesMergeSystem(templateID: "standup", customInstructions: "Krótko.")
        let partCalls = made.filter { $0.system == partSystem }
        #expect(partCalls.count >= 3)
        #expect(partCalls.allSatisfy { $0.maxTokens == MeetingNotesWriter.partMaxTokens && $0.user.contains("Część ") })
        #expect(partCalls.allSatisfy { $0.user.hasSuffix("\n\n" + MeetingPrompts.notesReminder(templateID: "standup")) })
        #expect(made.count == partCalls.count + 1)
        let merge = try #require(made.last)
        #expect(merge.system == mergeSystem)
        #expect(merge.maxTokens == MeetingNotesWriter.mergeMaxTokens)
        #expect(merge.user.hasSuffix("</part>\n\n" + MeetingPrompts.notesMergeReminder(templateID: "standup")))
        for number in 1...partCalls.count {
            #expect(merge.user.contains("- notatki \(number) [0:00]"))
        }
        #expect(notes == "## Podsumowanie\n- notatki \(made.count) [0:00]")
        #expect(log.steps.first == [0, partCalls.count + 1])
        #expect(log.steps.last == [made.count, made.count])
    }

    @Test func writerMergesInRoundsWhenThePartNotesAreLong() async throws {
        let (meeting, segments) = Self.meeting(lines: 240)
        let calls = Calls()
        let long = String(repeating: "- długi punkt notatek z tej części spotkania [0:00]\n", count: 400)
        let notes = try await MeetingNotesWriter.write(
            meeting: meeting, segments: segments, templateID: "general", budget: 4_000
        ) { system, user, maxTokens in
            let number = await calls.add(system, user, maxTokens)
            return "## Podsumowanie\n- wynik \(number) [0:00]\n" + long
        }
        let made = await calls.made
        let mergeSystem = MeetingPrompts.notesMergeSystem(templateID: "general", customInstructions: nil)
        let merges = made.filter { $0.system == mergeSystem }
        let parts = made.count - merges.count
        // Pairs each round: n parts need n - 1 merges.
        #expect(merges.count == parts - 1)
        #expect(notes.hasPrefix("## Podsumowanie\n- wynik \(made.count) [0:00]"))
    }

    @Test func writerStopsAtTheFirstFailedCall() async {
        struct Boom: Error {}
        let (meeting, segments) = Self.meeting(lines: 240)
        let calls = Calls()
        await #expect(throws: Boom.self) {
            _ = try await MeetingNotesWriter.write(meeting: meeting, segments: segments, templateID: "general", budget: 4_000) { system, user, maxTokens in
                if await calls.add(system, user, maxTokens) == 2 { throw Boom() }
                return "- x [0:00]"
            }
        }
        #expect(await calls.made.count == 2)
    }
}
