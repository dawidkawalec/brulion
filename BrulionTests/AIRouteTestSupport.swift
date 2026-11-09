import Foundation
import os
@testable import Brulion

/// A fake `AIRouteProviding`: a fixed route per role (nil = no AI for that role), an optional
/// delay before it answers, and a record of the roles asked for and prewarmed.
final class FakeAIRoutes: AIRouteProviding, Sendable {
    private struct State {
        var asked: [AIRole] = []
        var prewarmed: [AIRole] = []
    }

    private let routes: [AIRole: AIRoute]
    private let delay: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ routes: [AIRole: AIRoute], delay: Duration = .zero) {
        self.routes = routes
        self.delay = delay
    }

    /// The same route for both roles; nil = no AI at all.
    convenience init(_ route: AIRoute?, delay: Duration = .zero) {
        var routes: [AIRole: AIRoute] = [:]
        if let route {
            for role in AIRole.allCases { routes[role] = route }
        }
        self.init(routes, delay: delay)
    }

    var asked: [AIRole] { state.withLock { $0.asked } }
    var prewarmed: [AIRole] { state.withLock { $0.prewarmed } }

    func route(for role: AIRole, timeout: Duration) async -> AIRoute? {
        state.withLock { $0.asked.append(role) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return routes[role]
    }

    func prewarm(_ role: AIRole) async {
        state.withLock { $0.prewarmed.append(role) }
    }
}

enum AIRouteFixtures {
    /// A local-looking route to a stub server answering with `handler`, and its base URL.
    static func stubRoute(
        model: String = "bielik-test",
        key: String = "local-token",
        kind: AIRoute.Kind = .local,
        _ handler: @escaping StubURLProtocol.Handler
    ) -> (AIRoute, URL) {
        let baseURL = StubURLProtocol.register(handler)
        return (AIRoute(client: ChatCompletionsClient(baseURL: baseURL), key: key, model: model, kind: kind), baseURL)
    }
}
