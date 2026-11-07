import Foundation
import Testing
@testable import Captylo

struct LocalAIServiceTests {
    private let small = LocalAIFixtures.spec(id: "small", bytes: 1000, role: .correction)
    private let large = LocalAIFixtures.spec(id: "large", bytes: 2000, role: .features)

    private func makeService(
        _ folder: LocalAITempDirectory,
        roles: [LocalRole: LocalModelSpec],
        launcher: FakeLlamaLauncher,
        health: FakeLlamaHealth? = nil,
        budget: Int64? = nil,
        executable: URL? = localAIFakeExecutable,
        install: Bool = true
    ) -> LocalAIService {
        if install {
            for spec in Set(roles.values) { LocalAIFixtures.install(spec, in: folder.url) }
        }
        return LocalAIService(
            roleModels: roles,
            modelsDirectory: folder.url,
            runDirectory: folder.url.appending(path: "run"),
            executable: executable,
            options: LocalAIService.Options(idleTimeout: nil, startTimeout: .seconds(5), memoryBudgetBytes: budget),
            dependencies: .fake(launcher, health: health)
        )
    }

    @Test func twoRolesOnOneModelShareOneProcess() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let service = makeService(folder, roles: [.correction: small, .features: small], launcher: launcher)

        let correction = try #require(await service.endpoint(for: .correction, timeout: .seconds(5)))
        let features = try #require(await service.endpoint(for: .features, timeout: .seconds(5)))

        #expect(correction == features)
        #expect(launcher.launchCount == 1)
        #expect(launcher.processes[0].value(after: "--ctx-size") == String(LocalAITuning.featuresContext), "the larger context of both roles")
        await service.shutdown()
    }

    @Test func twoModelsRunSideBySideWithoutABudget() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let service = makeService(folder, roles: [.correction: small, .features: large], launcher: launcher)

        let correction = try #require(await service.endpoint(for: .correction, timeout: .seconds(5)))
        let features = try #require(await service.endpoint(for: .features, timeout: .seconds(5)))

        #expect(correction.baseURL != features.baseURL)
        #expect(correction.modelID == "small")
        #expect(features.modelID == "large")
        #expect(launcher.processes.map { $0.value(after: "--ctx-size") } == [String(LocalAITuning.correctionContext), String(LocalAITuning.featuresContext)])
        #expect(await service.activeModelIDs() == ["small", "large"])
        await service.shutdown()
        #expect(launcher.running.isEmpty)
        #expect(service.registry.count == 0)
    }

    @Test func memoryBudgetStopsTheLeastRecentlyUsedServer() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let budget = max(small.approximateRAMBytes, large.approximateRAMBytes) + 1
        let service = makeService(folder, roles: [.correction: small, .features: large], launcher: launcher, budget: budget)

        _ = try #require(await service.endpoint(for: .correction, timeout: .seconds(5)))
        _ = try #require(await service.endpoint(for: .features, timeout: .seconds(5)))
        #expect(await service.activeModelIDs() == ["large"])
        #expect(!launcher.processes[0].isRunning, "the small model made room")

        _ = try #require(await service.endpoint(for: .correction, timeout: .seconds(5)))
        #expect(await service.activeModelIDs() == ["small"])
        #expect(launcher.launchCount == 3)
        #expect(launcher.running.count == 1)
        await service.shutdown()
    }

    @Test func runningModelIsNotStoppedForItself() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let service = makeService(folder, roles: [.correction: small, .features: small], launcher: launcher, budget: 1)

        _ = try #require(await service.endpoint(for: .correction, timeout: .seconds(5)))
        _ = try #require(await service.endpoint(for: .features, timeout: .seconds(5)))
        #expect(launcher.launchCount == 1, "a model over the budget still runs, alone")
        await service.shutdown()
    }

    @Test func noEndpointWithoutModelOrHelper() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let notInstalled = makeService(folder, roles: [.correction: small], launcher: launcher, install: false)
        #expect(await notInstalled.endpoint(for: .correction, timeout: .seconds(1)) == nil)
        #expect(await notInstalled.status(for: .correction) == .notInstalled)
        #expect(await notInstalled.endpoint(for: .features, timeout: .seconds(1)) == nil)
        #expect(await notInstalled.status(for: .features) == .unassigned)

        let noHelper = makeService(folder, roles: [.correction: small], launcher: launcher, executable: nil)
        #expect(await noHelper.endpoint(for: .correction, timeout: .seconds(1)) == nil)
        #expect(await noHelper.status(for: .correction) == .helperMissing)
        #expect(launcher.launchCount == 0)
    }

    @Test func timeoutGivesUpButTheStartGoesOn() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let service = makeService(folder, roles: [.correction: small], launcher: launcher, health: FakeLlamaHealth(launcher: launcher, delay: .milliseconds(400)))

        #expect(await service.endpoint(for: .correction, timeout: .milliseconds(50)) == nil)
        #expect(await service.status(for: .correction) == .starting)
        #expect(await service.endpoint(for: .correction, timeout: .seconds(5)) != nil)
        #expect(launcher.launchCount == 1)
        #expect(await service.status(for: .correction) == .running)
        await service.shutdown()
    }

    @Test func withEndpointRunsTheRequest() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let service = makeService(folder, roles: [.features: large], launcher: launcher)

        let model = try await service.withEndpoint(for: .features, timeout: .seconds(5)) { $0.modelID }
        #expect(model == "large")
        let unassigned = try await service.withEndpoint(for: .correction, timeout: .seconds(1)) { $0.modelID }
        #expect(unassigned == nil)
        await service.shutdown()
    }

    @Test func changingTheMappingStopsUnusedServers() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        LocalAIFixtures.install(large, in: folder.url)
        let service = makeService(folder, roles: [.correction: small, .features: small], launcher: launcher)

        _ = try #require(await service.endpoint(for: .correction, timeout: .seconds(5)))
        await service.setRoleModels([.correction: large])
        #expect(launcher.running.isEmpty, "small is no longer used")

        let endpoint = try #require(await service.endpoint(for: .correction, timeout: .seconds(5)))
        #expect(endpoint.modelID == "large")
        #expect(launcher.processes.last?.value(after: "--ctx-size") == String(LocalAITuning.correctionContext))
        await service.shutdown()
    }

    @Test func prewarmStartsWithoutWaiting() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let service = makeService(folder, roles: [.correction: small], launcher: launcher, health: FakeLlamaHealth(launcher: launcher, delay: .milliseconds(200)))

        await service.prewarm(.correction)
        #expect(await service.status(for: .correction) == .starting, "prewarm returns before the model is ready")
        #expect(await localAIWaitUntil { await service.status(for: .correction) == .running })
        #expect(launcher.launchCount == 1)
        await service.shutdown()
    }

    @Test func terminateAllNowSignalsEveryProcess() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let service = makeService(folder, roles: [.correction: small, .features: large], launcher: launcher)

        _ = await service.endpoint(for: .correction, timeout: .seconds(5))
        _ = await service.endpoint(for: .features, timeout: .seconds(5))
        service.terminateAllNow()
        #expect(launcher.running.isEmpty)
        #expect(service.registry.count == 0)
    }
}
