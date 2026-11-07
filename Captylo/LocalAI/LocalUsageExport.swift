import Foundation

/// What "Eksportuj licznik" writes (PRD 8: counted locally, exported by hand for the contest).
/// Counts and durations only: no text, no mode prompts, nothing about the user.
struct LocalUsageExport: Codable, Equatable, Sendable {
    static let formatID = "captylo.localai.usage.v1"

    var format = LocalUsageExport.formatID
    var exportedAt: Date
    var appVersion: String?
    var physicalMemoryBytes: UInt64?
    var averageCorrectionMilliseconds: Int?
    var p95CorrectionMilliseconds: Int?
    var counters: LocalUsageCounters
}
