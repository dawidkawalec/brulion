import Foundation
import Observation

/// "Wygeneruj ponownie" in the "Notatki AI" tab: writes a meeting's AI notes again with the
/// template the user picked (`MeetingNotesProcessor.regenerate` through `write`). Owned by
/// `AppState`, so a run that takes minutes keeps its spinner when the user looks at another
/// meeting or section meanwhile, and `finishedCount` tells the meeting views to reload.
@MainActor
@Observable
final class MeetingNotesRuns {
    /// Calls done of a notes run that takes several (a long meeting: parts, then merges).
    struct Progress: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    /// Reaches the runs from the notes processor, which is built before them (`AppState`).
    @MainActor
    final class Sink {
        weak var runs: MeetingNotesRuns?

        init() {}

        /// A `MeetingNotesProcessor.onProgress` that reports here from any thread.
        nonisolated func reporter() -> @Sendable (UUID, Int, Int) -> Void {
            { [weak self] id, done, total in
                Task { @MainActor in self?.runs?.report(meetingID: id, done: done, total: total) }
            }
        }
    }

    /// Meetings whose notes are being written now.
    private(set) var running: Set<UUID> = []
    /// Bumped after every run, whatever its outcome (the notes or the error are on the row).
    private(set) var finishedCount = 0
    /// Progress of the notes being written in several calls, per meeting (after a meeting too,
    /// not only for "Wygeneruj ponownie"); gone when the last call is done.
    private(set) var progress: [UUID: Progress] = [:]

    @ObservationIgnored private let write: @Sendable (_ meetingID: UUID, _ templateID: String?) async -> Void

    init(write: @escaping @Sendable (_ meetingID: UUID, _ templateID: String?) async -> Void) {
        self.write = write
    }

    func isRunning(_ meetingID: UUID) -> Bool {
        running.contains(meetingID)
    }

    /// Starts a run (nil template: picked from the title). Nil when one already runs for this
    /// meeting: a second click starts nothing.
    @discardableResult
    func regenerate(meetingID: UUID, templateID: String?) -> Task<Void, Never>? {
        guard running.insert(meetingID).inserted else { return nil }
        let write = self.write
        return Task {
            await write(meetingID, templateID)
            running.remove(meetingID)
            progress[meetingID] = nil
            finishedCount += 1
        }
    }

    /// `done` of `total` calls finished; a run of one call shows no progress.
    func report(meetingID: UUID, done: Int, total: Int) {
        if total > 1, done < total {
            progress[meetingID] = Progress(done: done, total: total)
        } else {
            progress[meetingID] = nil
        }
    }
}
