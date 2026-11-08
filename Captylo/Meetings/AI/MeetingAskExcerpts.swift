import Foundation

/// "Zapytaj" about a meeting too long for one call (PRD 7.4, Dawid's decision of 2026-11-08):
/// instead of the whole transcript the model gets the AI notes, the transcript lines with the
/// question's words (each with one neighbor before and after, the lines matching the most
/// words first) and the closing lines, as many as fit the input budget. The words and the
/// closing come from "Zapytaj wszystkie spotkania" (`LibraryAskRetrieval`). Pure functions;
/// `MeetingAsker` runs the call.
enum MeetingAskExcerpts {
    /// Lines from the end of the meeting that always go (decisions and next steps).
    static let closingLines = LibraryAskRetrieval.closingLines

    /// What a long meeting sends, or why it sends nothing.
    enum Plan: Equatable {
        /// The user message, with how many of the hit lines made it in.
        case excerpts(user: String, hits: Int, ofHits: Int)
        /// Not even the header, the notes, the AI notes and the closing lines fit the budget.
        case tooLong
        /// No AI notes and no line with the question's words: nothing to answer from.
        case nothingToGoOn
    }

    /// The user message for `question` about a meeting whose whole transcript does not fit:
    /// `MeetingAskPrompt.excerptUser` with the most hit lines that keep it, with `system` and
    /// `closing` (`MeetingPrompts.askReminder`) after a blank line, within `budget` tokens.
    static func plan(
        question: String,
        meeting: MeetingRecord,
        segments: [MeetingSegmentRecord],
        history: [MeetingQuestion],
        system: String,
        closing: String,
        budget: Int = TranscriptChunker.defaultInputBudget
    ) -> Plan {
        let spoken = segments.filter { !$0.isEcho }.sorted(by: timeOrder)
        let ranked = rankedHits(terms: LibraryAskRetrieval.terms(question) ?? [], in: spoken)
        let summary = (meeting.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ranked.isEmpty || !summary.isEmpty else { return .nothingToGoOn }

        func user(_ count: Int) -> String {
            let picked = runs(hits: ranked.prefix(count), in: spoken)
            return TranscriptChunker.appending(
                closing,
                to: MeetingAskPrompt.excerptUser(meeting: meeting, runs: picked, question: question, history: history)
            )
        }
        func fits(_ count: Int) -> Bool {
            TranscriptChunker.fits(system: system, user: user(count), budget: budget)
        }
        guard fits(0) else { return .tooLong }
        // More hits only add lines, so the largest count that fits is found by bisection.
        var low = 0
        var high = ranked.count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        return .excerpts(user: user(low), hits: low, ofHits: ranked.count)
    }

    /// The lines of `segments` (time order) holding at least one of `terms` (folded stems,
    /// `LibraryAskRetrieval.terms`), compared on the folded text (`MeetingSearch.fold`): the
    /// most distinct terms first, an earlier line first on a tie.
    static func rankedHits(terms: [String], in segments: [MeetingSegmentRecord]) -> [MeetingSegmentRecord] {
        guard !terms.isEmpty else { return [] }
        let scored = segments.enumerated().compactMap { index, segment -> (segment: MeetingSegmentRecord, score: Int, index: Int)? in
            let text = MeetingSearch.fold(segment.text)
            let score = terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            return score > 0 ? (segment, score, index) : nil
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.segment)
    }

    /// Runs of adjacent lines of `segments` (time order, echo already left out): each hit with
    /// one line before and after, plus the last `closingLines` lines. Runs that touch or
    /// overlap merge.
    static func runs(hits: some Sequence<MeetingSegmentRecord>, in segments: [MeetingSegmentRecord]) -> [[MeetingSegmentRecord]] {
        guard !segments.isEmpty else { return [] }
        let position = Dictionary(segments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let last = segments.count - 1
        var keep = Set(max(segments.count - closingLines, 0)...last)
        for hit in hits {
            guard let index = position[hit.id] else { continue }
            keep.formUnion(max(index - 1, 0)...min(index + 1, last))
        }
        var result: [[MeetingSegmentRecord]] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index == previous + 1, !result.isEmpty {
                result[result.count - 1].append(segments[index])
            } else {
                result.append([segments[index]])
            }
            previous = index
        }
        return result
    }

    /// Time order, the id breaking ties so the order never depends on the input order.
    static func timeOrder(_ lhs: MeetingSegmentRecord, _ rhs: MeetingSegmentRecord) -> Bool {
        lhs.start != rhs.start ? lhs.start < rhs.start : lhs.id.uuidString < rhs.id.uuidString
    }
}
