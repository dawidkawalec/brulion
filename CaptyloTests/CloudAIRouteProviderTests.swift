import Foundation
import Security
import Testing
@testable import Captylo

/// "Bielik w chmurze": a route only while the setting is on and a key is saved.
struct CloudAIRouteProviderTests {
    private static func provider(
        enabled: Bool,
        key: String?,
        model: String = CloudAIRouteProvider.defaultModel,
        client: ChatCompletionsClient = ChatCompletionsClient(baseURL: CloudAIRouteProvider.baseURL),
        session: URLSession = StubURLProtocol.makeSession()
    ) -> CloudAIRouteProvider {
        let keys = key.map { [KeyStore.Account.cloudFerroSherlock: $0] } ?? [:]
        return CloudAIRouteProvider(
            keyStore: KeyStore.inMemory(seed: keys),
            configuration: { CloudAIRouteProvider.Configuration(isEnabled: enabled, model: model) },
            client: client,
            session: session
        )
    }

    @Test func offMeansNoRouteEvenWithAKey() async {
        let provider = Self.provider(enabled: false, key: "sherlock-key")
        for role in AIRole.allCases {
            #expect(await provider.route(for: role, timeout: .seconds(1)) == nil)
        }
    }

    @Test func onWithoutAKeyMeansNoRoute() async {
        #expect(await Self.provider(enabled: true, key: nil).route(for: .features, timeout: .seconds(1)) == nil)
        #expect(await Self.provider(enabled: true, key: "   ").route(for: .correction, timeout: .seconds(1)) == nil)
    }

    @Test func onWithAKeyRoutesBothRolesToSherlock() async throws {
        let provider = Self.provider(enabled: true, key: " sherlock-key \n")
        for role in AIRole.allCases {
            let route = try #require(await provider.route(for: role, timeout: .seconds(1)))
            #expect(route.kind == .cloud)
            #expect(route.key == "sherlock-key")
            #expect(route.model == "Bielik-11B-v3.0-Instruct")
            #expect(route.client.baseURL.absoluteString == "https://api-sherlock.cloudferro.com/openai/v1/")
        }
    }

    @Test func theModelIdComesFromTheSettingAndFallsBackWhenBlank() async throws {
        let custom = Self.provider(enabled: true, key: "k", model: " speakleash/Bielik-11B-v3.0-Instruct ")
        #expect(try #require(await custom.route(for: .features, timeout: .seconds(1))).model == "speakleash/Bielik-11B-v3.0-Instruct")
        let blank = Self.provider(enabled: true, key: "k", model: "  ")
        #expect(try #require(await blank.route(for: .features, timeout: .seconds(1))).model == CloudAIRouteProvider.defaultModel)
    }

    @Test func aKeychainThatDoesNotAnswerMeansNoRoute() async {
        let gate = DispatchSemaphore(value: 0)
        let keyStore = KeyStore(service: "pl.craftweb.szpak.tests") { _, _ in
            gate.wait()
            return KeyStore.ReadResult(value: "late", status: errSecSuccess)
        }
        let provider = CloudAIRouteProvider(
            keyStore: keyStore,
            configuration: { CloudAIRouteProvider.Configuration(isEnabled: true, model: "m") }
        )
        #expect(await provider.route(for: .features, timeout: .milliseconds(50)) == nil)
        gate.signal()
    }

    @MainActor
    @Test func theSettingsDefaultToOffAndTheDocumentedModel() throws {
        let suite = "pl.craftweb.szpak.tests.cloud-ai.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.cloudAIConfiguration == CloudAIRouteProvider.Configuration(isEnabled: false, model: "Bielik-11B-v3.0-Instruct"))
        settings.cloudAIEnabled = true
        settings.cloudAIModel = "inny-model"
        #expect(settings.cloudAIConfiguration == CloudAIRouteProvider.Configuration(isEnabled: true, model: "inny-model"))
        settings.reset()
        #expect(!settings.cloudAIEnabled)
        #expect(settings.cloudAIModel == CloudAIRouteProvider.defaultModel)
    }

    // MARK: Prewarm and the connection test

    @Test func prewarmHitsTheModelsEndpointOnlyWhileOn() async throws {
        let counter = Counter()
        let baseURL = StubURLProtocol.register { request in
            #expect(request.url?.path().hasSuffix("/models") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sherlock-key")
            counter.increment()
            return .json(#"{"data":[]}"#)
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let client = ChatCompletionsClient(baseURL: baseURL)

        await Self.provider(enabled: false, key: "sherlock-key", client: client).prewarm(.correction)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 0)

        let on = Self.provider(enabled: true, key: "sherlock-key", client: client)
        await on.prewarm(.correction)
        await on.prewarm(.features)
        try await waitUntil { counter.value >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 1, "debounced")
    }

    @Test func connectionTestSendsTheTypedKeyAndModel() async throws {
        let baseURL = StubURLProtocol.register { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer typed-key")
            let body = StubURLProtocol.body(of: request)
            #expect(body["model"] as? String == "Bielik-11B-v3.0-Instruct")
            #expect(body["max_tokens"] as? Int == 1)
            return .json(Fixtures.chat(content: "\"ok\"", finish: "length"))
        }
        defer { StubURLProtocol.unregister(baseURL) }
        let result = await CloudAIRouteProvider.testConnection(
            key: " typed-key ",
            model: "",
            client: ChatCompletionsClient(baseURL: baseURL),
            session: StubURLProtocol.makeSession()
        )
        let ms = try result.get()
        #expect(ms >= 0)
    }

    @Test func connectionTestReportsAMissingOrRejectedKey() async {
        guard case .failure(let missing) = await CloudAIRouteProvider.testConnection(key: "  ", model: "m") else {
            Issue.record("Expected failure without a key")
            return
        }
        #expect(missing as? ChatCompletionsError == .missingKey)

        let baseURL = StubURLProtocol.register { _ in .json(#"{"error":{"message":"bad key","code":401}}"#, status: 401) }
        defer { StubURLProtocol.unregister(baseURL) }
        let rejected = await CloudAIRouteProvider.testConnection(
            key: "bad",
            model: "m",
            client: ChatCompletionsClient(baseURL: baseURL),
            session: StubURLProtocol.makeSession()
        )
        guard case .failure(let error) = rejected else {
            Issue.record("Expected failure on 401")
            return
        }
        #expect(error as? ChatCompletionsError == .unauthorized)
    }
}
