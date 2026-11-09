import Foundation
import os

/// Local usage counter of the local AI, no network and no telemetry (PRD 8): dictations,
/// corrections accepted and rejected by the guard, timeouts, correction times, mode uses,
/// meetings. Kept as JSON at an injected URL (written after every event, atomically);
/// the user exports it to a file they pick.
actor LocalUsageStats {
    nonisolated let fileURL: URL
    private let now: @Sendable () -> Date
    private(set) var counters: LocalUsageCounters

    init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        counters = Self.load(fileURL)
    }

    func record(_ event: LocalUsageEvent) {
        counters.apply(event, at: now())
        save()
    }

    /// Starts counting from zero (the file is rewritten).
    func reset() {
        counters = LocalUsageCounters()
        save()
    }

    func export(
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        physicalMemoryBytes: UInt64? = ProcessInfo.processInfo.physicalMemory
    ) -> LocalUsageExport {
        LocalUsageExport(
            exportedAt: now(),
            appVersion: appVersion,
            physicalMemoryBytes: physicalMemoryBytes,
            averageCorrectionMilliseconds: counters.averageCorrectionMilliseconds,
            p95CorrectionMilliseconds: counters.p95CorrectionMilliseconds,
            counters: counters
        )
    }

    /// Writes `export()` as pretty JSON to a file the user picked.
    func export(to url: URL) throws {
        try Self.encoder().encode(export()).write(to: url, options: .atomic)
    }

    // MARK: File

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(counters).write(to: fileURL, options: .atomic)
        } catch {
            LocalAILog.logger.error("Usage stats not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(_ url: URL) -> LocalUsageCounters {
        guard let data = try? Data(contentsOf: url) else { return LocalUsageCounters() }
        do {
            return try decoder().decode(LocalUsageCounters.self, from: data)
        } catch {
            LocalAILog.logger.error("Usage stats unreadable, starting from zero")
            return LocalUsageCounters()
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
