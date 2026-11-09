import Foundation

/// How long dictation waits for the local model before pasting the raw text (PRD 5): local
/// generation time grows with the text, so the limit does too.
///
///     limit = base + input words x seconds per word x safety factor, capped
///
/// Meetings run in the background without a limit and do not use this.
enum LocalDeadline {
    enum Kind: Sendable {
        /// The cleanup ("Czyszczenie") on the correction model; capped at 15 s.
        case cleanup
        /// An AI mode or custom prompt on the features model; capped at 30 s.
        case mode
    }

    static func limit(
        for kind: Kind,
        inputWords: Int,
        baseSeconds: Double? = nil,
        secondsPerWord: Double? = nil
    ) -> Duration {
        let base = baseSeconds ?? defaultBase(kind)
        let perWord = secondsPerWord ?? defaultSecondsPerWord(kind)
        let raw = base + Double(max(0, inputWords)) * perWord * LocalAITuning.deadlineSafetyFactor
        let seconds = min(cap(kind), max(0, raw))
        return .milliseconds(Int((seconds * 1000).rounded()))
    }

    /// The same for a text: words are whitespace-separated runs.
    static func limit(for kind: Kind, input: String) -> Duration {
        limit(for: kind, inputWords: wordCount(input))
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    static func cap(_ kind: Kind) -> Double {
        switch kind {
        case .cleanup: LocalAITuning.cleanupCapSeconds
        case .mode: LocalAITuning.modeCapSeconds
        }
    }

    private static func defaultBase(_ kind: Kind) -> Double {
        switch kind {
        case .cleanup: LocalAITuning.cleanupBaseSeconds
        case .mode: LocalAITuning.modeBaseSeconds
        }
    }

    private static func defaultSecondsPerWord(_ kind: Kind) -> Double {
        switch kind {
        case .cleanup: LocalAITuning.correctionSecondsPerWord
        case .mode: LocalAITuning.featuresSecondsPerWord
        }
    }
}
