import Foundation

/// AI cleanup with one hard deadline (gotchas 64, 65, 68). Never throws: any failure yields
/// `.failed` and the caller pastes the raw transcript.
///
/// Each call asks `routes` for the job's role first (`AIRole`, within the deadline): the local
/// model server or Bielik in the cloud. No route = `.skipped(.noKey)`, the raw text stays.
///
/// A cleanup job (PRD 7.2) sends the few-shot conversation with the transcript in `<tekst>` tags
/// (`CleanupPrompt.messages`) at temperature 0 with `max_tokens` = words x 3 + 32, and its answer
/// goes through `CorrectionGuard`: the merged text is pasted, or the raw text when the guard
/// rejects it. A rewrite job sends the system prompt and the bare transcript.
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

    /// The lowercased words of an answer the system spell checker accepts (`CorrectionSpelling`).
    typealias Spelling = @Sendable (String) async -> Set<String>
    /// Records a usage event (`LocalUsageStats`); never with any text.
    typealias UsageRecorder = @Sendable (LocalUsageEvent) -> Void

    private let routes: any AIRouteProviding
    private let session: URLSession
    private let deadline: Duration
    private let tokenCap: Int
    private let adaptsDeadline: Bool
    private let spelling: Spelling
    private let usage: UsageRecorder?

    /// - Parameters:
    ///   - deadline: the limit of a job that names none.
    ///   - adaptsDeadline: stretch every limit to the local-model limit for the input
    ///     (`LocalDeadline`, PRD 5), as the app does on the local and the cloud route alike.
    ///   - spelling: the spell check of the guard's merge; the system dictionaries by default.
    ///   - usage: where accepted and rejected corrections, mode uses and timeouts are counted.
    init(
        routes: any AIRouteProviding,
        session: URLSession = HTTP.llmSession,
        deadline: Duration = .seconds(3),
        tokenCap: Int = Enhancer.defaultTokenCap,
        adaptsDeadline: Bool = false,
        spelling: @escaping Spelling = { await CorrectionSpelling.knownWords(in: $0) },
        usage: UsageRecorder? = nil
    ) {
        self.routes = routes
        self.session = session
        self.deadline = deadline
        self.tokenCap = tokenCap
        self.adaptsDeadline = adaptsDeadline
        self.spelling = spelling
        self.usage = usage
    }

    // MARK: TextEnhancing

    func enhance(_ raw: String, job: EnhancementJob) async -> EnhancementOutcome {
        guard !Self.shouldSkip(raw, kind: job.kind) else { return .skipped(.tooShort) }
        let deadline = Self.deadline(for: job, input: raw, fallback: self.deadline, adaptive: adaptsDeadline)

        // The route lookup counts against the deadline: a model server that is still starting
        // or an ACL prompt must not hold the widget.
        let clock = ContinuousClock()
        let start = clock.now
        guard let route = await routes.route(for: job.role, timeout: deadline) else {
            // A local server still starting gives up exactly at the deadline: that is a timeout,
            // not a missing model.
            if clock.now - start >= deadline - .milliseconds(50) {
                Log.enhancement.error("AI skipped: no route within the deadline")
                usage?(.timeout(LocalRole(job.role)))
                return .failed(.deadline(seconds: Self.seconds(deadline)), ms: Self.milliseconds(clock.now - start))
            }
            return .skipped(.noKey)
        }
        guard clock.now - start < deadline else {
            Log.enhancement.error("AI skipped: the route took longer than the deadline")
            usage?(.timeout(LocalRole(job.role)))
            return .failed(.deadline(seconds: Self.seconds(deadline)), ms: Self.milliseconds(clock.now - start))
        }

        let request = route.client.chatRequest(
            model: route.model,
            messages: Self.messages(for: job, raw: raw),
            maxTokens: Self.maxTokens(for: raw, kind: job.kind, cap: tokenCap),
            key: route.key
        )
        if let usageID = job.usageID {
            usage?(.modeUsed(id: usageID))
        }
        let signpost = Log.signposter.beginInterval("enhance")
        defer { Log.signposter.endInterval("enhance", signpost) }

        do {
            let (data, http) = try await sendWithRetry(request, deadline: deadline, start: start, clock: clock)
            if ChatCompletionsClient.mapStatus(http.statusCode) != nil {
                Log.enhancement.error("AI failed: HTTP \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                return .failed(.http(status: http.statusCode), ms: Self.milliseconds(clock.now - start))
            }
            let (content, finishReason) = try route.client.parseChat(data)
            var text = Self.stripReasoning(content ?? "")
            if job.kind == .cleanup {
                text = CleanupPrompt.unwrap(text)
            }
            if let rejection = Self.rejectionReason(output: text, finishReason: finishReason) {
                let ms = Self.milliseconds(clock.now - start)
                Log.enhancement.notice("AI output rejected: \(rejection.errorDescription, privacy: .public)")
                if job.kind == .cleanup {
                    usage?(.correctionRejected(reason: rejection == .empty ? "empty" : "truncated", milliseconds: ms))
                }
                return .failed(.rejected(rejection), ms: ms)
            }
            if job.kind == .cleanup {
                return await guarded(raw: raw, output: text, job: job, model: route.model, ms: Self.milliseconds(clock.now - start))
            }
            let ms = Self.milliseconds(clock.now - start)
            Log.enhancement.info("AI \(job.kind.rawValue, privacy: .public) (\(job.role.rawValue, privacy: .public)) ok in \(ms) ms with \(route.model, privacy: .public), \(route.kind.rawValue, privacy: .public)")
            return .enhanced(text: text, ms: ms, model: route.model)
        } catch {
            let ms = Self.milliseconds(clock.now - start)
            let failure = Self.failure(for: error, deadline: deadline)
            if case .deadline = failure {
                usage?(.timeout(LocalRole(job.role)))
            }
            Log.enhancement.error("AI failed after \(ms) ms: \(failure.errorDescription ?? "", privacy: .public)")
            return .failed(failure, ms: ms)
        }
    }

    /// A cleanup answer through `CorrectionGuard`: the merged text, or a rejection (the caller
    /// then pastes the raw text). Counted as an accepted or rejected correction.
    private func guarded(raw: String, output: String, job: EnhancementJob, model: String, ms: Int) async -> EnhancementOutcome {
        let known = await spelling(output)
        let outcome = CorrectionGuard.apply(
            raw: raw,
            output: output,
            vocabulary: Set(job.vocabulary),
            spellCheck: CorrectionSpelling.lookup(known)
        )
        if let rejection = outcome.rejection {
            Log.enhancement.notice("Correction rejected by the guard: \(rejection.code, privacy: .public)")
            usage?(.correctionRejected(reason: rejection.code, milliseconds: ms))
            return .failed(.rejected(EnhancementRejection(rejection)), ms: ms)
        }
        if let merge = outcome.merge {
            Log.enhancement.info("Correction ok in \(ms) ms with \(model, privacy: .public): \(merge.acceptedEdits) edits, \(merge.revertedWords) reverted, \(merge.droppedWords) dropped")
        }
        usage?(.correctionAccepted(milliseconds: ms))
        return .enhanced(text: outcome.text, ms: ms, model: model)
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

    /// What a job sends: a cleanup the few-shot conversation with the wrapped transcript
    /// (`CleanupPrompt.messages`), a rewrite its system prompt and the bare transcript.
    nonisolated static func messages(for job: EnhancementJob, raw: String) -> [ChatMessage] {
        switch job.kind {
        case .cleanup: CleanupPrompt.messages(system: job.systemPrompt, transcript: raw)
        case .rewrite: [.system(job.systemPrompt), .user(raw)]
        }
    }

    /// The call's limit: the job's own (or `fallback`); when `adaptive`, stretched to the
    /// local-model limit for this input (`LocalDeadline`: cleanup or modes, PRD 5) and never past
    /// that kind's cap (15 s cleanup, 30 s modes).
    nonisolated static func deadline(for job: EnhancementJob, input: String, fallback: Duration, adaptive: Bool) -> Duration {
        let fixed = job.deadline ?? fallback
        guard adaptive else { return fixed }
        let kind: LocalDeadline.Kind = job.kind == .cleanup ? .cleanup : .mode
        let local = LocalDeadline.limit(for: kind, input: input)
        let cap = Duration.milliseconds(Int((LocalDeadline.cap(kind) * 1000).rounded()))
        return min(max(fixed, local), cap)
    }

    /// Cleanup: input words x 3 + 32 (F0), at most `cap`. Rewrite: `est = max(16, utf8Count / 3)`,
    /// `min(max(4096, cap), est * 3 + 256)` (a translation or an e-mail may grow).
    nonisolated static func maxTokens(for text: String, kind: AIModeKind, cap: Int = defaultTokenCap) -> Int {
        switch kind {
        case .cleanup:
            return min(cap, LocalDeadline.wordCount(text) * 3 + 32)
        case .rewrite:
            let estimate = max(16, text.utf8.count / 3)
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

    /// Sanity check of every answer (gotcha 68): nil when it is usable. An empty or cut-off
    /// answer is rejected; a cleanup answer then goes through `CorrectionGuard` (merge, length
    /// and word similarity), a rewrite may legitimately shrink (checklist) or grow (e-mail).
    nonisolated static func rejectionReason(output: String, finishReason: String?) -> EnhancementRejection? {
        if output.isEmpty {
            return .empty
        }
        if finishReason == "length" {
            return .truncated
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
