import Foundation
import Testing
@testable import Captylo

/// The router runs every take through the local engine: there is no cloud transcription.
struct TranscriptionRouterTests {
    private static let loud: [Float] = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    private static let silent: [Float] = [Float](repeating: 0.0005, count: 16_000)

    @Test func localPathUsesTheLocalEngine() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "  lokalnie  ")
        let router = TranscriptionRouter(local: local, localInstalled: { true })
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        let result = try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: ["Kawalec"])

        #expect(result.text == "lokalnie")
        #expect(result.modelName == "whisper-large-v3-turbo")
        #expect(result.ms >= 0)
        #expect(local.transcribeCalls == 1)
    }

    @Test func localPathRequiresTheModel() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "x")
        let router = TranscriptionRouter(local: local, localInstalled: { false })
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        await #expect(throws: DictationError.modelNotReady) {
            try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])
        }
        #expect(local.transcribeCalls == 0)
    }

    @Test func theLocalEngineIsTheOnlyOne() {
        #expect(STTEngine.allCases == [.local])
    }

    // MARK: The local model is still being prepared (first load, Neural Engine compile)

    @Test func aTakeStopsWaitingForAPreparingModel() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie", delay: .seconds(5))
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            localReady: { false },
            modelWait: .milliseconds(50)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: DictationError.modelPreparing) {
            _ = try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])
        }
        #expect(start.duration(to: clock.now) < .seconds(2), "the take must not hang until the model is ready")
    }

    @Test func aModelThatGetsReadyWithinTheWaitStillTranscribes() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "lokalnie", delay: .milliseconds(20))
        let router = TranscriptionRouter(
            local: local,
            localInstalled: { true },
            localReady: { false },
            modelWait: .seconds(5)
        )
        let audio = try TranscriptionFixtures.capturedAudio(samples: Self.loud)

        let result = try await router.transcribe(audio, engine: .local, language: "pl", vocabulary: [])

        #expect(result.text == "lokalnie")
    }

    @Test func modelPreparingSaysWhatToDo() {
        #expect(DictationError.modelPreparing.errorDescription == "Model lokalny jeszcze się przygotowuje (jednorazowo, do kilku minut). Spróbuj ponownie za chwilę.")
    }

    // MARK: Hallucinations

    @Test func silenceHallucinationIsDropped() async throws {
        let local = TranscriptionFakeLocalTranscriber(text: "Dziękuję za uwagę.")
        let router = TranscriptionRouter(local: local, localInstalled: { true })

        let silent = try await router.transcribe(
            try TranscriptionFixtures.capturedAudio(samples: Self.silent), engine: .local, language: "pl", vocabulary: [])
        #expect(silent.text == "")

        let loud = try await router.transcribe(
            try TranscriptionFixtures.capturedAudio(samples: Self.loud), engine: .local, language: "pl", vocabulary: [])
        #expect(loud.text == "Dziękuję za uwagę.")
    }

    @Test func hallucinationFilterIsCaseInsensitiveAndKeepsRealText() {
        #expect(TranscriptionRouter.filterHallucination("napisy stworzone przez społeczność amara.org", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("Subtitles by the Amara.org community", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("  Idę do sklepu.  ", samples: Self.silent) == "Idę do sklepu.")
        #expect(TranscriptionRouter.filterHallucination("Dziękuję za uwagę", samples: Self.loud) == "Dziękuję za uwagę")
        // Whisper's short silence lines go only when they are the whole text of a silent take.
        #expect(TranscriptionRouter.filterHallucination(" Dziękuję. ", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("Thank you.", samples: Self.silent) == "")
        #expect(TranscriptionRouter.filterHallucination("Dziękuję, wyślę jutro.", samples: Self.silent) == "Dziękuję, wyślę jutro.")
        #expect(TranscriptionRouter.filterHallucination("Dziękuję.", samples: Self.loud) == "Dziękuję.")
        #expect(TranscriptionRouter.filterHallucination("", samples: []) == "")
        #expect(TranscriptionRouter.rms(Self.silent) < TranscriptionRouter.silenceRMS)
        #expect(TranscriptionRouter.rms(Self.loud) > TranscriptionRouter.silenceRMS)
    }
}
