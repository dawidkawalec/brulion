import Foundation
import os
import Testing
@testable import Captylo

/// `MeetingSummarizer` and `MeetingChat` over the stubbed network, and `MeetingNotesProcessor`
/// storing the result.
struct MeetingSummarizerTests {
    private static let model = "bielik-minitron-test"
    private static let notes = "## Podsumowanie\n- Wdrożenie w piątek [0:01]"

    private static func segments(_ id: UUID) -> [MeetingSegmentRecord] {
        [MeetingSegmentRecord(meetingID: id, track: .them, start: 1, end: 3, text: "Wdrożenie przesuwamy na piątek, testy do czwartku.")]
    }

    private static func chat(_ content: String, finish: String = "stop") -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"choices":[{"message":{"content":"\#(escaped)"},"finish_reason":"\#(finish)"}]}"#
    }

    /// A summarizer on a stub server; `hasRoute: false` = no AI route at all.
    private static func summarizer(
        _ handler: @escaping StubURLProtocol.Handler,
        hasRoute: Bool = true
    ) -> (MeetingSummarizer, URL) {
        let (route, baseURL) = AIRouteFixtures.stubRoute(model: model, handler)
        let summarizer = MeetingSummarizer(
            session: StubURLProtocol.makeSession(),
            routes: FakeAIRoutes(hasRoute ? route : nil)
        )
        return (summarizer, baseURL)
    }

    // MARK: MeetingChat

    @Test func messagesPutTheInstructionsFirstOnlyWhenThereAreAny() {
        #expect(MeetingChat.messages(system: nil, user: "dane") == [.user("dane")])
        #expect(MeetingChat.messages(system: "", user: "dane") == [.user("dane")])
        #expect(MeetingChat.messages(system: "Instrukcje.", user: "dane") == [.system("Instrukcje."), .user("dane")])
    }

    @Test func eachTaskAsksForItsRoleAndItsOpenInstructions() {
        #expect(MeetingAITask.transcriptCorrection.role == .correction)
        #expect(MeetingAITask.notes(templateID: "general").role == .features)
        #expect(MeetingAITask.ask.role == .features)
        #expect(MeetingAITask.libraryAsk.role == .features)
        // The open Polish prompts written for Bielik (`MeetingPrompts`).
        #expect(MeetingAIInstructions.system(for: .ask) == MeetingPrompts.askSystem())
        #expect(MeetingAIInstructions.system(for: .libraryAsk) == MeetingPrompts.libraryAskSystem())
        #expect(MeetingAIInstructions.system(for: .transcriptCorrection) == MeetingPrompts.correctionSystem())
        #expect(MeetingAIInstructions.system(for: .notes(templateID: "client")) == MeetingPrompts.notesSystem(templateID: "client", customInstructions: nil))
    }

    @Test func chatSendsTheSystemInstructionAndTheDataWithTheRoutesModel() async throws {
        let seen = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let (route, baseURL) = AIRouteFixtures.stubRoute(model: Self.model) { request in
            seen.withLock { $0 = request }
            return .json(Self.chat("Odpowiedź [0:01]"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let routes = FakeAIRoutes(route)
        let chat = MeetingChat(session: StubURLProtocol.makeSession(), routes: routes)

        let reply = try await chat.complete(task: .ask, system: "Odpowiadaj tylko na podstawie spotkania.", user: "dane spotkania", maxTokens: 100)
        #expect(reply.text == "Odpowiedź [0:01]")
        #expect(reply.model == Self.model)
        #expect(routes.asked == [.features])

        let request = try #require(seen.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
        let messages = StubURLProtocol.messages(of: request)
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.map(\.content) == ["Odpowiadaj tylko na podstawie spotkania.", "dane spotkania"])
        let body = StubURLProtocol.body(of: request)
        #expect(body["model"] as? String == Self.model)
        #expect(body["max_tokens"] as? Int == 100)
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["captylo_task"] == nil)
    }

    @Test func chatWithoutARouteFailsWithNoKey() async throws {
        let chat = MeetingChat(session: StubURLProtocol.makeSession(), routes: FakeAIRoutes(nil))
        await #expect(throws: MeetingSummaryError.noKey) {
            try await chat.complete(task: .transcriptCorrection, system: nil, user: "1|tekst", maxTokens: 10)
        }
    }

    @Test func chatOnAHeldRouteSendsOnlyTheDataWithoutInstructions() async throws {
        let seen = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let (route, baseURL) = AIRouteFixtures.stubRoute { request in
            seen.withLock { $0 = request }
            return .json(Self.chat("ok"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let routes = FakeAIRoutes(route)
        let chat = MeetingChat(session: StubURLProtocol.makeSession(), routes: routes)
        _ = try await chat.complete(route: try await chat.route(for: .transcriptCorrection), system: nil, user: "1|tekst", maxTokens: 10)
        #expect(routes.asked == [.correction])
        let messages = StubURLProtocol.messages(of: try #require(seen.withLock { $0 }))
        #expect(messages.map(\.role) == ["user"])
        #expect(messages.first?.content == "1|tekst")
    }

    // MARK: Summarizer

    @Test func returnsTheMarkdownAndModel() async throws {
        let seen = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let (summarizer, baseURL) = Self.summarizer { request in
            seen.withLock { $0 = request }
            return .json(Self.chat(Self.notes))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let meeting = MeetingRecord(title: "Standup")
        let out = try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.standup)
        #expect(out.markdown == Self.notes)
        #expect(out.model == Self.model)

        let request = try #require(seen.withLock { $0 })
        let body = StubURLProtocol.body(of: request)
        #expect(body["model"] as? String == Self.model)
        #expect(body["max_tokens"] as? Int == MeetingSummarizer.maxTokens)
        let messages = StubURLProtocol.messages(of: request)
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.last?.content.contains("[0:01] Rozmówcy: Wdrożenie przesuwamy na piątek") == true)
        // The template's reminder closes the data (`MeetingPrompts.notesReminder`).
        #expect(messages.last?.content.hasSuffix(MeetingPrompts.notesReminder(templateID: "standup")) == true)
    }

    @Test func theTemplatePicksTheInstructions() async throws {
        let systems = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (summarizer, baseURL) = Self.summarizer { request in
            let system = StubURLProtocol.messages(of: request).first { $0.role == "system" }?.content ?? ""
            systems.withLock { $0.append(system) }
            return .json(Self.chat(Self.notes))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let meeting = MeetingRecord(title: "x")
        _ = try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.standup)
        #expect(systems.withLock { $0 } == [MeetingPrompts.notesSystem(templateID: "standup", customInstructions: nil)])
    }

    @Test func progressIsReportedForTheCalls() async throws {
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat(Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        let steps = OSAllocatedUnfairLock<[[Int]]>(initialState: [])
        let meeting = MeetingRecord(title: "x")
        _ = try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general) { done, total in
            steps.withLock { $0.append([done, total]) }
        }
        #expect(steps.withLock { $0 } == [[0, 1], [1, 1]])
    }

    @Test func noRouteAndEmptyTranscriptFailClearly() async throws {
        let meeting = MeetingRecord(title: "x")
        let (noRoute, url1) = Self.summarizer({ _ in .json(Self.chat(Self.notes)) }, hasRoute: false)
        defer { StubURLProtocol.unregister(url1) }
        await #expect(throws: MeetingSummaryError.noKey) {
            try await noRoute.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
        }
        let (withRoute, url2) = Self.summarizer { _ in .json(Self.chat(Self.notes)) }
        defer { StubURLProtocol.unregister(url2) }
        await #expect(throws: MeetingSummaryError.noTranscript) {
            try await withRoute.summarize(meeting: meeting, segments: [], template: BuiltInMeetingTemplates.general)
        }
        // Echo is never sent, so a transcript of echo alone is as good as none.
        var echo = Self.segments(meeting.id)[0]
        echo.isEcho = true
        await #expect(throws: MeetingSummaryError.noTranscript) {
            try await withRoute.summarize(meeting: meeting, segments: [echo], template: BuiltInMeetingTemplates.general)
        }
    }

    @Test func serverErrorsTimeoutsAndEmptyAnswersAreTyped() async throws {
        let meeting = MeetingRecord(title: "x")
        let replies: [(StubURLProtocol.Reply, MeetingSummaryError)] = [
            (.json(#"{"error":{"message":"boom","code":502}}"#, status: 502), .server(502)),
            (.json("{}", status: 401), .server(401)),
            (.json("{}", status: 429), .server(429)),
            (.failure(.timedOut), .timedOut),
            (.json(Self.chat("   ")), .empty),
            (.json(Self.chat("<think>plan</think>")), .empty),
        ]
        for (reply, expected) in replies {
            let (summarizer, baseURL) = Self.summarizer { _ in reply }
            defer { StubURLProtocol.unregister(baseURL) }
            await #expect(throws: expected) {
                try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
            }
        }
    }

    @Test func errorMessagesReuseTheAppsTexts() {
        #expect(MeetingSummaryError.noKey.errorDescription == ChatCompletionsError.missingKeyMessage)
        #expect(MeetingSummaryError.server(401).errorDescription == ChatCompletionsError.unauthorized.errorDescription)
        #expect(MeetingSummaryError.server(429).errorDescription == ChatCompletionsError.rateLimited.errorDescription)
        #expect(MeetingSummaryError.server(500).errorDescription?.contains("500") == true)
    }

    @Test func stripsReasoningFromTheAnswer() async throws {
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat("<think>plan</think>\n" + Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        let meeting = MeetingRecord(title: "x")
        let out = try await summarizer.summarize(meeting: meeting, segments: Self.segments(meeting.id), template: BuiltInMeetingTemplates.general)
        #expect(out.markdown == Self.notes)
    }

    /// A local model writes the notes of a long meeting in minutes: the session waits that long.
    @Test func meetingSessionOutlastsALocalModel() {
        let configuration = HTTP.meetingLLMSession.configuration
        #expect(configuration.timeoutIntervalForRequest >= 600)
        #expect(configuration.timeoutIntervalForResource >= 1800)
        #expect(MeetingChat.routeTimeout >= .seconds(60))
    }

    // MARK: Processor

    private struct Fixture {
        let database: Database
        let meetingID: UUID
    }

    private static func fixture(title: String = "Daily standup") async throws -> Fixture {
        let database = Database(modelContainer: try Store.makeInMemoryContainer())
        var meeting = MeetingRecord(title: title)
        meeting.status = .processing
        meeting.summaryError = "stary błąd"
        try await database.createMeeting(meeting)
        for segment in Self.segments(meeting.id) {
            try await database.appendSegment(segment)
        }
        return Fixture(database: database, meetingID: meeting.id)
    }

    private static func processor(_ fixture: Fixture, summarizer: MeetingSummarizer, allowed: Bool = true) -> MeetingNotesProcessor {
        MeetingNotesProcessor(database: fixture.database, summarizer: summarizer, isAllowed: { allowed })
    }

    @Test func storesTheNotesTemplateAndModel() async throws {
        let fixture = try await Self.fixture()
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat(Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).process(meetingID: fixture.meetingID)
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == Self.notes)
        #expect(meeting.summaryTemplateID == "standup")
        #expect(meeting.summaryModel == Self.model)
        #expect(meeting.summaryError == nil)
        #expect(meeting.status == .processing)
    }

    @Test func storesThePolishErrorAndKeepsEarlierNotes() async throws {
        let fixture = try await Self.fixture()
        var meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        meeting.summary = "## Podsumowanie\n- wcześniejsze"
        try await fixture.database.updateMeeting(meeting)
        let (summarizer, baseURL) = Self.summarizer({ _ in .json(Self.chat(Self.notes)) }, hasRoute: false)
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).process(meetingID: fixture.meetingID)
        meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summaryError == MeetingSummaryError.noKey.errorDescription)
        #expect(meeting.summary == "## Podsumowanie\n- wcześniejsze")
    }

    @Test func aProcessorThatIsNotAllowedMakesNoCall() async throws {
        let fixture = try await Self.fixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (summarizer, baseURL) = Self.summarizer { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat(Self.notes))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer, allowed: false).process(meetingID: fixture.meetingID)
        #expect(calls.withLock { $0 } == 0)
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == nil)
        #expect(meeting.summaryError == "stary błąd")
    }

    @Test func regenerateUsesThePickedTemplate() async throws {
        let fixture = try await Self.fixture()
        let systems = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (summarizer, baseURL) = Self.summarizer { request in
            let system = StubURLProtocol.messages(of: request).first { $0.role == "system" }?.content ?? ""
            systems.withLock { $0.append(system) }
            return .json(Self.chat(Self.notes))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).regenerate(meetingID: fixture.meetingID, templateID: "client")
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summaryTemplateID == "client")
        #expect(systems.withLock { $0 } == [MeetingPrompts.notesSystem(templateID: "client", customInstructions: nil)])
    }

    @Test func aFinishedMeetingWithNotesIsCounted() async throws {
        let fixture = try await Self.fixture()
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat(Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        let counted = OSAllocatedUnfairLock(initialState: 0)
        var processor = Self.processor(fixture, summarizer: summarizer)
        processor.onProcessed = { counted.withLock { $0 += 1 } }
        await processor.process(meetingID: fixture.meetingID)
        // "Wygeneruj ponownie" is not a newly processed meeting.
        await processor.regenerate(meetingID: fixture.meetingID, templateID: "client")
        #expect(counted.withLock { $0 } == 1)
    }

    /// The call can take minutes: notes and a title typed meanwhile must survive the save.
    @Test func keepsEditsMadeWhileTheNotesWereWritten() async throws {
        let fixture = try await Self.fixture()
        let requested = OSAllocatedUnfairLock(initialState: false)
        let (summarizer, baseURL) = Self.summarizer { _ in
            requested.withLock { $0 = true }
            return .json(Self.chat(Self.notes), delay: .milliseconds(800))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let processor = Self.processor(fixture, summarizer: summarizer)
        let run = Task { await processor.process(meetingID: fixture.meetingID) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !requested.withLock({ $0 }), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        var edited = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        edited.title = "Standup po zmianie"
        edited.notes = "dopisane w trakcie"
        try await fixture.database.updateMeeting(edited)
        await run.value

        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == Self.notes)
        #expect(meeting.title == "Standup po zmianie")
        #expect(meeting.notes == "dopisane w trakcie")
    }

    @Test func aDeletedMeetingIsLeftAlone() async throws {
        let fixture = try await Self.fixture()
        let (summarizer, baseURL) = Self.summarizer { _ in .json(Self.chat(Self.notes)) }
        defer { StubURLProtocol.unregister(baseURL) }
        await Self.processor(fixture, summarizer: summarizer).process(meetingID: UUID())
        let meeting = try #require(try await fixture.database.meeting(id: fixture.meetingID))
        #expect(meeting.summary == nil)
    }
}
