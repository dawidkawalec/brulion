import Foundation
import os
@testable import Brulion

/// Fake local engine: fixed text or a fixed error, counts calls.
final class TranscriptionFakeLocalTranscriber: LocalTranscribing, Sendable {
    private struct Counters {
        var transcribe = 0
        var preview = 0
    }

    private let text: String
    private let failure: DictationError?
    /// How long `transcribe` takes, like a model that is still being loaded.
    private let delay: Duration
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    init(text: String, failure: DictationError? = nil, delay: Duration = .zero) {
        self.text = text
        self.failure = failure
        self.delay = delay
    }

    var transcribeCalls: Int { counters.withLock { $0.transcribe } }
    var previewCalls: Int { counters.withLock { $0.preview } }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        counters.withLock { $0.transcribe += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return text
    }

    func preview(_ tail: [Float], language: String?) async throws -> String {
        counters.withLock { $0.preview += 1 }
        if let failure { throw failure }
        return text
    }
}

enum TranscriptionFixtures {
    /// Writes a few bytes as `<id>.wav` in the temporary directory and returns the captured audio.
    static func capturedAudio(samples: [Float], duration: TimeInterval = 1.5) throws -> CapturedAudio {
        let id = UUID()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(id.uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0]).write(to: url)
        return CapturedAudio(id: id, fileURL: url, samples: samples, duration: duration)
    }
}
