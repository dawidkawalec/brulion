import Foundation
import os

/// "Zapytaj" about one meeting: one non-streaming call with the whole transcript and the
/// user's notes (`MeetingAskPrompt`), on `HTTP.meetingLLMSession` and the stronger model
/// (`MeetingAITask.ask`), like the AI notes. A meeting too long for one call sends its AI notes
/// and the lines about the question instead (`MeetingAskExcerpts`). The question and its answer, or the Polish reason it failed,
/// go onto the meeting row in one `modifyMeeting` step, newest last, the newest
/// `maxStoredQuestions` kept. Never logs the question or the answer.
actor MeetingAsker {
    /// Answer cap: a short, cited answer.
    static let maxTokens = 1_500
    /// Questions kept per meeting; the oldest go first.
    static let maxStoredQuestions = 50
    /// A pasted wall of text is cut to this many characters.
    static let maxQuestionLength = 1_000
    /// Fewer words than this in the transcript and notes together (echo excluded) is nothing to ask about.
    static let minimumWords = 5

    static var recordingMessage: String {
        String(localized: "Zapytaj działa po zakończeniu spotkania.")
    }

    static var nothingToAskMessage: String {
        String(localized: "W tym spotkaniu jest za mało rozmowy, żeby odpowiedzieć.")
    }

    /// Not even the AI notes, the user's notes and the closing lines fit one call.
    static var tooLongMessage: String {
        String(localized: "To spotkanie jest za długie, żeby zapytać o nie naraz. Zajrzyj do notatek AI albo zapytaj wszystkie spotkania.")
    }

    /// A long meeting without AI notes and a question that matches no transcript line.
    static var nothingToGoOnMessage: String {
        String(localized: "To spotkanie jest długie, a pytanie nie pasuje do żadnej linii transkryptu i nie ma jeszcze notatek AI. Zapytaj konkretniej, np. o temat, osobę albo kwotę.")
    }

    private let database: Database
    private let chat: MeetingChat

    init(
        database: Database,
        session: URLSession = HTTP.meetingLLMSession,
        routes: any AIRouteProviding
    ) {
        self.database = database
        chat = MeetingChat(session: session, routes: routes)
    }

    /// Asks `question` about the meeting and stores the exchange on its row. Nil (and nothing
    /// sent or stored) for a blank question or a meeting that is not there.
    func ask(meetingID: UUID, question: String) async -> MeetingQuestion? {
        let trimmed = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQuestionLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let meeting: MeetingRecord
        let segments: [MeetingSegmentRecord]
        do {
            guard let found = try await database.meeting(id: meetingID) else { return nil }
            meeting = found
            segments = try await database.segments(meetingID: meetingID)
        } catch {
            Log.data.error("Meeting ask could not read the meeting: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        var asked = MeetingQuestion(question: trimmed)
        do {
            let (answer, model) = try await answer(trimmed, meeting: meeting, segments: segments)
            asked.answer = answer
            asked.model = model
        } catch {
            Log.enhancement.error("Meeting ask failed: \(error.localizedDescription, privacy: .public)")
            asked.error = error.localizedDescription
        }

        // The call can take a while: append to the row as it is now, in one step, so edits and
        // other answers saved meanwhile survive.
        let stored = asked
        do {
            try await database.modifyMeeting(id: meetingID) { latest in
                latest.questions.append(stored)
                if latest.questions.count > Self.maxStoredQuestions {
                    latest.questions.removeFirst(latest.questions.count - Self.maxStoredQuestions)
                }
            }
        } catch {
            Log.data.error("Meeting answer could not be saved: \(error.localizedDescription, privacy: .public)")
        }
        return asked
    }

    private func answer(_ question: String, meeting: MeetingRecord, segments: [MeetingSegmentRecord]) async throws -> (String, String) {
        guard meeting.status != .recording else { throw AskError(message: Self.recordingMessage) }
        _ = try await chat.route(for: .ask)
        let spoken = segments.filter { !$0.isEcho }
        let words = spoken.reduce(WordCounter.count(meeting.notes)) { $0 + WordCounter.count($1.text) }
        guard words >= Self.minimumWords else { throw AskError(message: Self.nothingToAskMessage) }

        let system = MeetingAIInstructions.system(for: .ask)
        let closing = MeetingPrompts.askReminder()
        var user = TranscriptChunker.appending(
            closing,
            to: MeetingAskPrompt.user(meeting: meeting, segments: spoken, question: question, history: meeting.questions)
        )
        // Over the input budget the whole meeting would not fit the model: the AI notes and the
        // lines about the question go instead (Dawid, 8.11).
        if !TranscriptChunker.fits(system: system, user: user) {
            switch MeetingAskExcerpts.plan(
                question: question, meeting: meeting, segments: spoken,
                history: meeting.questions, system: system, closing: closing
            ) {
            case .excerpts(let excerpted, let hits, let total):
                Log.enhancement.info("Meeting ask on excerpts: \(hits) of \(total) hit lines")
                user = excerpted
            case .tooLong:
                throw AskError(message: Self.tooLongMessage)
            case .nothingToGoOn:
                throw AskError(message: Self.nothingToGoOnMessage)
            }
        }
        let started = ContinuousClock.now
        let reply = try await chat.complete(task: .ask, system: system, user: user, maxTokens: Self.maxTokens)
        if reply.finishReason == "length" {
            Log.enhancement.notice("Meeting answer reached the \(Self.maxTokens) token cap")
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting ask ok in \(ms) ms with \(reply.model, privacy: .public)")
        return (CitationNormalizer.normalize(reply.text), reply.model)
    }

    /// A reason not to call the AI, shown as it is.
    private struct AskError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
