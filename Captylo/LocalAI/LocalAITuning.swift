import Foundation

/// Every number of the local AI that F0 measures or tunes, in one place (docs/local-ai.md,
/// "Pending numbers"). Values marked PLACEHOLDER are educated guesses until the measured
/// ones replace them; nothing else in `Captylo/LocalAI/` hardcodes these.
enum LocalAITuning {
    // MARK: Context windows (llama-server `-c`)

    /// PLACEHOLDER: context for the correction role (a dictation plus the cleanup prompt).
    static let correctionContext = 8192
    /// PLACEHOLDER: context for the features role (a 1 h meeting is about 20-25k tokens; longer
    /// transcripts are split by the meeting code, PRD 7.4).
    static let featuresContext = 16384

    static func contextLength(for role: LocalRole) -> Int {
        switch role {
        case .correction: correctionContext
        case .features: featuresContext
        }
    }

    // MARK: Memory

    /// Measured peak resident memory of llama-server per model id, at its context, in bytes.
    /// PLACEHOLDER: empty until F0 sends the numbers; `peakRAMBytes` falls back to the factor.
    static let measuredPeakRAM: [String: Int64] = [:]
    /// PLACEHOLDER: peak memory as a multiple of the file size when no measurement exists.
    static let ramFactor = 1.3

    static func peakRAMBytes(modelID: String, fileBytes: Int64) -> Int64 {
        measuredPeakRAM[modelID] ?? Int64((Double(fileBytes) * ramFactor).rounded())
    }

    /// PLACEHOLDER: share of the physical memory all llama-server processes may use together,
    /// per tier. 16 GB x 0.6 fits 1.5B + Minitron next to Whisper; 8 GB x 0.45 fits one model.
    static let standardMemoryBudgetFraction = 0.6
    static let experimentalMemoryBudgetFraction = 0.45
    /// On the experimental tier a model whose peak memory exceeds this share of the physical
    /// memory is allowed, but with a memory warning (PRD 6: Minitron on 8 GB).
    static let memoryWarningFraction = 0.35

    /// Prompt cache in RAM per server (llama-server `--cache-ram`, MiB). Its default (8 GiB)
    /// would make memory use unpredictable on small Macs.
    static let promptCacheMiB = 512

    // MARK: Deadlines (PRD 5)

    /// PLACEHOLDER: fixed part of the cleanup deadline, seconds.
    static let cleanupBaseSeconds = 1.5
    /// PLACEHOLDER: fixed part of an AI mode's deadline, seconds.
    static let modeBaseSeconds = 4.0
    /// PLACEHOLDER: generation time per input word, seconds (correction and features models).
    static let correctionSecondsPerWord = 0.02
    static let featuresSecondsPerWord = 0.02
    /// Safety factor on the per-word time (PRD 5).
    static let deadlineSafetyFactor = 1.5
    /// Caps (PRD 5).
    static let cleanupCapSeconds = 15.0
    static let modeCapSeconds = 30.0

    // MARK: Correction guard (PRD 7.2)

    /// PLACEHOLDER: minimum word similarity between the raw text and the correction.
    static let guardMinimumSimilarity = 0.5
    /// Allowed output length as a share of the input length.
    static let guardMinimumLengthRatio = 0.5
    static let guardMaximumLengthRatio = 1.5
    /// The length check applies only to inputs longer than this many characters.
    static let guardLengthCheckMinimumCharacters = 40

    // MARK: Server lifecycle

    /// Default idle time before a server is stopped to free its memory (PRD 5: 10 min).
    static let defaultIdleTimeout: Duration = .seconds(10 * 60)
    /// How long a start may take before it counts as failed (big models load in seconds).
    static let startTimeout: Duration = .seconds(60)
}
