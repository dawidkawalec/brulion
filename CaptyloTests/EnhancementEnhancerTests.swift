import Foundation
import os
import Testing
@testable import Captylo

/// Collects the usage events an enhancer records.
final class UsageEvents: Sendable {
    private let events = OSAllocatedUnfairLock<[LocalUsageEvent]>(initialState: [])
    var all: [LocalUsageEvent] { events.withLock { $0 } }
    func record(_ event: LocalUsageEvent) { events.withLock { $0.append(event) } }
}

struct EnhancementEnhancerTests {
    private static let raw = "no więc to jest dłuższy testowy transkrypt który ma zdecydowanie więcej niż trzy słowa"
    private static let systemPrompt = CleanupPrompt.system(template: "", vocabulary: [], kind: .cleanup)

    /// A spell check that knows every word of the answer (the merge then judges by the rules alone).
    static let knowsEverything: Enhancer.Spelling = { text in
        Set(CorrectionMerger.tokenize(text).map { $0.core.lowercased() })
    }

    /// An enhancer whose every role goes to a stub server answering with `handler`, or no route
    /// at all when `hasRoute` is false. Returns the fake provider too, to see the roles asked for.
    private func makeEnhancer(
        _ handler: @escaping StubURLProtocol.Handler,
        hasRoute: Bool = true,
        model: String = "bielik-test",
        deadline: Duration = .seconds(3),
        usage: UsageEvents? = nil
    ) -> (Enhancer, FakeAIRoutes, URL) {
        let (route, baseURL) = AIRouteFixtures.stubRoute(model: model, handler)
        let routes = FakeAIRoutes(hasRoute ? route : nil)
        var recorder: Enhancer.UsageRecorder?
        if let usage {
            recorder = { event in usage.record(event) }
        }
        let enhancer = Enhancer(
            routes: routes,
            session: StubURLProtocol.makeSession(),
            deadline: deadline,
            spelling: Self.knowsEverything,
            usage: recorder
        )
        return (enhancer, routes, baseURL)
    }

    /// `text` as the JSON string literal `Fixtures.chat` expects.
    private static func json(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Roles

    @Test func eachModeAsksForItsRole() async {
        let (enhancer, routes, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: Self.json(Self.raw), finish: "stop"))
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

    // MARK: The cleanup request

    @Test func cleanupSendsTheFewShotConversationAtTemperatureZero() async throws {
        let cleaned = "No więc to jest dłuższy testowy transkrypt, który ma zdecydowanie więcej niż trzy słowa."
        let (enhancer, _, baseURL) = makeEnhancer({ request in
            #expect(request.url?.path().hasSuffix("/chat/completions") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
            let body = StubURLProtocol.body(of: request)
            #expect(body["model"] as? String == "bielik-1.5b")
            #expect(body["temperature"] as? Double == 0)
            // Input words x 3 + 32 (F0): 14 words.
            #expect(body["max_tokens"] as? Int == 14 * 3 + 32)
            let messages = StubURLProtocol.messages(of: request)
            #expect(messages.map(\.role) == ["system", "user", "assistant", "user", "assistant", "user"])
            #expect(messages.first?.content == Self.systemPrompt)
            #expect(messages[1].content.hasPrefix("<tekst>\nyyy dobra"))
            #expect(messages.last?.content == "<tekst>\n" + Self.raw + "\n</tekst>")
            // The model echoes the tags and thinks first: both are stripped.
            return .json(Fixtures.chat(content: Self.json("<think>hm</think>\n<tekst>\n\(cleaned)\n</tekst>"), finish: "stop"))
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

    @Test func aCustomCleanupTemplateKeepsTheFewShotAndTheWrapping() async throws {
        let mode = AIMode(name: "Mój prompt", prompt: "Popraw tylko interpunkcję.", kind: .cleanup, deadlineSeconds: 3)
        let (enhancer, _, baseURL) = makeEnhancer { request in
            let messages = StubURLProtocol.messages(of: request)
            #expect(messages.first?.content == "Popraw tylko interpunkcję.")
            #expect(messages.count == 6)
            #expect(messages.last?.content.hasPrefix("<tekst>\n") == true)
            return .json(Fixtures.chat(content: Self.json(Self.raw), finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        #expect(await enhancer.enhance(Self.raw, mode: mode, vocabulary: []).text != nil)
    }

    @Test func aRewriteSendsTheBareTranscript() async throws {
        let (enhancer, _, baseURL) = makeEnhancer { request in
            let messages = StubURLProtocol.messages(of: request)
            #expect(messages.map(\.role) == ["system", "user"])
            #expect(messages.last?.content == Self.raw)
            return .json(Fixtures.chat(content: "\"A longer English text with every idea kept and nothing else.\"", finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, mode: BuiltInAIModes.english, vocabulary: [])
        #expect(outcome.text == "A longer English text with every idea kept and nothing else.")
    }

    // MARK: The guard

    @Test func theGuardRevertsAnUnsafeWordAndKeepsTheSafeEdits() async {
        let raw = "zrób mi jeszcze listę rzeczy na jutro i wyślij ją do zespołu"
        // The small model turned the imperative into the first person: the merge puts it back.
        let (enhancer, _, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: Self.json("Zrobię mi jeszcze listę rzeczy na jutro i wyślij ją do zespołu."), finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(raw, mode: BuiltInAIModes.cleanup, vocabulary: [])
        guard case .enhanced(let text, _, _) = outcome else {
            Issue.record("Expected .enhanced, got \(outcome)")
            return
        }
        #expect(text.hasPrefix("Zrób mi jeszcze"))
        #expect(text.hasSuffix("do zespołu."))
    }

    @Test func anAnswerToTheDictatedQuestionIsMergedBackToTheDictation() async {
        let raw = "czy możesz mi powiedzieć jaka jest jutro pogoda w Krakowie bo jadę na spotkanie"
        // The model answered the question instead of cleaning it: none of its words survive
        // the merge, so the dictation itself is pasted.
        let (enhancer, _, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: Self.json("Niestety nie mam dostępu do prognozy pogody, sprawdź serwis meteorologiczny."), finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(raw, mode: BuiltInAIModes.cleanup, vocabulary: [])
        if let text = outcome.text {
            #expect(CorrectionGuard.words(text) == CorrectionGuard.words(raw), "no word of the answer may survive: \(text)")
        }
    }

    @Test func aRejectedAnswerPastesTheRawText() async {
        // Fillers the model may drop, but the merged text is then under half the dictation's
        // length: the guard rejects it and the raw text is pasted.
        let raw = "yyy eee yyy mmm eee yyy hmm eee yyy dobra wyślij to"
        let usage = UsageEvents()
        let (enhancer, _, baseURL) = makeEnhancer({ _ in
            .json(Fixtures.chat(content: Self.json("Dobra, wyślij to."), finish: "stop"))
        }, usage: usage)
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(raw, mode: BuiltInAIModes.cleanup, vocabulary: [])
        guard case .failed(.rejected(let rejection), _) = outcome else {
            Issue.record("Expected a rejection, got \(outcome)")
            return
        }
        #expect(rejection == .tooShort)
        #expect(outcome.text == nil, "the raw text is pasted")
        #expect(usage.all.contains(where: { event in
            if case .correctionRejected(let reason, _) = event { return reason == "tooShort" }
            return false
        }))
    }

    @Test func theGuardLetsALearnedTermThrough() async {
        let raw = "wrzuć to do supabejs i daj znać jak skończysz bo czekam na to"
        let mode = BuiltInAIModes.cleanup
        let learned = LearningPromptContext(misheard: [TermCorrection(misheard: "supabejs", correct: "Supabase")])
        let (enhancer, _, baseURL) = makeEnhancer { _ in
            .json(Fixtures.chat(content: Self.json("Wrzuć to do Supabase i daj znać, jak skończysz, bo czekam na to."), finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let job = mode.job(vocabulary: ["Szpak"], learned: learned)
        #expect(job.vocabulary == ["Szpak", "Supabase"])
        let outcome = await enhancer.enhance(raw, job: job)
        #expect(outcome.text?.contains("Supabase") == true, "the learned form is a safe edit: \(outcome)")
    }

    @Test func usageCountsAcceptedCorrectionsModesAndTimeouts() async {
        let usage = UsageEvents()
        let (enhancer, _, baseURL) = makeEnhancer({ _ in
            .json(Fixtures.chat(content: Self.json(Self.raw), finish: "stop"))
        }, usage: usage)
        defer { StubURLProtocol.unregister(baseURL) }
        _ = await enhancer.enhance(Self.raw, mode: BuiltInAIModes.cleanup, vocabulary: [])
        _ = await enhancer.enhance(Self.raw, mode: BuiltInAIModes.english, vocabulary: [])
        let events = usage.all
        #expect(events.contains(.modeUsed(id: "cleanup")))
        #expect(events.contains(.modeUsed(id: "english")))
        #expect(events.contains { if case .correctionAccepted = $0 { true } else { false } })
        // A rewrite is never counted as a correction.
        #expect(events.filter { if case .correctionAccepted = $0 { true } else { false } }.count == 1)

        let slow = UsageEvents()
        let (late, _, url2) = makeEnhancer({ _ in
            .json(Fixtures.chat(content: "\"x\"", finish: "stop"), delay: .seconds(2))
        }, deadline: .milliseconds(300), usage: slow)
        defer { StubURLProtocol.unregister(url2) }
        _ = await late.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        #expect(slow.all.contains(.timeout(.correction)))
    }

    // MARK: Failures

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
        let (truncated, _, url1) = makeEnhancer { _ in .json(Fixtures.chat(content: Self.json(Self.raw), finish: "length")) }
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
        #expect(outcome.note == String(localized: "Nieprawidłowy klucz AI"))
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

    @Test func noRouteAtTheDeadlineIsATimeoutNotAMissingModel() async {
        // A local server still starting answers nil exactly when the deadline runs out.
        let routes = FakeAIRoutes([:], delay: .milliseconds(300))
        let usage = UsageEvents()
        let enhancer = Enhancer(routes: routes, session: StubURLProtocol.makeSession(), deadline: .milliseconds(300), usage: { usage.record($0) })
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        guard case .failed(.deadline, _) = outcome else {
            Issue.record("Expected .failed(.deadline), got \(outcome)")
            return
        }
        #expect(usage.all == [.timeout(.correction)])
    }

    @Test func retriesOnceOnConnectionLost() async {
        let counter = Counter()
        let (enhancer, _, baseURL) = makeEnhancer { _ in
            counter.increment()
            if counter.value == 1 {
                return .failure(.networkConnectionLost)
            }
            return .json(Fixtures.chat(content: Self.json(Self.raw), finish: "stop"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let outcome = await enhancer.enhance(Self.raw, systemPrompt: Self.systemPrompt)
        #expect(outcome.text?.lowercased() == Self.raw)
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

    @Test func cleanupMaxTokensIsWordsTimesThreePlus32() {
        #expect(Enhancer.maxTokens(for: "", kind: .cleanup) == 32)
        #expect(Enhancer.maxTokens(for: "jedno dwa trzy cztery", kind: .cleanup) == 4 * 3 + 32)
        #expect(Enhancer.maxTokens(for: Self.raw, kind: .cleanup) == 14 * 3 + 32)
        let long = String(repeating: "słowo ", count: 1000)
        #expect(Enhancer.maxTokens(for: long, kind: .cleanup) == 2048)
        #expect(Enhancer.maxTokens(for: long, kind: .cleanup, cap: 8192) == 3032)
    }

    @Test func fileLLMSessionOutlastsTheLongestLimit() {
        for configuration in [HTTP.fileLLMSession.configuration, HTTP.llmSession.configuration] {
            #expect(configuration.timeoutIntervalForRequest > LocalAITuning.modeCapSeconds)
            #expect(configuration.timeoutIntervalForResource > LocalAITuning.modeCapSeconds)
        }
    }

    @Test func stripsReasoningBlocks() {
        #expect(Enhancer.stripReasoning("<think>plan\nplan</think>\n\nCzysty tekst.") == "Czysty tekst.")
        #expect(Enhancer.stripReasoning("<THINKING>x</THINKING> Tekst <Reasoning>y\nz</Reasoning>") == "Tekst")
        #expect(Enhancer.stripReasoning("  Bez bloków.  ") == "Bez bloków.")
        // An unclosed block swallows the rest, so a leaked chain of thought never gets pasted.
        #expect(Enhancer.stripReasoning("Wynik. <think>nigdy nie zamknięte") == "Wynik.")
        #expect(Enhancer.stripReasoning("<think>a</think><think>b</think>") == "")
    }

    @Test func sanityCheckRejectsOnlyEmptyOrCutOffAnswers() {
        let long = String(repeating: "słowo ", count: 20)
        #expect(Enhancer.rejectionReason(output: "", finishReason: "stop") == .empty)
        #expect(Enhancer.rejectionReason(output: long, finishReason: "length") == .truncated)
        #expect(Enhancer.rejectionReason(output: long, finishReason: "stop") == nil)
        #expect(Enhancer.rejectionReason(output: "Tak.", finishReason: nil) == nil)
    }

    @Test func guardRejectionsMapToHistoryNotes() {
        #expect(EnhancementRejection(.lowSimilarity(0.2)) == .tooDifferent)
        #expect(EnhancementRejection(.tooShort(ratio: 0.3)) == .tooShort)
        #expect(EnhancementRejection(.tooLong(ratio: 2)) == .tooLong)
        #expect(EnhancementRejection(.empty) == .empty)
        #expect(EnhancementRejection.tooDifferent.note == "Odrzucono: zbyt duża zmiana treści")
    }

    // MARK: Deadline (PRD 5)

    @Test func theAdaptiveDeadlineGrowsWithTheInputUpToTheCap() {
        let cleanup = BuiltInAIModes.cleanup.job(vocabulary: [])
        let words = { (count: Int) in Array(repeating: "słowo", count: count).joined(separator: " ") }
        // Short dictation: the mode's own 3 s is the floor (1 s + 10 x 0.06 s is less).
        #expect(Enhancer.deadline(for: cleanup, input: words(10), fallback: .seconds(3), adaptive: true) == .seconds(3))
        // 200 words: 1 + 200 x 0.04 x 1.5 = 13 s.
        #expect(Enhancer.deadline(for: cleanup, input: words(200), fallback: .seconds(3), adaptive: true) == .seconds(13))
        // Capped at 15 s for cleanup, also over a user limit above it.
        #expect(Enhancer.deadline(for: cleanup, input: words(400), fallback: .seconds(3), adaptive: true) == .seconds(15))
        var slow = cleanup
        slow.deadline = .seconds(20)
        #expect(Enhancer.deadline(for: slow, input: words(10), fallback: .seconds(3), adaptive: true) == .seconds(15))

        let mode = BuiltInAIModes.organize.job(vocabulary: [])
        // A mode: 10 + 20 x 0.23 x 1.5 = 16.9 s over its own 8 s.
        #expect(Enhancer.deadline(for: mode, input: words(20), fallback: .seconds(3), adaptive: true) == .milliseconds(16900))
        #expect(Enhancer.deadline(for: mode, input: words(200), fallback: .seconds(3), adaptive: true) == .seconds(30))
        // A job without its own limit takes the enhancer's (15 s off the dictation path).
        var utility = mode
        utility.deadline = nil
        #expect(Enhancer.deadline(for: utility, input: words(5), fallback: .seconds(15), adaptive: true) == .seconds(15))
        // Not adaptive: the job's limit as it is.
        #expect(Enhancer.deadline(for: mode, input: words(200), fallback: .seconds(3), adaptive: false) == .seconds(8))
    }
}
