import Foundation

/// Writes the AI notes of one meeting with `TranscriptChunker`'s plan: one call when the
/// meeting fits the input budget; otherwise the notes of each part, one after another (one
/// local model serves one request at a time), then merge calls until one set of notes is left.
/// The chat call itself is injected (`complete`), so this stays free of networking and the
/// summarizer keeps its route, errors and timeouts. Every answer goes through
/// `CitationNormalizer`, so a citation list in one bracket still plays.
enum MeetingNotesWriter {
    /// Answer cap of the notes of a whole meeting (as `MeetingSummarizer.maxTokens`).
    static let wholeMaxTokens = 4_000
    /// Answer cap of one part's notes: short notes keep the merge small.
    static let partMaxTokens = 2_000
    /// Answer cap of a merge.
    static let mergeMaxTokens = 4_000

    /// One chat call: system prompt, user message, answer cap; returns the answer text.
    typealias Complete = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    /// Calls done and the calls expected in all (the total can grow when merges need rounds).
    typealias Progress = @Sendable (_ done: Int, _ total: Int) -> Void

    /// The notes Markdown. Errors of `complete` (and cancellation between calls) end the run.
    static func write(
        meeting: MeetingRecord,
        segments: [MeetingSegmentRecord],
        templateID: String,
        customInstructions: String? = nil,
        budget: Int = TranscriptChunker.defaultInputBudget,
        progress: Progress? = nil,
        complete: Complete
    ) async throws -> String {
        let system = MeetingPrompts.notesSystem(templateID: templateID, customInstructions: customInstructions)
        let reminder = MeetingPrompts.notesReminder(templateID: templateID)
        switch TranscriptChunker.plan(meeting: meeting, segments: segments, system: system, closing: reminder, budget: budget) {
        case .single(let user):
            progress?(0, 1)
            let notes = CitationNormalizer.normalize(try await complete(system, user, wholeMaxTokens))
            progress?(1, 1)
            return notes

        case .parts(let parts):
            let mergeSystem = MeetingPrompts.notesMergeSystem(templateID: templateID, customInstructions: customInstructions)
            let mergeReminder = MeetingPrompts.notesMergeReminder(templateID: templateID)
            var done = 0
            var total = parts.count + 1
            progress?(done, total)
            var notes: [MeetingNotesPlan.PartNotes] = []
            for part in parts {
                try Task.checkCancellation()
                let markdown = CitationNormalizer.normalize(try await complete(system, part.user, partMaxTokens))
                notes.append(MeetingNotesPlan.PartNotes(start: part.start, end: part.end, markdown: markdown))
                done += 1
                progress?(done, total)
            }
            while notes.count > 1 {
                let groups = TranscriptChunker.mergeGroups(notes, meeting: meeting, system: mergeSystem, closing: mergeReminder, budget: budget)
                // This round's merges, plus one more round when it leaves several notes.
                total = done + groups.filter { $0.count > 1 }.count + (groups.count > 1 ? 1 : 0)
                progress?(done, total)
                var merged: [MeetingNotesPlan.PartNotes] = []
                for group in groups {
                    let slice = Array(notes[group])
                    guard slice.count > 1, let first = slice.first, let last = slice.last else {
                        merged += slice
                        continue
                    }
                    try Task.checkCancellation()
                    let user = TranscriptChunker.mergeUser(meeting: meeting, parts: slice, closing: mergeReminder)
                    let markdown = CitationNormalizer.normalize(try await complete(mergeSystem, user, mergeMaxTokens))
                    merged.append(MeetingNotesPlan.PartNotes(start: first.start, end: last.end, markdown: markdown))
                    done += 1
                    progress?(done, total)
                }
                notes = merged
            }
            return notes.first?.markdown ?? ""
        }
    }
}
