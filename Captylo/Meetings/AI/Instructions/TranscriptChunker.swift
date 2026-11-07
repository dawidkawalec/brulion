import Foundation

/// Splits a long meeting for the AI notes on a local model (PRD 7.4): when the system prompt
/// and the meeting's data pass the input budget, the time-ordered lines (transcript segments
/// and the user's note lines) go into parts on line boundaries, about even in size, each part
/// self-contained (title, participants and which part it is repeated). Token counts are an
/// estimate from the UTF-8 length. Pure functions; `MeetingNotesWriter` runs the calls.
enum TranscriptChunker {
    /// UTF-8 bytes per token of Polish meeting text, behind every estimate here. Lower counts
    /// more tokens, so a smaller value is the safer side.
    static let bytesPerToken = 3.0
    /// Input tokens one call may use, system prompt and data together (PRD 7.4).
    static let defaultInputBudget = 20_000
    /// Tokens the chat template and the rounding of the estimate may add.
    static let overheadTokens = 64

    /// Estimated tokens of `text`.
    static func estimatedTokens(_ text: String) -> Int {
        Int((Double(text.utf8.count) / bytesPerToken).rounded(.up))
    }

    /// Whether one call with this system prompt and data stays within `budget` input tokens.
    static func fits(system: String, user: String, budget: Int = defaultInputBudget) -> Bool {
        estimatedTokens(system) + estimatedTokens(user) + overheadTokens <= budget
    }

    // MARK: Plan

    /// One call with `MeetingNotesPrompt.user` when it fits `budget` together with `system`;
    /// otherwise parts whose data, with `system`, each stay within it. Echo lines never go.
    /// A single line longer than a whole part goes alone in its own part (lines are never cut).
    static func plan(
        meeting: MeetingRecord,
        segments: [MeetingSegmentRecord],
        system: String,
        budget: Int = defaultInputBudget
    ) -> MeetingNotesPlan {
        let spoken = segments.filter { !$0.isEcho }.sorted { $0.start < $1.start }
        let whole = MeetingNotesPrompt.user(meeting: meeting, segments: spoken)
        if fits(system: system, user: whole, budget: budget) {
            return .single(user: whole)
        }
        let lines = timeline(meeting: meeting, segments: spoken)
        // Nothing to split (only a budget smaller than the frame gets here): one call anyway.
        guard !lines.isEmpty else { return .single(user: whole) }
        let header = header(meeting)
        // The frame of a part at its longest: header, part line and the empty tags.
        let frame = render(header: header, partLine: partLine(number: 99, count: 99, start: 359_999, end: 359_999), lines: [])
        let room = budget - estimatedTokens(system) - overheadTokens
        let limit = Int(Double(room) * bytesPerToken) - frame.utf8.count
        let groups = ranges(costs: lines.map { $0.text.utf8.count + 1 }, limit: limit)

        let parts = groups.enumerated().map { offset, range in
            let slice = Array(lines[range])
            let spokenTimes = slice.filter { !$0.isNote }.map(\.time)
            let times = spokenTimes.isEmpty ? slice.map(\.time) : spokenTimes
            let start = times.first ?? 0
            let end = times.last ?? start
            let line = partLine(number: offset + 1, count: groups.count, start: start, end: end)
            return MeetingNotesPlan.Part(
                number: offset + 1,
                count: groups.count,
                start: start,
                end: end,
                segmentCount: spokenTimes.count,
                user: render(header: header, partLine: line, lines: slice)
            )
        }
        return .parts(parts)
    }

    /// Consecutive index ranges over `costs`, in order, covering every index once, each summing
    /// to at most `limit` and about even in size; an item bigger than `limit` is alone in its
    /// range. Empty for no costs.
    static func ranges(costs: [Int], limit: Int) -> [Range<Int>] {
        guard !costs.isEmpty else { return [] }
        let limit = max(1, limit)
        var result: [Range<Int>] = []
        // What the closed ranges left, the open one included.
        var remaining = costs.reduce(0, +)
        var start = 0
        var sum = 0
        for (index, cost) in costs.enumerated() {
            if index > start {
                // The even share of what is left over the ranges it still needs.
                let needed = max(1, (Double(remaining) / Double(limit)).rounded(.up))
                let target = Double(remaining) / needed
                let over = sum + cost > limit
                // Stop at the boundary nearest that share, never at a sliver.
                let nearer = abs(Double(sum) - target) <= abs(Double(sum + cost) - target)
                if over || (Double(sum) >= target / 2 && nearer) {
                    result.append(start..<index)
                    remaining -= sum
                    start = index
                    sum = 0
                }
            }
            sum += cost
        }
        result.append(start..<costs.count)
        return result
    }

    // MARK: Merge

    /// The data of a merge call: the meeting header, then the notes of each part (or of parts
    /// merged before) in time order, each in `<part>` with its time span.
    static func mergeUser(meeting: MeetingRecord, parts: [MeetingNotesPlan.PartNotes]) -> String {
        var blocks = [header(meeting), "Notatki z \(parts.count) części spotkania, w kolejności czasu."]
        for (offset, part) in parts.enumerated() {
            let span = "Część \(offset + 1) z \(parts.count), od \(MeetingTime.stamp(part.start)) do \(MeetingTime.stamp(part.end)):"
            blocks.append("<part>\n\(span)\n\(part.markdown.trimmingCharacters(in: .whitespacesAndNewlines))\n</part>")
        }
        return blocks.joined(separator: "\n")
    }

    /// Neighbors whose notes fit one merge call within `budget`; every range has at least one
    /// item, and for two or more notes there are always fewer ranges than notes, so merging
    /// round by round ends with one. All in one range when it fits.
    static func mergeGroups(
        _ parts: [MeetingNotesPlan.PartNotes],
        meeting: MeetingRecord,
        system: String,
        budget: Int = defaultInputBudget
    ) -> [Range<Int>] {
        guard parts.count > 1 else { return parts.isEmpty ? [] : [0..<1] }
        if fits(system: system, user: mergeUser(meeting: meeting, parts: parts), budget: budget) {
            return [0..<parts.count]
        }
        let frame = mergeUser(meeting: meeting, parts: []).utf8.count
        let room = budget - estimatedTokens(system) - overheadTokens
        let limit = Int(Double(room) * bytesPerToken) - frame
        // Each part also carries its tags and span line.
        let costs = parts.map { $0.markdown.utf8.count + 64 }
        let groups = ranges(costs: costs, limit: limit)
        guard groups.count < parts.count else {
            // No two fit together: merge pairs anyway, so every round makes progress.
            return stride(from: 0, to: parts.count, by: 2).map { $0..<min($0 + 2, parts.count) }
        }
        return groups
    }

    // MARK: Pieces

    /// A transcript or note line as the prompt shows it, with its meeting time.
    private struct Line {
        let time: Double
        let isNote: Bool
        let text: String
    }

    /// The meeting's note lines and spoken segments in time order (a segment before a note
    /// at the same second), rendered like `MeetingNotesPrompt.user` renders them.
    private static func timeline(meeting: MeetingRecord, segments: [MeetingSegmentRecord]) -> [Line] {
        let spoken = segments.map { segment in
            Line(time: segment.start, isNote: false, text: "\(MeetingTime.stamp(segment.start)) \(meeting.promptLabel(for: segment)): \(segment.text)")
        }
        let notes = meeting.noteLines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Line(time: $0.at, isNote: true, text: "\(MeetingTime.stamp($0.at)) \($0.text)") }
        return (spoken + notes).enumerated()
            .sorted { lhs, rhs in
                if lhs.element.time != rhs.element.time { return lhs.element.time < rhs.element.time }
                if lhs.element.isNote != rhs.element.isNote { return !lhs.element.isNote }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// "Tytuł: ..." and, when the calendar named them, "Uczestnicy: ...", as in `MeetingNotesPrompt`.
    private static func header(_ meeting: MeetingRecord) -> String {
        var header = "Tytuł: \(meeting.title)"
        let participants = meeting.participants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !participants.isEmpty {
            header += "\nUczestnicy: " + participants.joined(separator: ", ")
        }
        return header
    }

    private static func partLine(number: Int, count: Int, start: Double, end: Double) -> String {
        "Część \(number) z \(count) dłuższego spotkania, od \(MeetingTime.stamp(start)) do \(MeetingTime.stamp(end)). Notatki pisz tylko z tej części."
    }

    /// One part's data in the layout of `MeetingNotesPrompt.user`, with the part line under
    /// the header.
    private static func render(header: String, partLine: String, lines: [Line]) -> String {
        let notes = lines.filter(\.isNote).map(\.text).joined(separator: "\n")
        let transcript = lines.filter { !$0.isNote }.map(\.text).joined(separator: "\n")
        return """
        \(header)
        \(partLine)
        <user_notes>
        \(notes)
        </user_notes>
        <transcript>
        \(transcript)
        </transcript>
        """
    }
}
