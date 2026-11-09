import Foundation
import os
import Testing
@testable import Brulion

/// A fake local AI: a fixed endpoint per role (nil = none), recording what was asked.
final class FakeLocalEndpoints: LocalEndpointProviding, Sendable {
    private struct State {
        var asked: [LocalRole] = []
        var prewarmed: [LocalRole] = []
        var held: [LocalRole] = []
    }

    private let endpoints: [LocalRole: LocalEndpoint]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ endpoints: [LocalRole: LocalEndpoint]) {
        self.endpoints = endpoints
    }

    var asked: [LocalRole] { state.withLock { $0.asked } }
    var prewarmed: [LocalRole] { state.withLock { $0.prewarmed } }
    var held: [LocalRole] { state.withLock { $0.held } }

    func endpoint(for role: LocalRole, timeout: Duration) async -> LocalEndpoint? {
        state.withLock { $0.asked.append(role) }
        return endpoints[role]
    }

    func prewarm(_ role: LocalRole) async {
        state.withLock { $0.prewarmed.append(role) }
    }

    func withEndpoint<T: Sendable>(
        for role: LocalRole,
        timeout: Duration,
        _ body: @Sendable (LocalEndpoint) async throws -> T
    ) async throws -> T? {
        state.withLock { $0.held.append(role) }
        guard let endpoint = endpoints[role] else { return nil }
        return try await body(endpoint)
    }
}

struct AIRoutingTests {
    private static let gigabyte: UInt64 = 1024 * 1024 * 1024
    private static let mac16 = HardwareProfile(physicalMemoryBytes: 16 * gigabyte)
    private static let mac8 = HardwareProfile(physicalMemoryBytes: 8 * gigabyte)

    private static let correctionEndpoint = LocalEndpoint(
        baseURL: URL(string: "http://127.0.0.1:50001/v1/")!,
        token: "token-a",
        modelID: LocalModelCatalog.bielik15B.id
    )
    private static let featuresEndpoint = LocalEndpoint(
        baseURL: URL(string: "http://127.0.0.1:50002/v1/")!,
        token: "token-b",
        modelID: LocalModelCatalog.bielikMinitron7B.id
    )

    private static func cloudRoute(model: String = "Bielik-11B-v3.0-Instruct") -> AIRoute {
        AIRoute(client: ChatCompletionsClient(baseURL: CloudAIRouteProvider.baseURL), key: "sherlock-key", model: model, kind: .cloud)
    }

    // MARK: LocalAIRouteProvider

    @Test func theLocalRouteMapsTheRoleAndTheEndpoint() async throws {
        let endpoints = FakeLocalEndpoints([.correction: Self.correctionEndpoint, .features: Self.featuresEndpoint])
        let provider = LocalAIRouteProvider(endpoints: endpoints)

        let correction = try #require(await provider.route(for: .correction, timeout: .seconds(1)))
        #expect(correction.kind == .local)
        #expect(correction.key == "token-a")
        #expect(correction.model == LocalModelCatalog.bielik15B.id)
        #expect(correction.client.baseURL == Self.correctionEndpoint.baseURL)
        let request = correction.client.chatRequest(model: correction.model, messages: [.user("x")], maxTokens: 4, key: correction.key)
        #expect(request.url?.absoluteString == "http://127.0.0.1:50001/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-a")

        let features = try #require(await provider.route(for: .features, timeout: .seconds(1)))
        #expect(features.model == LocalModelCatalog.bielikMinitron7B.id)
        #expect(endpoints.asked == [.correction, .features])

        await provider.prewarm(.features)
        #expect(endpoints.prewarmed == [.features])
    }

    @Test func theLocalRouteIsNilWithoutAnEndpointOrWithoutLocalAI() async throws {
        let provider = LocalAIRouteProvider(endpoints: FakeLocalEndpoints([:]))
        #expect(await provider.route(for: .correction, timeout: .seconds(1)) == nil)
        let none = LocalAIRouteProvider(endpoints: nil)
        #expect(await none.route(for: .features, timeout: .seconds(1)) == nil)
        await none.prewarm(.correction)
        let held = try await none.withRoute(for: .correction, timeout: .seconds(1)) { _ in 1 }
        #expect(held == nil)
    }

    @Test func aHeldLocalRouteKeepsTheServerInUse() async throws {
        let endpoints = FakeLocalEndpoints([.features: Self.featuresEndpoint])
        let provider = LocalAIRouteProvider(endpoints: endpoints)
        let model = try await provider.withRoute(for: .features, timeout: .seconds(1)) { route in route.model }
        #expect(model == LocalModelCatalog.bielikMinitron7B.id)
        #expect(endpoints.held == [.features])
        #expect(endpoints.asked.isEmpty)
    }

    @Test func appRolesMapOntoLocalRoles() {
        #expect(LocalRole(.correction) == .correction)
        #expect(LocalRole(.features) == .features)
    }

    // MARK: AIRoleRouting

    @Test func sixteenGigabytesRunsBothRolesLocally() {
        let routing = AIRoleRouting(hardware: Self.mac16)
        #expect(routing.target(for: .correction) == .local)
        #expect(routing.target(for: .features) == .local)
        #expect(routing.roleModels == [.correction: LocalModelCatalog.bielik15B, .features: LocalModelCatalog.bielikMinitron7B])
        #expect(routing.effectiveChoice(for: .features, cloudReady: true) == .local(LocalModelCatalog.bielikMinitron7B.id))
        #expect(routing.modelsInUse(cloudReady: false) == [LocalModelCatalog.bielik15B, LocalModelCatalog.bielikMinitron7B])
    }

    @Test func eightGigabytesSendsFeaturesToTheCloudWhenItIsSetUpElseToTheSmallModel() {
        let routing = AIRoleRouting(hardware: Self.mac8)
        #expect(routing.target(for: .correction) == .local)
        #expect(routing.target(for: .features) == .cloudOrLocal)
        // The service keeps the small model for the features as the fallback.
        #expect(routing.roleModels == [.correction: LocalModelCatalog.bielik15B, .features: LocalModelCatalog.bielik15B])
        #expect(routing.effectiveChoice(for: .features, cloudReady: true) == .cloud)
        #expect(routing.effectiveChoice(for: .features, cloudReady: false) == .local(LocalModelCatalog.bielik15B.id))
        #expect(routing.modelsInUse(cloudReady: true) == [LocalModelCatalog.bielik15B])
    }

    @Test func theUsersPickWinsOverThePlan() {
        let routing = AIRoleRouting(
            hardware: Self.mac8,
            correction: .local(LocalModelCatalog.bielikMinitron7B.id),
            features: .cloud
        )
        #expect(routing.target(for: .correction) == .local)
        #expect(routing.target(for: .features) == .cloud)
        // A cloud-only role has no local model, so no server is started for it.
        #expect(routing.roleModels == [.correction: LocalModelCatalog.bielikMinitron7B])
        #expect(routing.effectiveChoice(for: .features, cloudReady: false) == .cloud)
    }

    // MARK: Where Bielik runs (AILocation)

    @Test func thePlainSetupsReadAsTheirLocation() {
        let local = AIRoleRouting(hardware: Self.mac16)
        #expect(local.location(cloudEnabled: false) == .local)
        // The cloud on but no role on it: nothing leaves the Mac.
        #expect(local.location(cloudEnabled: true) == .local)
        #expect(local.cloudRoles(cloudEnabled: true).isEmpty)

        let features = AIRoleRouting(hardware: Self.mac16, features: .cloud)
        #expect(features.location(cloudEnabled: true) == .featuresInCloud)
        #expect(features.cloudRoles(cloudEnabled: true) == [.features])

        let all = AIRoleRouting(hardware: Self.mac16, correction: .cloud, features: .cloud)
        #expect(all.location(cloudEnabled: true) == .allInCloud)
        #expect(all.cloudRoles(cloudEnabled: true) == [.correction, .features])
    }

    @Test func aLocalPickStaysTheSameLocation() {
        let routing = AIRoleRouting(hardware: Self.mac16, correction: .local(LocalModelCatalog.bielik45B.id), features: .cloud)
        #expect(routing.location(cloudEnabled: true) == .featuresInCloud)
    }

    @Test func eightGigabytesCountTheDefaultFeaturesAsCloudOnlyWhileItIsOn() {
        let routing = AIRoleRouting(hardware: Self.mac8)
        #expect(routing.location(cloudEnabled: true) == .featuresInCloud)
        #expect(routing.location(cloudEnabled: false) == .local)
        #expect(routing.cloudRoles(cloudEnabled: false).isEmpty)
    }

    @Test func mixesWithoutAnOptionReadAsNil() {
        // Correction in the cloud, the AI features on this Mac.
        let correctionOnly = AIRoleRouting(hardware: Self.mac16, correction: .cloud)
        #expect(correctionOnly.location(cloudEnabled: true) == nil)
        #expect(correctionOnly.cloudRoles(cloudEnabled: true) == [.correction])
        // A role picked as the cloud while the cloud is off has no AI: not "Na tym Macu".
        let switchedOff = AIRoleRouting(hardware: Self.mac16, features: .cloud)
        #expect(switchedOff.location(cloudEnabled: false) == nil)
        #expect(switchedOff.cloudRoles(cloudEnabled: false).isEmpty)
    }

    @Test func aLocationListsItsCloudRoles() {
        #expect(AILocation.local.cloudRoles.isEmpty)
        #expect(!AILocation.local.usesCloud)
        #expect(AILocation.featuresInCloud.cloudRoles == [.features])
        #expect(AILocation.allInCloud.cloudRoles == [.correction, .features])
    }

    // MARK: AIRoleRouteProvider

    private static func composite(
        _ routing: AIRoleRouting,
        local: [LocalRole: LocalEndpoint],
        cloud: AIRoute?
    ) -> (AIRoleRouteProvider, FakeLocalEndpoints, FakeAIRoutes) {
        let endpoints = FakeLocalEndpoints(local)
        let cloudRoutes = FakeAIRoutes(cloud)
        let provider = AIRoleRouteProvider(local: LocalAIRouteProvider(endpoints: endpoints), cloud: cloudRoutes, routing: { routing })
        return (provider, endpoints, cloudRoutes)
    }

    @Test func aLocalRoleGoesLocalAndNeverAsksTheCloud() async {
        let (provider, endpoints, cloud) = Self.composite(
            AIRoleRouting(hardware: Self.mac16),
            local: [.correction: Self.correctionEndpoint, .features: Self.featuresEndpoint],
            cloud: Self.cloudRoute()
        )
        #expect(await provider.route(for: .correction, timeout: .seconds(1))?.kind == .local)
        #expect(await provider.route(for: .features, timeout: .seconds(1))?.model == LocalModelCatalog.bielikMinitron7B.id)
        #expect(endpoints.asked == [.correction, .features])
        #expect(cloud.asked.isEmpty)
    }

    @Test func aLocalRoleWithoutItsModelHasNoRoute() async {
        // Minitron is picked but not downloaded: no AI, the raw text is pasted (the cloud is
        // never a silent fallback for a local pick).
        let (provider, _, cloud) = Self.composite(AIRoleRouting(hardware: Self.mac16), local: [:], cloud: Self.cloudRoute())
        #expect(await provider.route(for: .features, timeout: .seconds(1)) == nil)
        #expect(cloud.asked.isEmpty)
    }

    @Test func aCloudRoleGoesToTheCloudOrNowhere() async {
        let routing = AIRoleRouting(hardware: Self.mac16, features: .cloud)
        let (provider, endpoints, cloud) = Self.composite(routing, local: [.features: Self.featuresEndpoint], cloud: Self.cloudRoute())
        #expect(await provider.route(for: .features, timeout: .seconds(1))?.kind == .cloud)
        #expect(cloud.asked == [.features])
        #expect(endpoints.asked.isEmpty)

        // The cloud off or without a key answers nil: no AI, never the local model behind it.
        let (offline, offlineEndpoints, _) = Self.composite(routing, local: [.features: Self.featuresEndpoint], cloud: nil)
        #expect(await offline.route(for: .features, timeout: .seconds(1)) == nil)
        #expect(offlineEndpoints.asked.isEmpty)
    }

    @Test func theEightGigabyteDefaultTriesTheCloudThenTheSmallModel() async {
        let routing = AIRoleRouting(hardware: Self.mac8)
        let (ready, readyEndpoints, _) = Self.composite(routing, local: [.features: Self.correctionEndpoint], cloud: Self.cloudRoute())
        #expect(await ready.route(for: .features, timeout: .seconds(1))?.kind == .cloud)
        #expect(readyEndpoints.asked.isEmpty)

        let (noCloud, endpoints, _) = Self.composite(routing, local: [.features: Self.correctionEndpoint], cloud: nil)
        let route = await noCloud.route(for: .features, timeout: .seconds(1))
        #expect(route?.kind == .local)
        #expect(route?.model == LocalModelCatalog.bielik15B.id)
        #expect(endpoints.asked == [.features])
    }

    @Test func nothingAvailableIsNil() async throws {
        let (provider, _, _) = Self.composite(AIRoleRouting(hardware: Self.mac8), local: [:], cloud: nil)
        #expect(await provider.route(for: .correction, timeout: .seconds(1)) == nil)
        #expect(await provider.route(for: .features, timeout: .seconds(1)) == nil)
        let held = try await provider.withRoute(for: .features, timeout: .seconds(1)) { _ in true }
        #expect(held == nil)
    }

    @Test func prewarmAndHeldRoutesFollowTheTarget() async throws {
        let (provider, endpoints, cloud) = Self.composite(
            AIRoleRouting(hardware: Self.mac16, features: .cloud),
            local: [.correction: Self.correctionEndpoint],
            cloud: Self.cloudRoute()
        )
        await provider.prewarm(.correction)
        await provider.prewarm(.features)
        #expect(endpoints.prewarmed == [.correction])
        #expect(cloud.prewarmed == [.features])

        let local = try await provider.withRoute(for: .correction, timeout: .seconds(1)) { $0.kind }
        #expect(local == .local)
        #expect(endpoints.held == [.correction])
        let remote = try await provider.withRoute(for: .features, timeout: .seconds(1)) { $0.kind }
        #expect(remote == .cloud)
    }

    @Test func theRoutingIsReadOnEveryRequest() async {
        let current = OSAllocatedUnfairLock(initialState: AIRoleRouting(hardware: Self.mac16))
        let endpoints = FakeLocalEndpoints([.features: Self.featuresEndpoint])
        let provider = AIRoleRouteProvider(
            local: LocalAIRouteProvider(endpoints: endpoints),
            cloud: FakeAIRoutes(Self.cloudRoute()),
            routing: { current.withLock { $0 } }
        )
        #expect(await provider.route(for: .features, timeout: .seconds(1))?.kind == .local)
        current.withLock { $0.features = .cloud }
        #expect(await provider.route(for: .features, timeout: .seconds(1))?.kind == .cloud)
    }
}
