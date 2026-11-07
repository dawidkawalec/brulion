import Foundation

/// AI cleanup with one hard deadline (gotchas 64, 65, 68). Never throws: any failure yields
/// `.failed` and the caller pastes the raw transcript.
///
/// Each call asks `routes` for the job's role first (`AIRole`, within the deadline): the local
/// model server or Bielik in the cloud. No route = `.skipped(.noKey)`, the raw text stays.
actor Enhancer: TextEnhancing {
    /// Transcripts with this many words or fewer skip the model.
    static let minimumWords = 4
    /// Budget that must remain for the single connection-lost retry.
    static let retryBudget: Duration = .milliseconds(800)
    /// Budget for the settings "Test" call (not on the hot path).
    static let utilityDeadline: Duration = .seconds(10)

    /// Output cap of the brief's `max_tokens` rule for dictation.
    static let defaultTokenCap = 2048
    /// Output cap of a rewrite mode on the dictation path.
    static let rewriteTokenCap = 4096

    private let routes: any AIRouteProviding
    private let session: URLSession
    private let deadline: Duration
    private let tokenCap: Int

    init(
        routes: any AIRouteProviding,
        session: URLSession = HTTP.llmSession,
        deadline: Duration = .seconds(3),
        tokenCap: Int = Enhancer.defaultTokenCap
    ) {
        self.routes = routes
        self.session = session
        self.deadline = deadline
        self.tokenCap = tokenCap
    }

    // MARK: TextEnhancing

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        guard !Self.shouldSkip(raw, kind: job.kind) else { return .skipped(.tooShort) }
        let deadline = job.deadline ?? self.deadline

        // The route lookup counts against the deadline: a model server that is still starting
        // or an ACL prompt must not hold the widget.
        let clock = ContinuousClock()
        let start = clock.now
        guard let route = await routes.route(for: job.role, timeout: deadline) else {
            return .skipped(.noKey)
        }
        guard clock.now - start < deadline else {
            Log.enhancement.error("AI skipped: the route took longer than the deadline")
            return .failed(.deadline(seconds: Self.seconds(deadline)), ms: Self.milliseconds(clock.now - start))
        }

        let maxTokens = Self.maxTokens(forUTF8Count: raw.utf8.count, kind: job.kind, cap: tokenCap)
        let request = route.client.chatRequest(
            model: route.model,
            system: job.systemPrompt,
            transcript: raw,
            maxTokens: maxTokens,
            key: route.key
        )
        let signpost = Log.signposter.beginInterval("enhance")
        defer { Log.signposter.endInterval("enhance", signpost) }

        do {
            let (data, http) = try await sendWithRetry(request, deadline: deadline, start: start, clock: clock)
            let ms = Self.milliseconds(clock.now - start)
            if ChatCompletionsClient.mapStatus(http.statusCode) != nil {
                Log.enhancement.error("AI failed: HTTP \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                return .failed(.http(status: http.statusCode), ms: ms)
            }
            let (content, finishReason) = try route.client.parseChat(data)
            let text = Self.stripReasoning(content ?? "")
            if let rejection = Self.rejectionReason(raw: raw, output: text, finishReason: finishReason, kind: job.kind) {
                Log.enhancement.notice("AI output rejected: \(rejection.errorDescription, privacy: .public)")
                return .failed(.rejected(rejection), ms: ms)
            }
            Log.enhancement.info("AI \(job.kind.rawValue, privacy: .public) (\(job.role.rawValue, privacy: .public)) ok in \(ms) ms with \(route.model, privacy: .public), \(route.kind.rawValue, privacy: .public)")
            return .enhanced(text: text, ms: ms, model: route.model)
        } catch {
            let ms = Self.milliseconds(clock.now - start)
            let failure = Self.failure(for: error, deadline: deadline)
            Log.enhancement.error("AI failed after \(ms) ms: \(failure.errorDescription ?? "", privacy: .public)")
            return .failed(failure, ms: ms)
        }
    }

    /// Starts or warms whatever serves `role` (the model server, the cloud connection); the
    /// provider debounces.
    func prewarm(_ role: AIRole) async {
        await routes.prewarm(role)
    }

    // MARK: Settings helpers

    /// "Testuj" in Modele: a one-token call on the route `role` uses now. The round trip in
    /// milliseconds and the model that answered.
    func test(role: AIRole) async -> Result<(ms: Int, model: String), any Error> {
        guard let route = await routes.route(for: role, timeout: Self.utilityDeadline) else {
            return .failure(ChatCompletionsError.missingKey)
        }
        let request = route.client.chatRequest(
            model: route.model,
            system: "Odpowiedz jednym słowem: ok.",
            transcript: "ok",
            maxTokens: 1,
            key: route.key
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, http) = try await Self.send(request, using: session, budget: Self.utilityDeadline)
            if let error = ChatCompletionsClient.mapStatus(http.statusCode) {
                Log.enhancement.error("Model test failed: HTTP \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                return .failure(error)
            }
            _ = try route.client.parseChat(data)
            return .success((Self.milliseconds(clock.now - start), route.model))
        } catch {
            return .failure(Self.wrapped(error))
        }
    }

    // MARK: Rules (pure, unit-tested)

    /// `est = max(16, utf8Count / 3)`; cleanup `min(cap, est * 2 + 64)` (brief 5.3), rewrite
    /// `min(max(4096, cap), est * 3 + 256)` (a translation or an e-mail may grow).
    nonisolated static func maxTokens(
        forUTF8Count count: Int,
        kind: AIModeKind = .cleanup,
        cap: Int = defaultTokenCap
    ) -> Int {
        let estimate = max(16, count / 3)
        switch kind {
        case .cleanup:
            return min(cap, estimate * 2 + 64)
        case .rewrite:
            return min(max(rewriteTokenCap, cap), estimate * 3 + 256)
        }
    }

    /// Cleanup skips 3 words or fewer (latency, and a short phrase gains nothing); a rewrite
    /// runs on any non-empty text (translating "dzień dobry" is still useful).
    nonisolated static func shouldSkip(_ raw: String, kind: AIModeKind) -> Bool {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        switch kind {
        case .cleanup: return WordCounter.count(raw) < minimumWords
        case .rewrite: return false
        }
    }

    /// Removes `<think>`, `<thinking>` and `<reasoning>` blocks (case-insensitive, across lines;
    /// an unclosed block swallows the rest) and trims whitespace.
    nonisolated static func stripReasoning(_ text: String) -> String {
        var output = text
        for pattern in Self.reasoningPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanity guard (gotcha 68): nil when the output is acceptable. Every kind rejects an empty
    /// or cut-off answer; only cleanup also checks the 0.4...2.5 length ratio (raw > 40 chars),
    /// because a rewrite may legitimately shrink (checklist) or grow (e-mail).
    nonisolated static func rejectionReason(
        raw: String,
        output: String,
        finishReason: String?,
        kind: AIModeKind = .cleanup
    ) -> EnhancementRejection? {
        if output.isEmpty {
            return .empty
        }
        if finishReason == "length" {
            return .truncated
        }
        if kind == .cleanup, raw.count > 40 {
            let ratio = Double(output.count) / Double(raw.count)
            if ratio < 0.4 { return .tooShort }
            if ratio > 2.5 { return .tooLong }
        }
        return nil
    }

    /// Maps a thrown transport or parse error to the failure kept in the outcome.
    nonisolated static func failure(for error: any Error, deadline: Duration) -> EnhancementFailure {
        switch error {
        case EnhancerError.deadline:
            return .deadline(seconds: seconds(deadline))
        case let error as ChatCompletionsError:
            if let status = error.status { return .http(status: status) }
            if case .network(let detail) = error { return .network(detail) }
            return .invalidResponse
        case let error as URLError:
            return .network(error.localizedDescription)
        default:
            return .network((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static let reasoningPatterns = [
        #"<think>.*?(</think>|\z)"#,
        #"<thinking>.*?(</thinking>|\z)"#,
        #"<reasoning>.*?(</reasoning>|\z)"#,
    ]

    // MARK: Transport

    /// One attempt, plus one immediate retry on connection-lost / TLS failure when > 0.8 s remains.
    private func sendWithRetry(
        _ request: URLRequest,
        deadline: Duration,
        start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) async throws -> (Data, HTTPURLResponse) {
        let budget = deadline - (clock.now - start)
        guard budget > .zero else { throw EnhancerError.deadline }
        do {
            return try await Self.send(request, using: session, budget: budget)
        } catch let error as URLError where Self.isRetryable(error) {
            let remaining = deadline - (clock.now - start)
            guard remaining > Self.retryBudget else { throw error }
            Log.enhancement.notice("Retrying cleanup after \(error.code.rawValue) with \(Self.milliseconds(remaining)) ms left")
            return try await Self.send(request, using: session, budget: remaining)
        }
    }

    /// Races the request against `Task.sleep` (gotcha 65): the request task is cancelled on timeout.
    nonisolated static func send(_ request: URLRequest, using session: URLSession, budget: Duration) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await session.data(for: request)
            }
            group.addTask {
                try await Task.sleep(for: budget)
                throw EnhancerError.deadline
            }
            defer { group.cancelAll() }
            guard let (data, response) = try await group.next() else {
                throw EnhancerError.deadline
            }
            guard let http = response as? HTTPURLResponse else {
                throw ChatCompletionsError.decoding
            }
            return (data, http)
        }
    }

    private nonisolated static func isRetryable(_ error: URLError) -> Bool {
        error.code == .networkConnectionLost || error.code == .secureConnectionFailed
    }

    private nonisolated static func wrapped(_ error: any Error) -> any Error {
        if error is ChatCompletionsError || error is EnhancerError { return error }
        return ChatCompletionsError.network(error.localizedDescription)
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

enum EnhancerError: LocalizedError, Sendable, Equatable {
    case deadline

    var errorDescription: String? {
        switch self {
        case .deadline:
            return String(localized: "Model nie odpowiedział na czas.")
        }
    }
}
