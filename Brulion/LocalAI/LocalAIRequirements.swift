import Foundation

/// What a plan needs from the Mac, for the onboarding step "Pobierz Bielika" (PRD 7.1).
struct LocalAIRequirements: Equatable, Sendable {
    let plan: LocalAIPlan

    var tier: HardwareTier { plan.tier }

    /// The models the plan downloads.
    var models: [LocalModelSpec] { plan.localModels }

    /// Bytes to download.
    var downloadBytes: Int64 { models.reduce(0) { $0 + $1.bytes } }

    /// Free disk space the downloads need, with the downloader's margin.
    var diskBytes: Int64 { downloadBytes + LocalModelDownloader.diskMargin }

    /// Memory the tier is meant for (nil on the experimental tier, which takes what there is).
    var minimumMemoryBytes: UInt64? {
        tier == .standard ? HardwareProfile.standardMinimumMemory : nil
    }

    func title() -> String {
        switch tier {
        case .standard: String(localized: "Pełna lokalna AI", table: "LocalAI")
        case .experimental: String(localized: "Tryb eksperymentalny", table: "LocalAI")
        }
    }

    /// One or two sentences: which model does what, and the memory and disk it needs.
    func summary(locale: Locale = AppLocale.current) -> String {
        let disk = LocalAIFormat.gigabytes(diskBytes, locale: locale)
        switch (tier, plan.features) {
        case (.standard, _):
            return String(localized: "Korekta dyktowania na Bieliku 1.5B, funkcje AI na Bieliku Minitron 7B. Potrzeba 16 GB pamięci RAM i ok. \(disk) wolnego miejsca na dysku.", table: "LocalAI")
        case (.experimental, .cloud):
            return String(localized: "Ten Mac ma mniej niż 16 GB pamięci RAM: korekta dyktowania działa na Bieliku 1.5B, a funkcje AI na Bieliku w chmurze. Potrzeba ok. \(disk) wolnego miejsca na dysku.", table: "LocalAI")
        case (.experimental, .local):
            return String(localized: "Ten Mac ma mniej niż 16 GB pamięci RAM: korekta dyktowania i funkcje AI działają na Bieliku 1.5B, więc funkcje AI są słabsze niż na większym modelu. Potrzeba ok. \(disk) wolnego miejsca na dysku.", table: "LocalAI")
        }
    }
}
