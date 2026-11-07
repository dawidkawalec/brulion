import Foundation
import os
import Testing
@testable import Captylo

/// The transcript fixes on a local model: one batch at a time, the open Polish instructions, and
/// only the lines `TranscriptFixGuard` finds safe.
struct MeetingCorrectorGuardTests {
    private static func segment(_ text: String, at start: Double) -> MeetingSegmentRecord {
        MeetingSegmentRecord(meetingID: UUID(), track: .them, start: start, end: start + 2, text: text)
    }

    @Test func onlySafeFixesOfABatchAreKept() {
        let batch = [
            Self.segment("wyśle oferte jutro", at: 0),
            Self.segment("musimy wyciąć ten fragment z nagrania", at: 3),
        ]
        // Line 1: diacritics only. Line 2: a different verb, "wyciąć" became "wyciszyć".
        let reply = "1|Wyślę ofertę jutro.\n2|Musimy wyciszyć ten fragment z nagrania."
        let kept = MeetingTranscriptCorrector.safeChanges(in: batch, reply: reply, glossary: [])
        #expect(kept.map(\.text) == ["Wyślę ofertę jutro."])
        #expect(kept.first?.originalText == "wyśle oferte jutro")
        for fixed in kept {
            let original = batch.first { $0.id == fixed.id }?.text ?? ""
            #expect(TranscriptFixGuard.isSafe(original: original, fixed: fixed.text, glossary: []))
        }
    }

    @Test func fixesRunOneBatchAtATimeWithTheCorrectionInstructions() async throws {
        #expect(MeetingTranscriptCorrector.parallelBatches == 1)
        let systems = OSAllocatedUnfairLock<[String]>(initialState: [])
        let (route, baseURL) = AIRouteFixtures.stubRoute { request in
            let system = StubURLProtocol.messages(of: request).first { $0.role == "system" }?.content ?? ""
            systems.withLock { $0.append(system) }
            return .json(#"{"choices":[{"message":{"content":"1|Wyślę ofertę jutro."},"finish_reason":"stop"}]}"#)
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let corrector = MeetingTranscriptCorrector(session: StubURLProtocol.makeSession(), routes: FakeAIRoutes([.correction: route]))
        let meeting = MeetingRecord(title: "Oferta")
        let segments = [MeetingSegmentRecord(meetingID: meeting.id, track: .them, start: 0, end: 2, text: "wyśle oferte jutro")]
        let result = try await corrector.correct(meeting: meeting, segments: segments, glossary: [])
        #expect(result.changes.map(\.text) == ["Wyślę ofertę jutro."])
        #expect(systems.withLock { $0 } == [MeetingPrompts.correctionSystem()])
    }
}
