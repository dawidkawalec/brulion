import Foundation
import os

/// After a meeting: AI notes from the template picked by the title, stored on the meeting
/// row. Runs after `SpeakerLabelProcessor`, so the transcript already carries "Mówca N".
struct MeetingNotesProcessor: MeetingPostProcessing {
    let database: Database
    let summarizer: MeetingSummarizer
    let isAllowed: @Sendable () async -> Bool
    /// Runs when the notes of a finished meeting were written (the local usage counter).
    var onProcessed: (@Sendable () -> Void)?
    /// Calls done of `total` for a meeting written in several calls (`MeetingNotesRuns.Sink`).
    var onProgress: (@Sendable (_ meetingID: UUID, _ done: Int, _ total: Int) -> Void)?

    func process(meetingID: UUID) async {
        guard await isAllowed() else { return }
        if await regenerate(meetingID: meetingID, templateID: nil) {
            onProcessed?()
        }
    }

    /// Also for "Wygeneruj ponownie" with a template the user picked (nil = pick from the title).
    /// On success stores the notes, template and model and clears the error; on failure stores
    /// the Polish error and keeps earlier notes. True when new notes were written.
    @discardableResult
    func regenerate(meetingID: UUID, templateID: String?) async -> Bool {
        let meeting: MeetingRecord
        let segments: [MeetingSegmentRecord]
        do {
            guard let found = try await database.meeting(id: meetingID) else { return false }
            meeting = found
            segments = try await database.segments(meetingID: meetingID)
        } catch {
            Log.data.error("Meeting notes could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let template = templateID.map(BuiltInMeetingTemplates.template(id:)) ?? BuiltInMeetingTemplates.pick(forTitle: meeting.title)

        let notes: (markdown: String, model: String)?
        let failure: String?
        do {
            let report = onProgress
            notes = try await summarizer.summarize(meeting: meeting, segments: segments, template: template) { done, total in
                report?(meetingID, done, total)
            }
            failure = nil
        } catch {
            Log.enhancement.error("Meeting notes failed: \(error.localizedDescription, privacy: .public)")
            notes = nil
            failure = error.localizedDescription
        }

        // The call can take minutes: change only the AI fields of the row as it is now, in one
        // step, so a title, notes or names edited meanwhile (even while this saves) survive.
        let usedTemplate = template.id
        do {
            try await database.modifyMeeting(id: meetingID) { latest in
                if let notes {
                    latest.summary = notes.markdown
                    latest.summaryModel = notes.model
                    latest.summaryTemplateID = usedTemplate
                    latest.summaryError = nil
                } else if let failure {
                    latest.summaryError = failure
                }
            }
        } catch {
            Log.data.error("Meeting notes could not be saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return notes != nil
    }
}
