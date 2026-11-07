import Foundation
import os
import Testing
@testable import Captylo

/// After a meeting: the AI fixes of the transcript, from the pure pieces to the processor over
/// an in-memory store.
struct MeetingTranscriptImprovementTests {
    // MARK: Helpers

    private static func database() throws -> Database {
        Database(modelContainer: try Store.makeInMemoryContainer())
    }

    private static func body(of request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return data
    }

    /// The user message of a chat request.
    private static func userMessage(of request: URLRequest) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body(of: request))) as? [String: Any] ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.last?["content"] as? String ?? ""
    }

    private static func chat(_ content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"choices":[{"message":{"content":"\#(escaped)"},"finish_reason":"stop"}]}"#
    }

    // MARK: Correction prompt

    @Test func correctionBatchesSkipEchoAndRespectTheLimits() {
        let id = UUID()
        var segments = (0..<170).map { index in
            MeetingSegmentRecord(meetingID: id, track: .me, start: Double(index), end: Double(index) + 0.5, text: "linia \(index)")
        }
        segments.append(MeetingSegmentRecord(meetingID: id, track: .me, start: 500, end: 501, text: "echo", isEcho: true))
        segments.append(MeetingSegmentRecord(meetingID: id, track: .me, start: 502, end: 503, text: "   "))
        let batches = MeetingCorrectionPrompt.batches(segments.shuffled())
        #expect(batches.map(\.count) == [80, 80, 10])
        #expect(batches.flatMap { $0 }.map(\.start) == (0..<170).map(Double.init))

        let long = (0..<5).map { index in
            MeetingSegmentRecord(meetingID: id, track: .them, start: Double(index), end: Double(index) + 1, text: String(repeating: "a", count: 3_000))
        }
        #expect(MeetingCorrectionPrompt.batches(long).map(\.count) == [2, 2, 1])
    }

    @Test func correctionPromptNumbersTheLinesWithTheGlossary() {
        let id = UUID()
        let batch = [
            MeetingSegmentRecord(meetingID: id, track: .me, start: 0, end: 1, text: "dam znaciannie"),
            MeetingSegmentRecord(meetingID: id, track: .them, start: 2, end: 3, text: "dwie\nlinie"),
        ]
        let user = MeetingCorrectionPrompt.user(title: "Oferta", glossary: ["Anna", " ", "Captylo"], batch: batch)
        #expect(user.contains("Tytuł spotkania: Oferta"))
        #expect(user.contains("Słownik (pisownia nazw i terminów): Anna, Captylo"))
        #expect(user.hasSuffix("Transkrypt:\n1|dam znaciannie\n2|dwie linie"))
        #expect(!MeetingCorrectionPrompt.user(title: "X", glossary: [], batch: batch).contains("Słownik"))
    }

    @Test func correctionAnswersAreParsedLineByLine() {
        let reply = "```\n1|Dam znać Annie.\n 2 | Wyślę ofertę jutro. \nkomentarz modelu\n2|druga wersja\n3|\nx|nie liczba\n```"
        #expect(MeetingCorrectionPrompt.parse(reply) == [1: "Dam znać Annie.", 2: "Wyślę ofertę jutro."])
    }

    @Test func aFixThatShortensOrAddsTooMuchIsRefused() {
        #expect(MeetingCorrectionPrompt.accepts("Dam znać Annie.", for: "dam znaciannie"))
        #expect(MeetingCorrectionPrompt.accepts("Wyślę ofertę jutro rano.", for: "wyśle oferte jutro rano"))
        // A summary of a long line.
        let long = "no to słuchajcie ja bym proponował żebyśmy wdrożenie przesunęli na piątek bo testy jeszcze trwają i nie zdążymy"
        #expect(!MeetingCorrectionPrompt.accepts("Wdrożenie w piątek.", for: long))
        // An added sentence.
        #expect(!MeetingCorrectionPrompt.accepts("Tak. Zgadzam się w pełni z tym, co powiedziała Anna, i dodam jeszcze jedno.", for: "tak"))
        #expect(!MeetingCorrectionPrompt.accepts("", for: "tak"))
    }

    @Test func fixedLinesKeepTheirFirstTextAndGetWordTimes() {
        let id = UUID()
        let same = MeetingSegmentRecord(
            meetingID: id, track: .me, start: 1, end: 2, text: "wyśle oferte",
            words: [MeetingWord(text: "wyśle", start: 1, end: 1.4), MeetingWord(text: "oferte", start: 1.5, end: 2)]
        )
        var fixedBefore = MeetingSegmentRecord(meetingID: id, track: .them, start: 3, end: 5, text: "dam znać annie",
                                               words: [MeetingWord(text: "dam", start: 3, end: 3.5), MeetingWord(text: "znaciannie", start: 3.6, end: 5)])
        fixedBefore.originalText = "dam znaciannie"
        let untouched = MeetingSegmentRecord(meetingID: id, track: .me, start: 6, end: 7, text: "Tak.")
        let changes = MeetingCorrectionPrompt.changes(
            in: [same, fixedBefore, untouched],
            reply: "1|Wyślę ofertę\n2|Dam znać Annie.\n3|Tak."
        )
        #expect(changes.map(\.id) == [same.id, fixedBefore.id])
        #expect(changes[0].text == "Wyślę ofertę")
        #expect(changes[0].originalText == "wyśle oferte")
        #expect(changes[0].words == [MeetingWord(text: "Wyślę", start: 1, end: 1.4), MeetingWord(text: "ofertę", start: 1.5, end: 2)])
        // A second fix keeps the text from before the first one.
        #expect(changes[1].originalText == "dam znaciannie")
        #expect(changes[1].words.map(\.text) == ["Dam", "znać", "Annie."])
        #expect(changes[1].words.first?.start == 3)
        #expect(abs((changes[1].words.last?.end ?? 0) - 5) < 0.0001)
    }

    // MARK: Correction processor

    private static func correctionFixture() async throws -> (Database, UUID) {
        let database = try database()
        var meeting = MeetingRecord(title: "Oferta", speakerNames: ["1": "Anna"])
        meeting.participants = ["Piotr Nowak", "Anna"]
        try await database.createMeeting(meeting)
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 0, end: 1.5, text: "dam znaciannie"))
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 2, end: 3.5, text: "wyśle oferte jutro", speaker: "1"))
        try await database.appendSegment(MeetingSegmentRecord(meetingID: meeting.id, track: .me, start: 2.1, end: 3.4, text: "wyśle oferte jutro", isEcho: true))
        return (database, meeting.id)
    }

    private static let model = "bielik-korekta-test"

    /// A corrector on a stub server, on the correction model; `hasRoute: false` = no AI route.
    private static func corrector(_ handler: @escaping StubURLProtocol.Handler, hasRoute: Bool = true, routes: FakeAIRoutes? = nil) -> MeetingTranscriptCorrector {
        let (route, _) = AIRouteFixtures.stubRoute(model: model, handler)
        return MeetingTranscriptCorrector(
            session: StubURLProtocol.makeSession(),
            routes: routes ?? FakeAIRoutes(hasRoute ? route : nil)
        )
    }

    @Test func transcriptFixesAskForTheCorrectionModel() async throws {
        let (database, id) = try await Self.correctionFixture()
        let (route, baseURL) = AIRouteFixtures.stubRoute(model: Self.model) { _ in .json(Self.chat("1|Dam znać Annie.")) }
        defer { StubURLProtocol.unregister(baseURL) }
        let routes = FakeAIRoutes([.correction: route])
        let corrector = MeetingTranscriptCorrector(session: StubURLProtocol.makeSession(), routes: routes)
        let processor = MeetingCorrectionProcessor(database: database, corrector: corrector, isEnabled: { true }, vocabulary: { [] })
        #expect(await processor.run(meetingID: id))
        #expect(Set(routes.asked) == [.correction])
    }

    @Test func theAIFixIsStoredAndCanBeRestored() async throws {
        let (database, id) = try await Self.correctionFixture()
        let seen = OSAllocatedUnfairLock(initialState: "")
        let corrector = Self.corrector { request in
            let user = Self.userMessage(of: request)
            seen.withLock { $0 = user }
            return .json(Self.chat("1|Dam znać Annie.\n2|Wyślę ofertę jutro."))
        }
        let processor = MeetingCorrectionProcessor(database: database, corrector: corrector, isEnabled: { true }, vocabulary: { ["Captylo"] })
        #expect(await processor.run(meetingID: id))

        let prompt = seen.withLock { $0 }
        // Dictionary, then the names typed on the meeting, then the calendar's participants, once each.
        #expect(prompt.contains("Słownik (pisownia nazw i terminów): Captylo, Anna, Piotr Nowak\n"))
        #expect(!prompt.contains("3|"))
        let segments = try await database.segments(meetingID: id)
        // `TranscriptFixGuard` keeps the spelling fix and refuses the one that splits a heard
        // word in two ("znaciannie" -> "znać Annie"): a line is never rebuilt from guesses.
        #expect(segments.filter { !$0.isEcho }.map(\.text) == ["dam znaciannie", "Wyślę ofertę jutro."])
        #expect(segments.filter { !$0.isEcho }.map(\.originalText) == [nil, "wyśle oferte jutro"])
        #expect(segments.first { $0.isEcho }?.text == "wyśle oferte jutro")
        #expect(try await database.meeting(id: id)?.transcriptAIModel == Self.model)
        #expect(try await database.meetings(query: "ofertę", limit: 5).map(\.id) == [id])

        #expect(try await database.restoreOriginalTranscript(meetingID: id) == 1)
        let restored = try await database.segments(meetingID: id)
        #expect(restored.filter { !$0.isEcho }.map(\.text) == ["dam znaciannie", "wyśle oferte jutro"])
        #expect(restored.allSatisfy { $0.originalText == nil })
        #expect(try await database.meeting(id: id)?.transcriptAIModel == nil)
    }

    @Test func aFailedAIFixKeepsTheTextAndSaysWhy() async throws {
        let (database, id) = try await Self.correctionFixture()
        let processor = MeetingCorrectionProcessor(
            database: database,
            corrector: Self.corrector { _ in .json("{}", status: 401) },
            isEnabled: { true },
            vocabulary: { [] }
        )
        #expect(await processor.run(meetingID: id) == false)
        #expect(try await database.segments(meetingID: id).map(\.text).contains("dam znaciannie"))
        let error = try #require(try await database.meeting(id: id)?.transcriptError)
        #expect(error.hasPrefix(MeetingCorrectionProcessor.errorPrefix))

        let noKey = MeetingCorrectionProcessor(
            database: database,
            corrector: Self.corrector({ _ in .json(Self.chat("1|x")) }, hasRoute: false),
            isEnabled: { true },
            vocabulary: { [] }
        )
        #expect(await noKey.run(meetingID: id) == false)
        #expect(try await database.meeting(id: id)?.transcriptError == MeetingCorrectionProcessor.errorPrefix + (MeetingSummaryError.noKey.errorDescription ?? ""))
    }

    @Test func theAIFixAfterAMeetingFollowsItsSwitch() async throws {
        let (database, id) = try await Self.correctionFixture()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let corrector = Self.corrector { _ in
            calls.withLock { $0 += 1 }
            return .json(Self.chat("1|Dam znać Annie."))
        }
        let off = MeetingCorrectionProcessor(database: database, corrector: corrector, isEnabled: { false }, vocabulary: { [] })
        await off.process(meetingID: id)
        #expect(calls.withLock { $0 } == 0)
        let on = MeetingCorrectionProcessor(database: database, corrector: corrector, isEnabled: { true }, vocabulary: { [] })
        await on.process(meetingID: id)
        #expect(calls.withLock { $0 } == 1)
    }

    // MARK: Runs

    @MainActor
    @Test func transcriptRunsAllowOneRunPerMeeting() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let runs = MeetingTranscriptRuns { _, _ in
            for await _ in gate.stream { break }
        }
        let id = UUID()
        let task = try #require(runs.start(.aiFix, meetingID: id))
        #expect(runs.kind(id) == .aiFix)
        #expect(runs.start(.restore, meetingID: id) == nil)
        gate.continuation.yield()
        await task.value
        #expect(runs.kind(id) == nil)
        #expect(runs.finishedCount == 1)
    }
}
