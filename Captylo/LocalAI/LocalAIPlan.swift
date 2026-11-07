import Foundation

/// Where one role runs.
enum LocalRoleAssignment: Equatable, Sendable {
    case local(LocalModelSpec)
    /// The optional cloud Bielik with the user's own key (PRD 7.5), handled outside this module.
    case cloud
}

/// The default setup for a Mac: which model each role uses (`HardwareProfile.plan`).
struct LocalAIPlan: Equatable, Sendable {
    let tier: HardwareTier
    let correction: LocalRoleAssignment
    let features: LocalRoleAssignment

    func assignment(for role: LocalRole) -> LocalRoleAssignment {
        switch role {
        case .correction: correction
        case .features: features
        }
    }

    /// The role -> model mapping for `LocalAIService` (cloud roles left out).
    var roleModels: [LocalRole: LocalModelSpec] {
        var models: [LocalRole: LocalModelSpec] = [:]
        for role in LocalRole.allCases {
            if case .local(let spec) = assignment(for: role) {
                models[role] = spec
            }
        }
        return models
    }

    /// Models to download for this plan, each once, in role order.
    var localModels: [LocalModelSpec] {
        var seen = Set<String>()
        return LocalRole.allCases.compactMap { roleModels[$0] }.filter { seen.insert($0.id).inserted }
    }
}
