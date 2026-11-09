import Foundation

/// The stored counters (`LocalUsageStats`, JSON). Durations keep an exact total plus the last
/// `sampleLimit` samples for the p95.
struct LocalUsageCounters: Codable, Equatable, Sendable {
    static let sampleLimit = 2000

    var since: Date?
    var updatedAt: Date?
    var dictations = 0
    var correctionsAccepted = 0
    var correctionsRejected = 0
    var rejectionsByReason: [String: Int] = [:]
    var timeouts = 0
    var timeoutsByRole: [String: Int] = [:]
    var correctionCount = 0
    var correctionMillisecondsTotal: Int64 = 0
    var correctionSamples: [Int] = []
    var modeUses: [String: Int] = [:]
    var meetingsProcessed = 0
    var serverFailures = 0

    mutating func apply(_ event: LocalUsageEvent, at date: Date) {
        if since == nil { since = date }
        updatedAt = date
        switch event {
        case .dictation:
            dictations += 1
        case .correctionAccepted(let milliseconds):
            correctionsAccepted += 1
            addCorrectionTime(milliseconds)
        case .correctionRejected(let reason, let milliseconds):
            correctionsRejected += 1
            rejectionsByReason[reason, default: 0] += 1
            addCorrectionTime(milliseconds)
        case .timeout(let role):
            timeouts += 1
            timeoutsByRole[role.rawValue, default: 0] += 1
        case .modeUsed(let id):
            modeUses[id, default: 0] += 1
        case .meetingProcessed:
            meetingsProcessed += 1
        case .serverFailure:
            serverFailures += 1
        }
    }

    /// Mean of every finished correction (accepted or rejected), nil before the first.
    var averageCorrectionMilliseconds: Int? {
        guard correctionCount > 0 else { return nil }
        return Int((Double(correctionMillisecondsTotal) / Double(correctionCount)).rounded())
    }

    /// 95th percentile (nearest rank) of the last `sampleLimit` corrections.
    var p95CorrectionMilliseconds: Int? {
        guard !correctionSamples.isEmpty else { return nil }
        let sorted = correctionSamples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    private mutating func addCorrectionTime(_ milliseconds: Int) {
        let milliseconds = max(0, milliseconds)
        correctionCount += 1
        correctionMillisecondsTotal += Int64(milliseconds)
        correctionSamples.append(milliseconds)
        if correctionSamples.count > Self.sampleLimit {
            correctionSamples.removeFirst(correctionSamples.count - Self.sampleLimit)
        }
    }
}
