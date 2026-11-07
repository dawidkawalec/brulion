import Foundation
import os
import Testing
@testable import Captylo

struct LocalAIServerTests {
    private func configuration(_ folder: URL, spec: LocalModelSpec, context: Int = 8192) -> LlamaServerConfiguration {
        LlamaServerConfiguration(modelID: spec.id, modelURL: LocalModelFiles.fileURL(for: spec, in: folder), contextLength: context)
    }

    private func makeServer(
        _ folder: LocalAITempDirectory,
        launcher: FakeLlamaLauncher,
        health: FakeLlamaHealth? = nil,
        idleTimeout: Duration? = nil,
        startTimeout: Duration = .seconds(5),
        registry: LlamaProcessRegistry = LlamaProcessRegistry(),
        onUnexpectedExit: (@Sendable (String, Int32) -> Void)? = nil
    ) -> LlamaServer {
        let spec = LocalAIFixtures.spec(bytes: 16)
        LocalAIFixtures.install(spec, in: folder.url)
        return LlamaServer(
            configuration: configuration(folder.url, spec: spec),
            executable: localAIFakeExecutable,
            runDirectory: folder.url.appending(path: "run"),
            idleTimeout: idleTimeout,
            startTimeout: startTimeout,
            dependencies: .fake(launcher, health: health, registry: registry),
            onUnexpectedExit: onUnexpectedExit
        )
    }

    // MARK: Arguments and environment

    @Test func argumentsListenOnLoopbackAndNeverCarryTheToken() {
        var configuration = LlamaServerConfiguration(modelID: "bielik-1.5b-v3-q8", modelURL: URL(fileURLWithPath: "/m/Bielik 1.5B.gguf"), contextLength: 8192)
        configuration.serverSleepSeconds = 720
        let arguments = configuration.arguments(port: 51234)

        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        #expect(value("--model") == "/m/Bielik 1.5B.gguf")
        #expect(value("--host") == "127.0.0.1")
        #expect(value("--port") == "51234")
        #expect(value("--alias") == "bielik-1.5b-v3-q8")
        #expect(value("--ctx-size") == "8192")
        #expect(value("--n-gpu-layers") == "99")
        #expect(value("--parallel") == "1")
        #expect(value("--cache-ram") == String(LocalAITuning.promptCacheMiB))
        #expect(value("--log-verbosity") == "2")
        #expect(value("--sleep-idle-seconds") == "720")
        for flag in ["--jinja", "--no-webui", "--no-slots", "--offline"] {
            #expect(arguments.contains(flag))
        }
        #expect(!arguments.contains("--api-key"))
        #expect(!arguments.contains("--metrics"))
        #expect(!arguments.contains { $0.contains("0.0.0.0") })
        #expect(!LlamaServerConfiguration(modelID: "m", modelURL: URL(fileURLWithPath: "/m"), contextLength: 1).arguments(port: 1).contains("--sleep-idle-seconds"))
    }

    @Test func environmentDropsTheShellsLlamaVariables() {
        let base = [
            "HOME": "/Users/test",
            "TMPDIR": "/tmp/x/",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "LLAMA_ARG_TOOLS": "all",
            "LLAMA_ARG_HOST": "0.0.0.0",
            "LLAMA_API_KEY": "someone-elses",
            "HF_TOKEN": "hf_secret",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
        ]
        let environment = LlamaServerConfiguration.environment(token: "abc", base: base)
        #expect(environment == [
            "HOME": "/Users/test",
            "TMPDIR": "/tmp/x/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LLAMA_API_KEY": "abc",
        ])
    }

    @Test func tokenIs32RandomBytesInHex() {
        let token = LlamaServerConfiguration.makeToken()
        #expect(token.count == 64)
        #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(token != LlamaServerConfiguration.makeToken())
    }

    @Test func exitReasonsComeFromTheOutput() {
        #expect(LlamaServerError.ExitReason.classify("srv init: couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 5000") == .portInUse)
        #expect(LlamaServerError.ExitReason.classify("ggml_metal: failed to allocate buffer, size = 900 MiB\nfailed to load model") == .outOfMemory)
        #expect(LlamaServerError.ExitReason.classify("srv load_model: failed to load model, '/m.gguf'") == .modelLoad)
        #expect(LlamaServerError.ExitReason.classify("") == .unknown)
    }

    @Test func freeLoopbackPortIsUsable() throws {
        let port = try LoopbackPort.free()
        #expect(port > 1024 && port < 65536)
    }

    // MARK: Lifecycle

    @Test func concurrentCallersShareOneStart() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let server = makeServer(folder, launcher: launcher, health: FakeLlamaHealth(launcher: launcher, delay: .milliseconds(50)))

        async let first = server.endpoint()
        async let second = server.endpoint()
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(launcher.launchCount == 1)
        #expect(a.baseURL.absoluteString == "http://127.0.0.1:\(launcher.processes[0].port ?? 0)/v1/")
        #expect(a.chatCompletionsURL.absoluteString.hasSuffix("/v1/chat/completions"))
        #expect(a.modelID == "test-model")
        #expect(launcher.processes[0].environment[LlamaServerConfiguration.apiKeyVariable] == a.token)
        #expect(launcher.processes[0].environment["LLAMA_ARG_TOOLS"] == nil)
        #expect(!a.description.contains(a.token))
        #expect(await server.status == .running(port: launcher.processes[0].port ?? 0))
        await server.stop()
    }

    @Test func retriesWhenThePortWasTaken() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher(behaviors: [.exitImmediately(status: 1, output: "couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 50001")])
        let server = makeServer(folder, launcher: launcher)

        let endpoint = try await server.endpoint()

        #expect(launcher.launchCount == 2)
        #expect(endpoint.baseURL.port == launcher.processes[1].port)
        await server.stop()
    }

    @Test func modelLoadFailureIsReportedAndRetriedOnNextUse() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher(behaviors: [.exitImmediately(status: 1, output: "failed to load model, '/x.gguf'")])
        let server = makeServer(folder, launcher: launcher)

        await #expect(throws: LlamaServerError.exited(status: 1, reason: .modelLoad)) {
            try await server.endpoint()
        }
        #expect(await server.status == .failed(.exited(status: 1, reason: .modelLoad)))

        _ = try await server.endpoint()
        #expect(launcher.launchCount == 2)
        await server.stop()
    }

    @Test func repeatedFailuresCoolDown() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let failure = FakeLlamaLauncher.Behavior.exitImmediately(status: 1, output: "")
        let launcher = FakeLlamaLauncher(behaviors: Array(repeating: failure, count: LlamaServer.maxFailures))
        let server = makeServer(folder, launcher: launcher)

        for _ in 0..<LlamaServer.maxFailures {
            _ = try? await server.endpoint()
        }
        await #expect(throws: LlamaServerError.coolingDown) {
            try await server.endpoint()
        }
        #expect(launcher.launchCount == LlamaServer.maxFailures)
    }

    @Test func crashIsNoticedAndTheNextUseStartsAgain() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let crashes = OSAllocatedUnfairLock<[Int32]>(initialState: [])
        let server = makeServer(folder, launcher: launcher, onUnexpectedExit: { _, status in crashes.withLock { $0.append(status) } })

        let first = try await server.endpoint()
        launcher.processes[0].finish(status: 139)
        #expect(await localAIWaitUntil { await server.status == .failed(.exited(status: 139, reason: .unknown)) })
        #expect(crashes.withLock { $0 } == [139])

        let second = try await server.endpoint()
        #expect(launcher.launchCount == 2)
        #expect(first.baseURL != second.baseURL)
        #expect(first.token != second.token)
        await server.stop()
    }

    @Test func stopsAfterTheIdleTimeout() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let server = makeServer(folder, launcher: launcher, idleTimeout: .milliseconds(150))

        _ = try await server.endpoint()
        #expect(await localAIWaitUntil { await server.status == .stopped })
        #expect(launcher.running.isEmpty)
        #expect(launcher.processes[0].terminateCalls == 1)
    }

    @Test func idleStopWaitsForRequestsInFlight() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let server = makeServer(folder, launcher: launcher, idleTimeout: .milliseconds(100))

        _ = try await server.endpoint()
        await server.beginUse()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await server.isActive)
        await server.endUse()
        #expect(await localAIWaitUntil { await server.status == .stopped })
    }

    @Test func startTimesOutWhenHealthNeverAnswers() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let server = makeServer(folder, launcher: launcher, health: FakeLlamaHealth(launcher: launcher, neverHealthy: true), startTimeout: .milliseconds(300))

        await #expect(throws: LlamaServerError.startTimedOut) {
            try await server.endpoint()
        }
        #expect(launcher.running.isEmpty)
    }

    @Test func missingModelOrHelperFailsWithoutLaunching() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let spec = LocalAIFixtures.spec(id: "absent", bytes: 16)
        let noModel = LlamaServer(configuration: configuration(folder.url, spec: spec), executable: localAIFakeExecutable, runDirectory: nil, dependencies: .fake(launcher))
        await #expect(throws: LlamaServerError.modelMissing) { try await noModel.endpoint() }

        LocalAIFixtures.install(spec, in: folder.url)
        let noHelper = LlamaServer(configuration: configuration(folder.url, spec: spec), executable: folder.url.appending(path: "no-such-helper"), runDirectory: nil, dependencies: .fake(launcher))
        await #expect(throws: LlamaServerError.helperMissing) { try await noHelper.endpoint() }
        #expect(launcher.launchCount == 0)
    }

    @Test func pidFileAndRegistryFollowTheProcess() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let launcher = FakeLlamaLauncher()
        let registry = LlamaProcessRegistry()
        let server = makeServer(folder, launcher: launcher, registry: registry)
        let pidFile = LlamaPIDFile.url(modelID: "test-model", in: folder.url.appending(path: "run"))

        _ = try await server.endpoint()
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        #expect(text == "\(launcher.processes[0].pid)\n\(localAIFakeExecutable.path)\n")
        #expect(registry.count == 1)

        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: pidFile.path(percentEncoded: false)))
        #expect(registry.count == 0)
        #expect(await server.status == .stopped)
    }

    // MARK: Stale servers

    @Test func staleProcessOfTheRecordedExecutableIsKilled() throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }

        LlamaPIDFile.write(pid: sleeper.processIdentifier, executable: URL(fileURLWithPath: "/bin/sleep"), modelID: "stale", in: folder.url)
        #expect(LlamaPIDFile.sweep(folder.url) == 1)
        sleeper.waitUntilExit()
        #expect(!sleeper.isRunning)
        #expect(!FileManager.default.fileExists(atPath: LlamaPIDFile.url(modelID: "stale", in: folder.url).path(percentEncoded: false)))
    }

    @Test func processRunningSomethingElseIsLeftAlone() throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }

        LlamaPIDFile.write(pid: sleeper.processIdentifier, executable: URL(fileURLWithPath: "/opt/llama/llama-server"), modelID: "reused-pid", in: folder.url)
        #expect(!LlamaPIDFile.killStale(at: LlamaPIDFile.url(modelID: "reused-pid", in: folder.url)))
        #expect(sleeper.isRunning)
    }

    @Test func locatorPrefersTheOverride() {
        let override = URL(fileURLWithPath: "/tmp/llama-server")
        #expect(LlamaServerLocator.locate(override: override, environment: [:]) == override)
        #if DEBUG
        #expect(LlamaServerLocator.locate(environment: ["CAPTYLO_LLAMA_SERVER": "/x/llama-server"])?.path == "/x/llama-server")
        #endif
    }
}
