import Foundation

/// What `LocalAIRouteProvider` needs from the local AI: `LocalAIService` in the app, a fake in tests.
protocol LocalEndpointProviding: Sendable {
    func endpoint(for role: LocalRole, timeout: Duration) async -> LocalEndpoint?
    func prewarm(_ role: LocalRole) async
    func withEndpoint<T: Sendable>(
        for role: LocalRole,
        timeout: Duration,
        _ body: @Sendable (LocalEndpoint) async throws -> T
    ) async throws -> T?
}

extension LocalAIService: LocalEndpointProviding {}

extension LocalRole {
    /// The app's AI role as the local model's role (docs/local-ai.md, integration point 3):
    /// cleanup, transcript fixes and note titles are `correction`; modes, custom prompts,
    /// "Przetwórz przez AI", meeting notes, "Zapytaj" and the style profile are `features`.
    init(_ role: AIRole) {
        switch role {
        case .correction: self = .correction
        case .features: self = .features
        }
    }
}

/// The model server on this Mac as an AI route (PRD 5): llama-server on 127.0.0.1 with its own
/// token, the role's model by id. nil while the role's model is not installed, the helper is
/// missing, the server failed or did not start within the timeout (the start goes on in the
/// background, so the next request finds it ready).
struct LocalAIRouteProvider: AIRouteProviding {
    /// nil = no local AI at all (the design preview and the test host never start llama-server).
    let endpoints: (any LocalEndpointProviding)?

    static func route(_ endpoint: LocalEndpoint) -> AIRoute {
        AIRoute(client: ChatCompletionsClient(baseURL: endpoint.baseURL), key: endpoint.token, model: endpoint.modelID, kind: .local)
    }

    func route(for role: AIRole, timeout: Duration) async -> AIRoute? {
        guard let endpoints, let endpoint = await endpoints.endpoint(for: LocalRole(role), timeout: timeout) else { return nil }
        return Self.route(endpoint)
    }

    func prewarm(_ role: AIRole) async {
        await endpoints?.prewarm(LocalRole(role))
    }

    func withRoute<T: Sendable>(
        for role: AIRole,
        timeout: Duration,
        _ body: @Sendable (AIRoute) async throws -> T
    ) async throws -> T? {
        guard let endpoints else { return nil }
        return try await endpoints.withEndpoint(for: LocalRole(role), timeout: timeout) { endpoint in
            try await body(Self.route(endpoint))
        }
    }
}
