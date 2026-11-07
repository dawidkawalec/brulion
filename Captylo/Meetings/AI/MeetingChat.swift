import Foundation
import os

/// One non-streaming AI call over meeting text, shared by the AI notes (`MeetingSummarizer`),
/// the transcript fixes (`MeetingTranscriptCorrector`) and the asks. The route comes from the
/// task's role (`AIRouteProviding`); the messages are the task's instructions as the system
/// message (when there are any, `MeetingAIInstructions`) and the data as the user message.
/// Meeting AI runs in the background with progress, so there is no deadline beyond the
/// session's generous timeouts (`HTTP.meetingLLMSession`). Errors come back as `MeetingSummaryError`.
struct MeetingChat: Sendable {
    /// How long a call waits for its route: the local model server may have to start and load
    /// a model first.
    static let routeTimeout: Duration = .seconds(120)

    let session: URLSession
    let routes: any AIRouteProviding
    /// The instructions of a task; `MeetingAIInstructions.system(for:)` in the app.
    let instructions: @Sendable (MeetingAITask) -> String?

    init(
        session: URLSession,
        routes: any AIRouteProviding,
        instructions: @escaping @Sendable (MeetingAITask) -> String? = { MeetingAIInstructions.system(for: $0) }
    ) {
        self.session = session
        self.routes = routes
        self.instructions = instructions
    }

    struct Reply: Sendable, Equatable {
        /// The answer with any reasoning block stripped; never empty.
        let text: String
        let finishReason: String?
        /// The model that answered, as history keeps it (`AIRoute.model`).
        let model: String
    }

    /// The route for `task`'s role, or `noKey` when there is none.
    func route(for task: MeetingAITask) async throws -> AIRoute {
        guard let route = await routes.route(for: task.role, timeout: Self.routeTimeout) else {
            throw MeetingSummaryError.noKey
        }
        return route
    }

    /// The messages of one call: `system` first when there is one, then the data.
    static func messages(system: String?, user: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        if let system, !system.isEmpty {
            messages.append(.system(system))
        }
        messages.append(.user(user))
        return messages
    }

    /// `maxTokens` is the answer cap.
    func complete(route: AIRoute, task: MeetingAITask, user: String, maxTokens: Int) async throws -> Reply {
        let request = route.client.chatRequest(
            model: route.model,
            messages: Self.messages(system: instructions(task), user: user),
            maxTokens: maxTokens,
            key: route.key
        )
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else {
            Log.enhancement.error("Meeting AI call failed: HTTP \(status)")
            throw MeetingSummaryError.server(status)
        }
        let (content, finishReason) = try route.client.parseChat(data)
        let text = Enhancer.stripReasoning(content ?? "")
        guard !text.isEmpty else { throw MeetingSummaryError.empty }
        return Reply(text: text, finishReason: finishReason, model: route.model)
    }

    /// The body and status of one attempt; a timeout becomes `.timedOut`, any other transport
    /// error the app's network message.
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatCompletionsError.decoding }
            return (data, http.statusCode)
        } catch let error as URLError {
            if error.code == .timedOut { throw MeetingSummaryError.timedOut }
            throw ChatCompletionsError.network(error.localizedDescription)
        }
    }
}
