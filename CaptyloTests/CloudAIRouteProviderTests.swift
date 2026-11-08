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

    // MARK: Providers

    @Test func thePresetsKnowTheirAddressModelAndKey() {
        #expect(CloudAIProvider.sherlock.presetBaseURL?.absoluteString == "https://api-sherlock.cloudferro.com/openai/v1/")
        #expect(CloudAIProvider.sherlock.defaultModel == "Bielik-11B-v3.0-Instruct")
        #expect(CloudAIProvider.sherlock.keyAccount == KeyStore.Account.cloudFerroSherlock)
        #expect(CloudAIProvider.pcss.presetBaseURL?.absoluteString == "https://llm.hpc.psnc.pl/v1/")
        #expect(CloudAIProvider.pcss.defaultModel == "bielik:11b")
        #expect(CloudAIProvider.pcss.keyAccount == "pcss-ai-hub")
        #expect(CloudAIProvider.custom.presetBaseURL == nil)
        #expect(CloudAIProvider.custom.keyAccount == "cloud-custom")
        #expect(Set(KeyStore.Account.cloudKeys).count == CloudAIProvider.allCases.count)
    }

    @Test func theOwnServerAddressIsCheckedAndGetsATrailingSlash() {
        let custom = CloudAIProvider.custom
        #expect(custom.baseURL(customURL: " https://ai.firma.pl/v1 ")?.absoluteString == "https://ai.firma.pl/v1/")
        #expect(custom.baseURL(customURL: "http://10.0.0.5:8000/v1/")?.absoluteString == "http://10.0.0.5:8000/v1/")
        #expect(custom.baseURL(customURL: "") == nil)
        #expect(custom.baseURL(customURL: "ai.firma.pl/v1") == nil)
        #expect(custom.baseURL(customURL: "ftp://ai.firma.pl/v1") == nil)
        #expect(custom.displayName(customURL: "https://ai.firma.pl/v1") == "ai.firma.pl")
        // A preset ignores the typed address.
        #expect(CloudAIProvider.pcss.baseURL(customURL: "https://inny.pl/v1")?.host() == "llm.hpc.psnc.pl")
        #expect(CloudAIProvider.pcss.displayName(customURL: "") == "PCSS AI HUB")
    }

    @Test func eachProviderRoutesToItsAddressWithItsOwnKey() async throws {
        let keyStore = KeyStore.inMemory(seed: ["cloudferro-sherlock": "sherlock-key", "pcss-ai-hub": "pcss-key", "cloud-custom": "own-key"])
        func route(_ configuration: CloudAIRouteProvider.Configuration) async -> AIRoute? {
            await CloudAIRouteProvider(keyStore: keyStore, configuration: { configuration }, session: StubURLProtocol.makeSession())
                .route(for: .features, timeout: .seconds(1))
        }
        let pcss = try #require(await route(.init(isEnabled: true, model: "", provider: .pcss)))
        #expect(pcss.client.baseURL.absoluteString == "https://llm.hpc.psnc.pl/v1/")
        #expect(pcss.key == "pcss-key")
        #expect(pcss.model == "bielik:11b")

        let own = try #require(await route(.init(isEnabled: true, model: "bielik", provider: .custom, customURL: "https://ai.firma.pl/v1")))
        #expect(own.client.baseURL.absoluteString == "https://ai.firma.pl/v1/")
        #expect(own.key == "own-key")
        #expect(own.model == "bielik")

        // An own server without a valid address has no route.
        #expect(await route(.init(isEnabled: true, model: "", provider: .custom, customURL: "nie-adres")) == nil)
        // Another provider's key is never used.
        let noKey = CloudAIRouteProvider(keyStore: KeyStore.inMemory(seed: ["cloudferro-sherlock": "sherlock-key"]),
                                         configuration: { .init(isEnabled: true, model: "", provider: .pcss) })
        #expect(await noKey.route(for: .features, timeout: .seconds(1)) == nil)
    }

    @MainActor
    @Test func changingTheProviderDropsTheTypedModel() throws {
        let suite = "pl.craftweb.szpak.tests.cloud-provider.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.cloudAIProvider == .sherlock)
        settings.cloudAIModel = "Bielik-11B-v2.6-Instruct"
        settings.setCloudAIProvider(.pcss)
        #expect(settings.cloudAIProvider == .pcss)
        #expect(settings.cloudAIModel == "bielik:11b")
        #expect(defaults.string(forKey: "ai.cloud.provider") == "pcss")
        settings.cloudAICustomURL = "https://ai.firma.pl/v1"
        settings.setCloudAIProvider(.custom)
        #expect(settings.cloudAIConfiguration.baseURL?.absoluteString == "https://ai.firma.pl/v1/")
        defaults.set("openai", forKey: "ai.cloud.provider")
        #expect(settings.cloudAIProvider == .sherlock, "an unknown stored provider reads as Sherlock")
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
