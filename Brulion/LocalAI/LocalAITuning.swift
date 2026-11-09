import Foundation

/// Every number of the local AI that F0 measures or tunes, in one place (docs/local-ai.md,
/// "Measured numbers"). F0 = 2026-11-07 on an M3 Pro 36 GB, llama-server v0.9.0, -c 8192,
/// -ngl 99, temperature 0, 60 real dictations (median 32 words). Values marked ESTIMATE or
/// PLACEHOLDER are not measured yet; nothing else in the module hardcodes these.
enum LocalAITuning {
    // MARK: Context windows (llama-server `-c`)

    /// Context for the correction role (a dictation plus the cleanup prompt). Bielik 1.5B was
    /// trained on 8192 tokens: never more.
    static let correctionContext = 8192
    /// Context for the features role: the meeting code's 20k-token input budget plus a 4k
    /// answer (`TranscriptChunker.defaultInputBudget`; longer transcripts are split, PRD 7.4).
    /// Minitron 7B was trained on 32768 tokens; the 4.5B serving this role gets the same.
    static let featuresContext = 24576

    static func contextLength(for role: LocalRole) -> Int {
        switch role {
        case .correction: correctionContext
        case .features: featuresContext
        }
    }

    // MARK: Memory

    /// Planned memory of llama-server per model id: the mapped model file plus the working
    /// memory. 1.5B measured in F0 at -c 8192 (1.70 GB + 0.45-0.6 GB). Minitron measured in the
    /// app at the features context -c 24576 (F3, 7.11: RSS 8.3-8.45 GB, of which the mapped
    /// 4.50 GB file macOS can drop; the peak is taken as the plan). The 4.5B is an ESTIMATE
    /// (5.06 GB + 2.4 GB at -c 24576), not measured. A model used for correction only runs at
    /// -c 8192 and needs less, so these are the upper bounds.
    static let measuredPeakRAM: [String: Int64] = [
        "bielik-1.5b-v3-q8": 2_300_000_000,
        "bielik-minitron-7b-v3-q4km": 8_450_000_000,
        "bielik-4.5b-v3-q8": 7_500_000_000,
    ]
    /// Peak memory as a multiple of the file size for a model without a measurement (tests,
    /// models added later).
    static let ramFactor = 1.3

    static func peakRAMBytes(modelID: String, fileBytes: Int64) -> Int64 {
        measuredPeakRAM[modelID] ?? Int64((Double(fileBytes) * ramFactor).rounded())
    }

    /// Share of the physical memory all llama-server processes may use together, per tier.
    /// 16 GB x 0.6 = 10.3 GB holds either model, but not 1.5B + Minitron (10.75 GB): on a 16 GB
    /// Mac the service stops the 1.5B while Minitron runs and starts it again for the next
    /// dictation (about 1-2 s). Dawid, 8.11: models one at a time there, rather than a bigger
    /// budget (swap) or a smaller context (more meeting parts). From 24 GB (14.4 GB) both stay
    /// loaded. 8 GB x 0.45 = 3.9 GB fits the 1.5B (2.3 GB) alone.
    static let standardMemoryBudgetFraction = 0.6
    static let experimentalMemoryBudgetFraction = 0.45
    /// On the experimental tier a model whose peak memory exceeds this share of the physical
    /// memory is allowed, but with a memory warning (PRD 6: Minitron on 8 GB).
    static let memoryWarningFraction = 0.35

    /// Prompt cache in RAM per server (llama-server `--cache-ram`, MiB). Its default (8 GiB)
    /// would make memory use unpredictable on small Macs.
    static let promptCacheMiB = 512

    // MARK: Deadlines (PRD 5)

    /// Fixed part of the cleanup deadline, seconds (1.5B: warm first token p50 0.07-0.09 s).
    static let cleanupBaseSeconds = 1.0
    /// Fixed part of an AI mode's deadline, seconds. A mode's answer can be much longer than the
    /// dictation (an e-mail or a list from a few words), and Minitron's time follows the answer
    /// (~2 s + ~0.2 s per answer word, F3 7.11): with 3 s, 9 of 36 short dictations in e-mail, list
    /// and organize hit the limit; 10 s gives 5-10 words about 12-14 s.
    static let modeBaseSeconds = 10.0
    /// Time per input word, seconds: 1.5B p50 0.032, p95 0.039 (rounded up to 0.04);
    /// Minitron p50 0.15, p95 0.23.
    static let correctionSecondsPerWord = 0.04
    static let featuresSecondsPerWord = 0.23
    /// Safety factor on the per-word time (PRD 5).
    static let deadlineSafetyFactor = 1.5
    /// Caps (PRD 5).
    static let cleanupCapSeconds = 15.0
    static let modeCapSeconds = 30.0

    // MARK: Correction guard (PRD 7.2)

    /// Minimum word similarity between the raw text and the merged correction (F0).
    static let guardMinimumSimilarity = 0.5
    /// Allowed output length as a share of the input length.
    static let guardMinimumLengthRatio = 0.5
    static let guardMaximumLengthRatio = 1.5
    /// The length check applies only to inputs longer than this many characters.
    static let guardLengthCheckMinimumCharacters = 40

    // MARK: Server lifecycle

    /// Default idle time before a server is stopped to free its memory (PRD 5: 10 min).
    static let defaultIdleTimeout: Duration = .seconds(10 * 60)
    /// How long a start may take before it counts as failed. F0 cold loads: 1.5B 1.4-1.7 s,
    /// Minitron 3.9-7.7 s (warm 0.3 s and 0.8 s); slower Macs and disks get a wide margin.
    static let startTimeout: Duration = .seconds(60)
}
