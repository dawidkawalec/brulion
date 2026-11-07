import Foundation

/// The recommended Bielik models of this Mac against what is on disk, for the onboarding step
/// "Pobierz Bielika" and the requirements box in Modele: what is left to download, how many
/// bytes, whether the disk has room, and what the "Pobierz" button does. Pure.
struct BielikDownloadPlan: Equatable, Sendable {
    /// The models the Mac's plan recommends (`LocalAIRequirements.models`), in role order.
    let models: [LocalModelSpec]
    let states: [String: LocalAIModelStore.State]
    /// Bytes of unfinished downloads on disk, per model id.
    let partialBytes: [String: Int64]
    /// Free space on the data volume, nil when macOS does not say.
    let freeBytes: Int64?

    init(models: [LocalModelSpec], states: [String: LocalAIModelStore.State], partialBytes: [String: Int64] = [:], freeBytes: Int64?) {
        self.models = models
        self.states = states
        self.partialBytes = partialBytes
        self.freeBytes = freeBytes
    }

    func state(of spec: LocalModelSpec) -> LocalAIModelStore.State {
        states[spec.id] ?? .notInstalled
    }

    /// Models not installed and not on their way (a failed download counts: it can start again).
    var pending: [LocalModelSpec] {
        models.filter { spec in
            switch state(of: spec) {
            case .notInstalled, .failed: true
            case .downloading, .verifying, .installed: false
            }
        }
    }

    var isDownloading: Bool {
        models.contains { spec in
            switch state(of: spec) {
            case .downloading, .verifying: true
            default: false
            }
        }
    }

    var allInstalled: Bool {
        !models.isEmpty && models.allSatisfy { state(of: $0) == .installed }
    }

    /// Bytes still to download: the pending models (less what they already have on disk) plus
    /// the rest of the running downloads.
    var remainingBytes: Int64 {
        models.reduce(0) { total, spec in
            switch state(of: spec) {
            case .installed, .verifying:
                return total
            case .downloading(let progress):
                return total + max(0, progress.totalBytes - progress.receivedBytes)
            case .notInstalled, .failed:
                return total + max(0, spec.bytes - (partialBytes[spec.id] ?? 0))
            }
        }
    }

    /// Room for the pending downloads with the downloader's margin (unknown free space: yes,
    /// the downloader checks again before it starts).
    var hasEnoughSpace: Bool {
        guard let freeBytes else { return true }
        let pendingBytes = pending.reduce(Int64(0)) { $0 + max(0, $1.bytes - (partialBytes[$1.id] ?? 0)) }
        guard pendingBytes > 0 else { return true }
        return freeBytes >= pendingBytes + LocalModelDownloader.diskMargin
    }

    /// "Pobierz" starts something.
    var canStart: Bool {
        !pending.isEmpty && hasEnoughSpace
    }
}
