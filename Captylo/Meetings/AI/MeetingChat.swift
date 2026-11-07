import Foundation
import os

/// One non-streaming AI call over meeting text, shared by the AI notes (`MeetingSummarizer`),
/// the transcript fixes (`MeetingTranscriptCorrector`) and the asks. The route comes from the
/// task's role (`AIRouteProviding`); the messages are the open Polish instructions
/// (`MeetingPrompts`) as the system message and the data as the user message, at temperature
/// 0.2. Meeting AI runs in the background with progress, so there is no deadline beyond the
/// session's generous timeouts (`HTTP.meetingLLMSession`). Errors come back as `MeetingSummaryError`.
struct MeetingChat: Sendable {
    /// How long a call waits for its route: the local model server may have to start and load
    /// a model first.
    static let routeTimeout: Duration = .seconds(120)
    /// Meeting answers read better with a little freedom than at 0 (meeting prompt trials).
    static let temperature = 0.2

    let session: URLSession
    let routes: any AIRouteProviding

    init(session: URLSession, routes: any AIRouteProviding) {
        self.session = session
        self.routes = routes
    }

    struct Reply: Sendable, Equatable {
        /// The answer with any reasoning block stripped; never empty.
        let text: String
        let finishReason: String?
        /// The model that answered, as history keeps it (`AIRoute.model`).
        let model: String
    }

    /// The route for `task`'s role, or `noKey` when there is none (checked before any work).
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

    /// One call on the route of `task`'s role. A local model server is kept alive while the
    /// call runs (a long meeting can take minutes, longer than the idle stop), `noKey` without
    /// a route. `maxTokens` is the answer cap.
    func complete(task: MeetingAITask, system: String?, user: String, maxTokens: Int) async throws -> Reply {
        let reply = try await routes.withRoute(for: task.role, timeout: Self.routeTimeout) { route in
            try await self.complete(route: route, system: system, user: user, maxTokens: maxTokens)
        }
        guard let reply else { throw MeetingSummaryError.noKey }
        return reply
    }

    /// One call on `route`. `maxTokens` is the answer cap.
    func complete(route: AIRoute, system: String?, user: String, maxTokens: Int) async throws -> Reply {
        let request = route.client.chatRequest(
            model: route.model,
            messages: Self.messages(system: system, user: user),
            maxTokens: maxTokens,
            key: route.key,
            temperature: Self.temperature
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
