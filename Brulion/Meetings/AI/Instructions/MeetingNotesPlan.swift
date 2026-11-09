import Foundation

/// How the AI notes of one meeting get written (`TranscriptChunker.plan`): one call when the
/// whole meeting fits the input budget, otherwise notes for each part and then a merge
/// (PRD 7.4). `MeetingNotesWriter` runs it.
enum MeetingNotesPlan: Sendable, Equatable {
    /// Everything fits one call: the data of `MeetingNotesPrompt.user`, as before.
    case single(user: String)
    /// Too long for one call: notes for each part with the same `MeetingPrompts.notesSystem`,
    /// then `TranscriptChunker.mergeUser` with `MeetingPrompts.notesMergeSystem`.
    case parts([Part])

    /// One part of a long meeting: consecutive lines, never a segment cut in two.
    struct Part: Sendable, Equatable {
        /// 1-based.
        let number: Int
        let count: Int
        /// Meeting seconds of its first and last line.
        let start: Double
        let end: Double
        /// Transcript lines in it (the user's note lines not counted).
        let segmentCount: Int
        /// The data for this part's notes call: the meeting header, which part it is, the
        /// user's note lines of its time span and its transcript lines.
        let user: String
    }

    /// The notes of one part, or of neighboring parts already merged, as a merge call reads them.
    struct PartNotes: Sendable, Equatable {
        let start: Double
        let end: Double
        let markdown: String
    }
}
