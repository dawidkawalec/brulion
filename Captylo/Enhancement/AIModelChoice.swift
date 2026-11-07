import Foundation

/// What the user picked for one AI role in Modele > Zaawansowane (`AppSettings.aiModelChoice`):
/// a Bielik model on this Mac (a `LocalModelCatalog` id) or "Chmura" (Bielik 11B in CloudFerro
/// Sherlock on the user's key, `CloudAIRouteProvider`). Stored as the model id or `cloud`;
/// nothing stored means the Mac's default plan (`AIRoleRouting`).
enum AIModelChoice: Hashable, Sendable {
    case local(String)
    case cloud

    /// The stored value of `.cloud`.
    static let cloudValue = "cloud"

    /// nil for nothing stored, an empty value or a model id the catalog does not know.
    init?(stored: String?) {
        guard let value = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value == Self.cloudValue {
            self = .cloud
        } else if LocalModelCatalog.model(id: value) != nil {
            self = .local(value)
        } else {
            return nil
        }
    }

    var stored: String {
        switch self {
        case .local(let id): id
        case .cloud: Self.cloudValue
        }
    }

    /// The local model, nil for the cloud (or an unknown id).
    var localModel: LocalModelSpec? {
        guard case .local(let id) = self else { return nil }
        return LocalModelCatalog.model(id: id)
    }

    /// What Modele offers per role, in this order: the recommended model first, then the
    /// alternatives, the cloud last (PRD 6).
    static func options(for role: AIRole) -> [AIModelChoice] {
        switch role {
        case .correction:
            [
                .local(LocalModelCatalog.bielik15B.id),
                .local(LocalModelCatalog.bielikMinitron7B.id),
                .local(LocalModelCatalog.bielik45B.id),
                .cloud,
            ]
        case .features:
            [
                .local(LocalModelCatalog.bielikMinitron7B.id),
                .local(LocalModelCatalog.bielik45B.id),
                .local(LocalModelCatalog.bielik15B.id),
                .cloud,
            ]
        }
    }
}
