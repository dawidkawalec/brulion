import Foundation

/// The Mac's memory and what follows from it: the tier, the default plan, the memory budget of
/// the model servers and the memory warning per model (PRD 6). Pure apart from `current`.
struct HardwareProfile: Equatable, Sendable {
    /// 16 GB: a Mac with exactly this much is on the standard tier.
    static let standardMinimumMemory: UInt64 = 16 * 1024 * 1024 * 1024

    let physicalMemoryBytes: UInt64

    init(physicalMemoryBytes: UInt64) {
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// This Mac.
    static var current: HardwareProfile {
        HardwareProfile(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    var tier: HardwareTier {
        physicalMemoryBytes >= Self.standardMinimumMemory ? .standard : .experimental
    }

    /// The default plan. `cloudFeaturesAvailable` is the app's input: true when the user set
    /// up the cloud Bielik (PRD 7.5). It only changes the experimental tier, where AI features
    /// then go to the cloud instead of the small local model; 16 GB Macs keep everything local.
    func plan(cloudFeaturesAvailable: Bool = false) -> LocalAIPlan {
        let correction = LocalRoleAssignment.local(LocalModelCatalog.defaultModel(for: .correction))
        switch tier {
        case .standard:
            return LocalAIPlan(
                tier: .standard,
                correction: correction,
                features: .local(LocalModelCatalog.defaultModel(for: .features))
            )
        case .experimental:
            return LocalAIPlan(
                tier: .experimental,
                correction: correction,
                features: cloudFeaturesAvailable ? .cloud : .local(LocalModelCatalog.defaultModel(for: .correction))
            )
        }
    }

    /// Whether picking `spec` should show a memory warning: on the experimental tier a model
    /// that takes more than `LocalAITuning.memoryWarningFraction` of the memory (Minitron or
    /// 4.5B on 8 GB) stays allowed, but with the warning.
    func needsMemoryWarning(_ spec: LocalModelSpec) -> Bool {
        guard tier == .experimental else { return false }
        return Double(spec.approximateRAMBytes) > Double(physicalMemoryBytes) * LocalAITuning.memoryWarningFraction
    }

    /// How much memory all model servers may use together (`LocalAIService.Options`). On the
    /// experimental tier it fits one model, so the service runs one server at a time.
    var memoryBudgetBytes: Int64 {
        let fraction = switch tier {
        case .standard: LocalAITuning.standardMemoryBudgetFraction
        case .experimental: LocalAITuning.experimentalMemoryBudgetFraction
        }
        return Int64(Double(physicalMemoryBytes) * fraction)
    }

    /// What the onboarding shows for this Mac.
    func requirements(cloudFeaturesAvailable: Bool = false) -> LocalAIRequirements {
        LocalAIRequirements(plan: plan(cloudFeaturesAvailable: cloudFeaturesAvailable))
    }
}
