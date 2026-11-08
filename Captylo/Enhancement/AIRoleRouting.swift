import Foundation

/// Where each AI role runs: the Mac's default plan (`HardwareProfile.plan(cloudFeaturesAvailable:)`,
/// PRD 6) unless the user picked a model for the role in Modele. Pure; `AppState` keeps a
/// snapshot for the routes (`AIRoleRouteProvider`) and feeds `roleModels` to `LocalAIService`.
///
/// - 16 GB and more: correction on Bielik 1.5B, AI features on Bielik Minitron 7B.
/// - Under 16 GB (experimental): correction on 1.5B; AI features on the cloud while "Bielik w
///   chmurze" is on with a key saved, else on 1.5B (decided per request: `.cloudOrLocal`).
struct AIRoleRouting: Equatable, Sendable {
    /// Which provider serves a role.
    enum Target: Equatable, Sendable {
        /// The model server on this Mac (`LocalAIService` knows the role's model).
        case local
        /// Only "Bielik w chmurze"; nothing while it is off or has no key.
        case cloud
        /// The experimental tier's default for AI features: the cloud when it is on with a key,
        /// otherwise the local model (`localModel(for:)`).
        case cloudOrLocal
    }

    let hardware: HardwareProfile
    /// nil = the plan's default.
    var correction: AIModelChoice?
    var features: AIModelChoice?

    init(hardware: HardwareProfile, correction: AIModelChoice? = nil, features: AIModelChoice? = nil) {
        self.hardware = hardware
        self.correction = correction
        self.features = features
    }

    /// The user's pick for `role`, nil when the plan decides.
    func choice(for role: AIRole) -> AIModelChoice? {
        switch role {
        case .correction: correction
        case .features: features
        }
    }

    func target(for role: AIRole) -> Target {
        switch choice(for: role) {
        case .cloud?:
            return .cloud
        case .local?:
            return .local
        case nil:
            switch hardware.plan(cloudFeaturesAvailable: true).assignment(for: LocalRole(role)) {
            case .cloud: return .cloudOrLocal
            case .local: return .local
            }
        }
    }

    /// The model this Mac runs `role` on when it runs locally; nil when the role is cloud only.
    func localModel(for role: AIRole) -> LocalModelSpec? {
        switch choice(for: role) {
        case .cloud?:
            return nil
        case .local(let id)?:
            return LocalModelCatalog.model(id: id)
        case nil:
            guard case .local(let spec) = hardware.plan(cloudFeaturesAvailable: false).assignment(for: LocalRole(role)) else {
                return nil
            }
            return spec
        }
    }

    /// The role -> model mapping for `LocalAIService.setRoleModels` (cloud-only roles left out).
    var roleModels: [LocalRole: LocalModelSpec] {
        var models: [LocalRole: LocalModelSpec] = [:]
        for role in AIRole.allCases {
            if let spec = localModel(for: role) {
                models[LocalRole(role)] = spec
            }
        }
        return models
    }

    /// What serves `role` right now, for Modele: `cloudReady` = "Bielik w chmurze" on with a key.
    func effectiveChoice(for role: AIRole, cloudReady: Bool) -> AIModelChoice {
        switch target(for: role) {
        case .cloud:
            return .cloud
        case .cloudOrLocal where cloudReady:
            return .cloud
        case .local, .cloudOrLocal:
            return localModel(for: role).map { .local($0.id) } ?? .cloud
        }
    }

    /// The roles whose text goes to the cloud while "Bielik w chmurze" is `cloudEnabled`: a role
    /// picked as the cloud, and on the experimental tier the AI features by default. None while
    /// the cloud is off (such a role has no route at all, `AIRoleRouteProvider`).
    func cloudRoles(cloudEnabled: Bool) -> [AIRole] {
        guard cloudEnabled else { return [] }
        return AIRole.allCases.filter { target(for: $0) != .local }
    }

    /// The "Gdzie działa Bielik" option these picks amount to; nil for a mix it has no option for:
    /// the correction in the cloud with the AI features local, or a role picked as the cloud
    /// while the cloud is off.
    func location(cloudEnabled: Bool) -> AILocation? {
        if !cloudEnabled, AIRole.allCases.contains(where: { target(for: $0) == .cloud }) {
            return nil
        }
        let roles = cloudRoles(cloudEnabled: cloudEnabled)
        return AILocation.allCases.first { $0.cloudRoles == roles }
    }

    /// The local models in use for `cloudReady`, each once, in role order: what the requirements
    /// and the onboarding recommend to download.
    func modelsInUse(cloudReady: Bool) -> [LocalModelSpec] {
        var seen = Set<String>()
        return AIRole.allCases.compactMap { effectiveChoice(for: $0, cloudReady: cloudReady).localModel }
            .filter { seen.insert($0.id).inserted }
    }
}
