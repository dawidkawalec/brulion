import Foundation
import Testing
@testable import Captylo

struct LocalAIDeadlineTests {
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @Test func followsTheFormula() {
        let perWord = 0.02
        let limit = LocalDeadline.limit(for: .cleanup, inputWords: 60, baseSeconds: 1.5, secondsPerWord: perWord)
        #expect(abs(seconds(limit) - (1.5 + 60 * perWord * LocalAITuning.deadlineSafetyFactor)) < 0.001)
    }

    @Test func defaultsComeFromTheTuningTable() {
        #expect(abs(seconds(LocalDeadline.limit(for: .cleanup, inputWords: 0)) - LocalAITuning.cleanupBaseSeconds) < 0.001)
        #expect(abs(seconds(LocalDeadline.limit(for: .mode, inputWords: 0)) - LocalAITuning.modeBaseSeconds) < 0.001)
    }

    @Test func capsLongInputs() {
        #expect(seconds(LocalDeadline.limit(for: .cleanup, inputWords: 100_000)) == 15)
        #expect(seconds(LocalDeadline.limit(for: .mode, inputWords: 100_000)) == 30)
        #expect(LocalDeadline.cap(.cleanup) == 15)
        #expect(LocalDeadline.cap(.mode) == 30)
    }

    @Test func growsWithTheInput() {
        let short = LocalDeadline.limit(for: .mode, inputWords: 10)
        let long = LocalDeadline.limit(for: .mode, inputWords: 200)
        #expect(long > short)
        #expect(LocalDeadline.limit(for: .cleanup, inputWords: -5) == LocalDeadline.limit(for: .cleanup, inputWords: 0))
    }

    @Test func countsWordsOfAText() {
        #expect(LocalDeadline.wordCount("  ala ma\nkota  i\tpsa ") == 5)
        #expect(LocalDeadline.wordCount("") == 0)
        #expect(LocalDeadline.limit(for: .cleanup, input: "ala ma kota") == LocalDeadline.limit(for: .cleanup, inputWords: 3))
    }
}
