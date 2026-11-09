import Foundation

/// "Gdzie działa Bielik" in Modele > Podstawowe: the three plain setups of the two AI roles.
/// The option is not stored on its own: `AIRoleRouting.location(cloudEnabled:)` reads it from the
/// cloud switch and the role picks, and `AppSettings.setAILocation(_:)` writes them. A mix made
/// in Modele > Zaawansowane that is none of the three (the correction in the cloud with the AI
/// features on this Mac) shows no option selected.
enum AILocation: String, CaseIterable, Hashable, Sendable {
    /// Both roles on this Mac: Bielik 1.5B and Minitron 7B (or the user's local picks). Nothing
    /// goes to the cloud.
    case local
    /// The correction on this Mac, the AI features (modes, meeting notes, Zapytaj) on Bielik 11B
    /// in CloudFerro Sherlock.
    case featuresInCloud
    /// Both roles on Bielik 11B in CloudFerro Sherlock: every dictation goes to the cloud too.
    case allInCloud

    /// The roles this option sends to the cloud, in role order.
    var cloudRoles: [AIRole] {
        switch self {
        case .local: []
        case .featuresInCloud: [.features]
        case .allInCloud: [.correction, .features]
        }
    }

    var usesCloud: Bool { !cloudRoles.isEmpty }
}
