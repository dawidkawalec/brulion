import Foundation
import Testing
@testable import Captylo

struct EnhancementEnhancerTests {
    private static let raw = "no więc to jest dłuższy testowy transkrypt który ma zdecydowanie więcej niż trzy słowa"
    private static let systemPrompt = CleanupPrompt.system(template: "", vocabulary: [])

    /// An enhancer whose every role goes to a stub server answering with `handler`, or no route
    /// at all when `hasRoute` is false. Returns the fake provider too, to see the roles asked for.
    private func makeEnhancer(
        _ handler: @escaping StubURLProtocol.Handler,
        hasRoute: Bool = true,
        model: String = "bielik-test",
        deadline: Duration = .seconds(3)
    ) -> (Enhancer, FakeAIRoutes, URL) {
        let (route, baseURL) = AIRouteFixtures.stubRoute(model: model, handler)
        let routes = FakeAIRoutes(hasRoute ? route : nil)
        let enhancer = Enhancer(routes: routes, session: StubURLProtocol.makeSession(), deadline: deadline)
        return (enhancer, routes, baseURL)
    }

    // MARK: Roles

    @Test func eachModeAsksForItsRole() async {
        let (enhancer, routes, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: "\"\(Self.raw)\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        // "Czyszczenie" runs on the correction model, every other built-in and custom mode on
        // the features model (PRD 7.2-7.3).
        _ = await enhancer.enhance(Self.raw, mode: BuiltInAIModes.cleanup, vocabulary: [])
        for mode in [BuiltInAIModes.english, BuiltInAIModes.organize, BuiltInAIModes.email, BuiltInAIModes.tasks, AIMode.newCustom()] {
            _ = await enhancer.enhance(Self.raw, mode: mode, vocabulary: [])
        }
        #expect(routes.asked == [.correction, .features, .features, .features, .features, .features])
    }

    @Test func aModesRoleFollowsTheCleanupKeyNotItsKind() {
        #expect(BuiltInAIModes.cleanup.role == .correction)
        #expect(BuiltInAIModes.cleanup.job(vocabulary: []).role == .correction)
        // A custom mode is a feature even when it is a cleanup kind.
        let custom = AIMode(name: "Moje czyszczenie", prompt: "p", kind: .cleanup, deadlineSeconds: 3)
        #expect(custom.role == .features)
        #expect(BuiltInAIModes.english.job(vocabulary: []).role == .features)
        // Note titles use the small model; a plain job defaults to the features model.
        #expect(NoteTitles.job.role == .correction)
        #expect(EnhancementJob(systemPrompt: "p").role == .features)
    }

    @Test func prewarmPassesTheRoleOn() async {
        let routes = FakeAIRoutes(nil)
        let enhancer = Enhancer(routes: routes, session: StubURLProtocol.makeSession())
        await enhancer.prewarm(.correction)
        await enhancer.prewarm(.features)
        #expect(routes.prewarmed == [.correction, .features])
    }

    // MARK: No route

    @Test func noRouteIsSkippedWithoutNetwork() async {
        let counter = Counter()
        let (enhancer, _, baseURL) = makeEnhancer({ _ in
            counter.increment()
            return .json(Fixtures.chat(content: "\"x\"", finish: "stop"))
        }, hasRoute: false)
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        #expect(outcome == .skipped(.noKey))
        #expect(outcome.text == nil, "the raw text is pasted")
        #expect(outcome.note == "Brak modelu AI")
        #expect(counter.value == 0)
    }

    @Test func theUnavailableProviderNeverRoutes() async {
        let provider = UnavailableAIRouteProvider()
        #expect(await provider.route(for: .correction, timeout: .seconds(1)) == nil)
        #expect(await provider.route(for: .features, timeout: .seconds(1)) == nil)
        await provider.prewarm(.features)
        let enhancer = Enhancer(routes: provider, session: StubURLProtocol.makeSession())
        #expect(await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt) == .skipped(.noKey))
    }

    // MARK: enhance

    @Test func returnsEnhancedTextWithTheRoutesModelAndTiming() async throws {
        let cleaned = "Więc to jest dłuższy testowy transkrypt, który ma zdecydowanie więcej niż trzy słowa."
        let (enhancer, _, baseURL) = makeEnhancer({ request in
            #expect(request.url?.path().hasSuffix("/chat/completions") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
            let body = StubURLProtocol.body(of: request)
            #expect(body["model"] as? String == "bielik-1.5b")
            #expect(body["temperature"] as? Double == 0)
            let messages = StubURLProtocol.messages(of: request)
            #expect(messages.map(\.role) == ["system", "user"])
            #expect(messages.last?.content == Self.raw)
            return .json(Fixtures.chat(content: "\"<think>hm</think>\\n\(cleaned)\"", finish: "stop"))
        }, model: "bielik-1.5b")
        defer { StubURLProtocol.unregister(baseURL) }

        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .enhanced(let text, let ms, let model) = outcome else {
            Issue.record("Expected .enhanced, got \(outcome)")
            return
        }
        #expect(text == cleaned)
        // History keeps the route's model as the model name.
        #expect(model == "bielik-1.5b")
        #expect(ms >= 0 && ms < 3000)
    }

    @Test func skipsShortTranscriptsWithoutAskingForARoute() async {
        let counter = Counter()
        let (enhancer, routes, baseURL) = makeEnhancer { _ in
            counter.increment()
            return .json(Fixtures.chat(content: "\"x\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        #expect(await enhancer.enhance("tylko trzy słowa", systemPrompt: Self.systemPrompt) == .skipped(.tooShort))
        #expect(await enhancer.enhance("", systemPrompt: Self.systemPrompt) == .skipped(.tooShort))
        // A rewrite mode still skips empty text.
        #expect(await enhancer.enhance("  ", job: EnhancementJob(systemPrompt: "p", kind: .rewrite)) == .skipped(.tooShort))
        #expect(counter.value == 0)
        #expect(routes.asked.isEmpty)
    }

    @Test func failsOnTruncatedOrEmptyOutput() async {
        let (truncated, _, url1) = makeEnhancer { _ in .json(Fixtures.chat(content: "\"\(Self.raw)\"", finish: "length")) }
        defer { StubURLProtocol.unregister(url1) }
        guard case .failed(.rejected(.truncated), _) = await truncated.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .failed on finish_reason length")
            return
        }

        let (empty, _, url2) = makeEnhancer { _ in .json(Fixtures.chat(content: "null", finish: "stop")) }
        defer { StubURLProtocol.unregister(url2) }
        guard case .failed(.rejected(.empty), _) = await empty.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .failed on null content")
            return
        }
    }

    @Test func failsOnHTTPErrorsWithPolishReason() async {
        let (enhancer, _, baseURL) = makeEnhancer { _ in .json(#"{"error":{"message":"bad key","code":401}}"#, status: 401) }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .failed(let failure, _) = outcome else {
            Issue.record("Expected .failed, got \(outcome)")
            return
        }
        #expect(failure == .http(status: 401))
        #expect(failure.errorDescription == ChatCompletionsError.unauthorized.errorDescription)
        #expect(outcome.note == String(localized: "Błąd AI \(String(401))"))
    }

    @Test func deadlineFailsWithinBudgetAndKeepsTheRawText() async {
        let (enhancer, _, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: "\"late\"", finish: "stop"), delay: .seconds(5))
        }
        defer { StubURLProtocol.unregister(baseURL) }

        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        let elapsed = clock.now - start

        guard case .failed(let failure, let ms) = outcome else {
            Issue.record("Expected .failed on deadline, got \(outcome)")
            return
        }
        #expect(failure == .deadline(seconds: 3))
        #expect(failure.errorDescription == EnhancerError.deadline.errorDescription)
        #expect(outcome.text == nil, "the raw text is pasted")
        #expect(elapsed >= .seconds(2.9), "finished too early: \(elapsed)")
        #expect(elapsed < .seconds(3.3), "deadline overshoot: \(elapsed)")
        #expect(ms >= 2900 && ms < 3300)
    }

    @Test func aRouteThatTakesTheWholeDeadlineFails() async {
        let counter = Counter()
        let (route, baseURL) = AIRouteFixtures.stubRoute { _ in
            counter.increment()
            return .json(Fixtures.chat(content: "\"x\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        // The provider ignores its timeout (a model server still starting): the job's deadline wins.
        let routes = FakeAIRoutes(route, delay: .milliseconds(400))
        let enhancer = Enhancer(routes: routes, session: StubURLProtocol.makeSession(), deadline: .milliseconds(300))
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .failed(.deadline, _) = outcome else {
            Issue.record("Expected .failed(.deadline), got \(outcome)")
            return
        }
        #expect(counter.value == 0)
    }

    @Test func retriesOnceOnConnectionLost() async {
        let counter = Counter()
        let (enhancer, _, baseURL) = makeEnhancer { _ in
            counter.increment()
            if counter.value == 1 {
                return .failure(.networkConnectionLost)
            }
            return .json(Fixtures.chat(content: "\"\(Self.raw)\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        #expect(outcome.text == Self.raw)
        #expect(counter.value == 2)
    }

    @Test func doesNotRetryOtherNetworkErrors() async {
        let counter = Counter()
        let (enhancer, _, baseURL) = makeEnhancer { _ in
            counter.increment()
            return .failure(.notConnectedToInternet)
        }
        defer { StubURLProtocol.unregister(baseURL) }
        guard case .failed = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .failed")
            return
        }
        #expect(counter.value == 1)
    }

    @Test func doesNotRetryWhenBudgetIsTooSmall() async {
        let counter = Counter()
        let (enhancer, _, baseURL) = makeEnhancer({ _ in
            counter.increment()
            return .failure(.networkConnectionLost)
        }, deadline: .milliseconds(500))
        defer { StubURLProtocol.unregister(baseURL) }
        guard case .failed = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt) else {
            Issue.record("Expected .failed")
            return
        }
        #expect(counter.value == 1)
    }

    // MARK: test

    @Test func testSendsATinyCallOnTheRoleAndReportsTheModel() async throws {
        let (enhancer, routes, baseURL) = makeEnhancer({ request in
            #expect(StubURLProtocol.body(of: request)["max_tokens"] as? Int == 1)
            return .json(Fixtures.chat(content: "\"ok\"", finish: "length"), delay: .milliseconds(50))
        }, model: "bielik-1.5b")
        defer { StubURLProtocol.unregister(baseURL) }
        let answer = try await enhancer.test(role: .correction).get()
        #expect(answer.ms >= 40 && answer.ms < 5000)
        #expect(answer.model == "bielik-1.5b")
        #expect(routes.asked == [.correction])
    }

    @Test func testReportsNoRouteAndBadKey() async {
        let (noRoute, _, url1) = makeEnhancer({ _ in .json("{}") }, hasRoute: false)
        defer { StubURLProtocol.unregister(url1) }
        guard case .failure(let missing) = await noRoute.test(role: .features) else {
            Issue.record("Expected failure without a route")
            return
        }
        #expect(missing as? ChatCompletionsError == .missingKey)

        let (badKey, _, url2) = makeEnhancer { _ in .json(#"{"error":{"message":"no","code":401}}"#, status: 401) }
        defer { StubURLProtocol.unregister(url2) }
        guard case .failure(let error) = await badKey.test(role: .features) else {
            Issue.record("Expected failure on 401")
            return
        }
        #expect(error as? ChatCompletionsError == .unauthorized)
    }

    // MARK: Pure rules

    @Test func maxTokensRule() {
        // est = max(16, bytes / 3); cap = min(2048, est * 2 + 64)
        #expect(Enhancer.maxTokens(forUTF8Count: 0) == 96)
        #expect(Enhancer.maxTokens(forUTF8Count: 30) == 96)
        #expect(Enhancer.maxTokens(forUTF8Count: 300) == 264)
        #expect(Enhancer.maxTokens(forUTF8Count: 2900) == 1996)
        #expect(Enhancer.maxTokens(forUTF8Count: 3000) == 2048)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000) == 2048)
    }

    @Test func maxTokensHonorsALargerFileCap() {
        #expect(Enhancer.maxTokens(forUTF8Count: 9000, cap: 8192) == 6064)
        #expect(Enhancer.maxTokens(forUTF8Count: 100_000, cap: 8192) == 8192)
    }

    @Test func fileLLMSessionOutlastsTheFileDeadline() {
        let configuration = HTTP.fileLLMSession.configuration
        #expect(configuration.timeoutIntervalForRequest > 15)
        #expect(configuration.timeoutIntervalForResource > 15)
    }

    @Test func stripsReasoningBlocks() {
        #expect(Enhancer.stripReasoning("<think>plan\nplan</think>\n\nCzysty tekst.") == "Czysty tekst.")
        #expect(Enhancer.stripReasoning("<THINKING>x</THINKING> Tekst <Reasoning>y\nz</Reasoning>") == "Tekst")
        #expect(Enhancer.stripReasoning("  Bez bloków.  ") == "Bez bloków.")
        // An unclosed block swallows the rest, so a leaked chain of thought never gets pasted.
        #expect(Enhancer.stripReasoning("Wynik. <think>nigdy nie zamknięte") == "Wynik.")
        #expect(Enhancer.stripReasoning("<think>a</think><think>b</think>") == "")
    }

    @Test func sanityGuardCases() {
        let long = String(repeating: "słowo ", count: 20)
        #expect(Enhancer.rejectionReason(raw: long, output: "", finishReason: "stop") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: long, finishReason: "length") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: "Tak.", finishReason: "stop") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: long + long + long, finishReason: "stop") != nil)
        #expect(Enhancer.rejectionReason(raw: long, output: long, finishReason: "stop") == nil)
        #expect(Enhancer.rejectionReason(raw: long, output: String(long.prefix(60)), finishReason: nil) == nil)
        // Short transcripts (<= 40 chars) skip the length ratio check.
        #expect(Enhancer.rejectionReason(raw: "krótki tekst do sprawdzenia", output: "Ok", finishReason: "stop") == nil)
    }
}
