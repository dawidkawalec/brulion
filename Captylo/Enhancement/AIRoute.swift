import Foundation

/// Which kind of model a request needs (PRD 5-6): the small "korekta" model or the stronger "funkcje AI" model.
enum AIRole: String, Sendable, Codable, CaseIterable {
    /// Dictation cleanup ("Czyszczenie"), note titles, meeting transcript fixes.
    case correction
    /// Every other AI mode, custom prompts, "Przetwórz przez AI", the style profile, meeting
    /// notes and "Zapytaj".
    case features
}

/// Where one AI request goes: an OpenAI-compatible server, the key it signs with and the model
/// it asks for. `model` is what history keeps as the model name.
struct AIRoute: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        /// The model server on this Mac (127.0.0.1).
        case local
        /// Bielik in CloudFerro Sherlock, on the user's own key.
        case cloud
    }

    var client: ChatCompletionsClient
    var key: String
    var model: String
    var kind: Kind
}

/// nil = no AI right now (no model downloaded, server failed, cloud off): callers paste the raw text.
protocol AIRouteProviding: Sendable {
    /// The route for `role`, answered within `timeout` (callers count it against their own
    /// deadline, so an implementation must not overrun it).
    func route(for role: AIRole, timeout: Duration) async -> AIRoute?
    /// Starts or warms whatever serves `role` without blocking (called on the hotkey press).
    func prewarm(_ role: AIRole) async
}

/// No AI at all: the design preview's default and the state before any provider is wired.
struct UnavailableAIRouteProvider: AIRouteProviding {
    func route(for role: AIRole, timeout: Duration) async -> AIRoute? { nil }
    func prewarm(_ role: AIRole) async {}
}
