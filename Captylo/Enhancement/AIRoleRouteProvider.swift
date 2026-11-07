import Foundation

/// The app's one AI route (`AppState.aiRoutes`): per request it reads where the role runs
/// (`AIRoleRouting`, a snapshot of the settings) and asks the local model server or "Bielik w
/// chmurze". A role on a local model goes local, a role on "Chmura" goes to the cloud (which
/// answers only while it is on with a key), the experimental default for AI features tries the
/// cloud first. No route = nil: the raw text is pasted, as without AI.
struct AIRoleRouteProvider: AIRouteProviding {
    let local: any AIRouteProviding
    let cloud: any AIRouteProviding
    /// The current routing; read off the main actor on every request.
    let routing: @Sendable () -> AIRoleRouting
    /// How long a prewarm may wait to learn whether the cloud is set up (the Keychain).
    static let cloudCheckTimeout: Duration = .seconds(1)

    func route(for role: AIRole, timeout: Duration) async -> AIRoute? {
        switch routing().target(for: role) {
        case .local:
            return await local.route(for: role, timeout: timeout)
        case .cloud:
            return await cloud.route(for: role, timeout: timeout)
        case .cloudOrLocal:
            let clock = ContinuousClock()
            let start = clock.now
            if let route = await cloud.route(for: role, timeout: timeout) {
                return route
            }
            let left = timeout - (clock.now - start)
            guard left > .zero else { return nil }
            return await local.route(for: role, timeout: left)
        }
    }

    func prewarm(_ role: AIRole) async {
        switch routing().target(for: role) {
        case .local:
            await local.prewarm(role)
        case .cloud:
            await cloud.prewarm(role)
        case .cloudOrLocal:
            if await cloud.route(for: role, timeout: Self.cloudCheckTimeout) != nil {
                await cloud.prewarm(role)
            } else {
                await local.prewarm(role)
            }
        }
    }

    func withRoute<T: Sendable>(
        for role: AIRole,
        timeout: Duration,
        _ body: @Sendable (AIRoute) async throws -> T
    ) async throws -> T? {
        switch routing().target(for: role) {
        case .local:
            return try await local.withRoute(for: role, timeout: timeout, body)
        case .cloud:
            return try await cloud.withRoute(for: role, timeout: timeout, body)
        case .cloudOrLocal:
            if let route = await cloud.route(for: role, timeout: timeout) {
                return try await body(route)
            }
            return try await local.withRoute(for: role, timeout: timeout, body)
        }
    }
}
