import Foundation

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

/// AI notes for one meeting: one pass over the whole transcript (a 1 h meeting is ~20-25k
/// tokens). Non-streaming, on `HTTP.meetingLLMSession`, whose timeouts are the only limit, on
/// the stronger model (`MeetingAITask.notes`, `AIRole.features`).
actor MeetingSummarizer {
    /// Answer cap: the five sections of a 2 h meeting fit well under it.
    static let maxTokens = 4_000
    /// Fewer spoken words than this (echo excluded) is not a conversation worth notes.
    static let minimumWords = 5

    private let chat: MeetingChat

    /// - Parameter instructions: the system instructions per task (`MeetingAIInstructions` in the app).
    init(
        session: URLSession = HTTP.meetingLLMSession,
        routes: any AIRouteProviding,
        instructions: @escaping @Sendable (MeetingAITask) -> String? = { MeetingAIInstructions.system(for: $0) }
    ) {
        chat = MeetingChat(session: session, routes: routes, instructions: instructions)
    }

    func summarize(meeting: MeetingRecord, segments: [MeetingSegmentRecord], template: MeetingTemplate) async throws -> (markdown: String, model: String) {
        let task = MeetingAITask.notes(templateID: template.id)
        let route = try await chat.route(for: task)
        let spoken = segments.filter { !$0.isEcho }
        guard spoken.reduce(0, { $0 + WordCounter.count($1.text) }) >= Self.minimumWords else {
            throw MeetingSummaryError.noTranscript
        }
        let user = MeetingNotesPrompt.user(meeting: meeting, segments: spoken)
        let started = ContinuousClock.now

        let reply = try await chat.complete(route: route, task: task, user: user, maxTokens: Self.maxTokens)
        if reply.finishReason == "length" {
            // Cut off notes still beat none; the last section may be incomplete.
            Log.enhancement.notice("Meeting notes reached the \(Self.maxTokens) token cap")
        }
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.enhancement.info("Meeting notes ok in \(ms) ms with \(reply.model, privacy: .public)")
        return (reply.text, reply.model)
    }
}
