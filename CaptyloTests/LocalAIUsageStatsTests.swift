import Foundation
import Testing
@testable import Captylo

struct LocalAIUsageStatsTests {
    private let date = Date(timeIntervalSince1970: 1_794_000_000)

    @Test func countsEveryKindOfEvent() async {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let stats = LocalUsageStats(fileURL: folder.url.appending(path: "usage.json"), now: { [date] in date })

        await stats.record(.dictation)
        await stats.record(.dictation)
        await stats.record(.correctionAccepted(milliseconds: 400))
        await stats.record(.correctionRejected(reason: CorrectionGuard.Rejection.tooLong(ratio: 2).code, milliseconds: 800))
        await stats.record(.timeout(.correction))
        await stats.record(.modeUsed(id: "builtin.email"))
        await stats.record(.modeUsed(id: "builtin.email"))
        await stats.record(.meetingProcessed)
        await stats.record(.serverFailure)

        let counters = await stats.counters
        #expect(counters.dictations == 2)
        #expect(counters.correctionsAccepted == 1)
        #expect(counters.correctionsRejected == 1)
        #expect(counters.rejectionsByReason == ["tooLong": 1])
        #expect(counters.timeouts == 1)
        #expect(counters.timeoutsByRole == ["correction": 1])
        #expect(counters.modeUses == ["builtin.email": 2])
        #expect(counters.meetingsProcessed == 1)
        #expect(counters.serverFailures == 1)
        #expect(counters.averageCorrectionMilliseconds == 600)
        #expect(counters.since == date)
    }

    @Test func p95UsesNearestRank() {
        var counters = LocalUsageCounters()
        for milliseconds in 1...100 {
            counters.apply(.correctionAccepted(milliseconds: milliseconds), at: date)
        }
        #expect(counters.p95CorrectionMilliseconds == 95)
        #expect(counters.averageCorrectionMilliseconds == 51)
        #expect(LocalUsageCounters().p95CorrectionMilliseconds == nil)
    }

    @Test func keepsABoundedSampleButAnExactAverage() {
        var counters = LocalUsageCounters()
        for _ in 0..<(LocalUsageCounters.sampleLimit + 10) {
            counters.apply(.correctionAccepted(milliseconds: 100), at: date)
        }
        #expect(counters.correctionSamples.count == LocalUsageCounters.sampleLimit)
        #expect(counters.correctionCount == LocalUsageCounters.sampleLimit + 10)
        #expect(counters.averageCorrectionMilliseconds == 100)
    }

    @Test func survivesARestart() async {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let url = folder.url.appending(path: "nested/usage.json")
        // Whole seconds: the file stores ISO 8601 dates without fractions.
        let first = LocalUsageStats(fileURL: url, now: { [date] in date })
        await first.record(.dictation)
        await first.record(.correctionAccepted(milliseconds: 250))

        let second = LocalUsageStats(fileURL: url)
        #expect(await second.counters == first.counters)
        await second.reset()
        #expect(await LocalUsageStats(fileURL: url).counters == LocalUsageCounters())
    }

    @Test func unreadableFileStartsFromZero() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let url = folder.url.appending(path: "usage.json")
        try Data("{not json".utf8).write(to: url)
        #expect(await LocalUsageStats(fileURL: url).counters == LocalUsageCounters())
    }

    @Test func exportsAnOpenJSONFormat() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let stats = LocalUsageStats(fileURL: folder.url.appending(path: "usage.json"), now: { [date] in date })
        await stats.record(.correctionAccepted(milliseconds: 300))
        let target = folder.url.appending(path: "export.json")

        try await stats.export(to: target)

        let exported = try LocalUsageStats.decoder().decode(LocalUsageExport.self, from: Data(contentsOf: target))
        #expect(exported.format == "szpak.localai.usage.v1")
        #expect(exported.exportedAt == date)
        #expect(exported.p95CorrectionMilliseconds == 300)
        #expect(exported.counters.correctionsAccepted == 1)
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("\"correctionsAccepted\" : 1"))
    }
}
