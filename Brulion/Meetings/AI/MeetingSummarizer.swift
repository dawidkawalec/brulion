import Foundation
import os

enum MeetingSummaryError: LocalizedError, Sendable, Equatable {
    /// No route: no local model ready and the cloud off (or without a key).
    case noKey
    case noTranscript
    case timedOut
    case server(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .noKey:
            return ChatCompletionsError.missingKeyMessage
        case .noTranscript:
            return String(localized: "Za mało rozmowy, żeby zrobić notatki.")
        case .timedOut:
            return String(localized: "AI nie odpowiedziało na czas. Spróbuj ponownie.")
        case .server(let code):
            // A wrong key or the rate limit reads the same as everywhere else in the app.
            switch ChatCompletionsError.forStatus(code) {
            case .unauthorized, .rateLimited:
                return ChatCompletionsError.forStatus(code).errorDescription
            default:
                return String(localized: "Błąd AI (kod \(code)). Spróbuj ponownie.")
            }
        case .empty:
            return String(localized: "AI zwróciło pustą odpowiedź.")
        }
    }
}

/// AI notes for one meeting on the stronger model (`MeetingAITask.notes`, `AIRole.features`):
/// one call when the meeting fits the input budget, otherwise notes per part and a merge
/// (`MeetingNotesWriter`, PRD 7.4; a 1 h meeting is about 20-25k tokens). Non-streaming, on
/// `HTTP.meetingLLMSession`, whose timeouts are the only limit; a local server is kept alive
/// for each call.
actor MeetingSummarizer {
    /// Answer cap of the notes of a whole meeting.
    static let maxTokens = MeetingNotesWriter.wholeMaxTokens
    /// Fewer spoken words than this (echo excluded) is not a conversation worth notes.
    static let minimumWords = 5

    /// Calls done and the calls expected in all (more than one for a long meeting).
    typealias Progress = MeetingNotesWriter.Progress

    private let chat: MeetingChat

    init(session: URLSession = HTTP.meetingLLMSession, routes: any AIRouteProviding) {
        chat = MeetingChat(session: session, routes: routes)
    }

    func summarize(
        meeting: MeetingRecord,
        segments: [MeetingSegmentRecord],
        template: MeetingTemplate,
        progress: Progress? = nil
    ) async throws -> (markdown: String, model: String) {
        let task = MeetingAITask.notes(templateID: template.id)
        _ = try await chat.route(for: task)
        let spoken = segments.filter { !$0.isEcho }
        guard spoken.reduce(0, { $0 + WordCounter.count($1.text) }) >= Self.minimumWords else {
            throw MeetingSummaryError.noTranscript
        }
        let started = ContinuousClock.now
        let chat = self.chat
        let served = ModelBox()
        let markdown = try await MeetingNotesWriter.write(
            meeting: meeting,
            segments: spoken,
            templateID: template.id,
            progress: progress
        ) { system, user, maxTokens in
            let reply = try await chat.complete(task: task, system: system, user: user, maxTokens: maxTokens)
            if reply.finishReason == "length" {
                // Cut off notes still beat none; the last section may be incomplete.
                Log.enhancement.notice("Meeting notes call reached the \(maxTokens) token cap")
            }
            served.set(reply.model)
            return reply.text
        }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingSummaryError.empty }
        let model = served.value ?? ""
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting notes ok in \(ms) ms with \(model, privacy: .public)")
        return (markdown, model)
    }

    /// The model of the last call (every call of one run uses the same route).
    private final class ModelBox: Sendable {
        private let model = OSAllocatedUnfairLock<String?>(initialState: nil)
        var value: String? { model.withLock { $0 } }
        func set(_ value: String) { model.withLock { $0 = value } }
    }
}
