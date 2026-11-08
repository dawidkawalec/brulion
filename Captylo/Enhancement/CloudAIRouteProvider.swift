import Foundation
import os

/// "Bielik w chmurze" (docs/PRD.md 6 and 7.5): Bielik 11B v3.0 at a Polish provider
/// (`CloudAIProvider`: CloudFerro Sherlock by default, PCSS AI HUB) or on the user's own
/// OpenAI-compatible server, on the user's own key, straight from this Mac with no server of ours
/// in between. A route only while `AppSettings.cloudAIEnabled` is on (off by default) and the
/// provider's key is saved; it serves the roles the routing sends here. The local model server's
/// provider goes in front of this one at integration (`AppState`).
struct CloudAIRouteProvider: AIRouteProviding {
    /// What the provider reads from the settings, as a snapshot it can read off the main actor.
    struct Configuration: Sendable, Equatable {
        var isEnabled: Bool
        /// The model id as typed; blank = the provider's default.
        var model: String
        var provider: CloudAIProvider = .sherlock
        /// The user's server, `CloudAIProvider.custom` only.
        var customURL: String = ""

        var baseURL: URL? { provider.baseURL(customURL: customURL) }
    }

    /// Sherlock's OpenAI-compatible API (`CloudAIProvider.sherlock`, the default provider).
    static let baseURL = CloudAIProvider.sherlock.presetBaseURL!
    /// Bielik 11B v3.0 Instruct as Sherlock names it; the list of models is `GET {base}/models`.
    static let defaultModel = CloudAIProvider.sherlock.defaultModel
    /// How long a dictation-path prewarm may wait for the Keychain.
    static let prewarmKeyTimeout: Duration = .seconds(2)

    let keyStore: KeyStore
    let configuration: @Sendable () -> Configuration
    /// Replaces the client built from the provider's base URL (tests).
    let clientOverride: ChatCompletionsClient?
    let session: URLSession
    private let prewarmer = Prewarmer()

    init(
        keyStore: KeyStore,
        configuration: @escaping @Sendable () -> Configuration,
        client: ChatCompletionsClient? = nil,
        session: URLSession = HTTP.llmSession
    ) {
        self.keyStore = keyStore
        self.configuration = configuration
        clientOverride = client
        self.session = session
    }

    func route(for role: AIRole, timeout: Duration) async -> AIRoute? {
        let current = configuration()
        guard current.isEnabled else { return nil }
        guard let baseURL = current.baseURL else {
            Log.enhancement.error("Cloud AI skipped: the server address is not a valid http(s) URL")
            return nil
        }
        switch await keyStore.load(current.provider.keyAccount, timeout: timeout) {
        case .timedOut:
            Log.enhancement.error("Cloud AI skipped: the Keychain did not answer in time")
            return nil
        case .value(let stored):
            guard let key = Self.nonBlank(stored) else { return nil }
            let client = clientOverride ?? ChatCompletionsClient(baseURL: baseURL)
            return AIRoute(client: client, key: key, model: Self.model(current.model, provider: current.provider), kind: .cloud)
        }
    }

    /// Warms DNS, TLS and HTTP/2 to Sherlock (`GET {base}/models`, the answer ignored), at most
    /// once per 20 s; nothing while the cloud is off.
    func prewarm(_ role: AIRole) async {
        guard let route = await route(for: role, timeout: Self.prewarmKeyTimeout) else { return }
        await prewarmer.fire(Self.modelsRequest(baseURL: route.client.baseURL, key: route.key), using: session)
    }

    // MARK: Settings helpers

    /// "Testuj połączenie": one tiny chat call with the key and model typed in the settings
    /// (saved or not, cloud on or off) at the provider's address. The round trip in milliseconds,
    /// or why it failed.
    static func testConnection(
        key: String,
        model: String,
        provider: CloudAIProvider = .sherlock,
        client: ChatCompletionsClient = ChatCompletionsClient(baseURL: baseURL),
        session: URLSession = HTTP.llmSession,
        timeout: Duration = Enhancer.utilityDeadline
    ) async -> Result<Int, any Error> {
        guard let key = nonBlank(key) else { return .failure(ChatCompletionsError.missingKey) }
        let request = client.chatRequest(
            model: Self.model(model, provider: provider),
            messages: [.system("Odpowiedz jednym słowem: ok."), .user("ok")],
            maxTokens: 1,
            key: key
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, http) = try await Enhancer.send(request, using: session, budget: timeout)
            if let error = ChatCompletionsClient.mapStatus(http.statusCode) {
                Log.enhancement.error("Cloud AI test failed: HTTP \(http.statusCode) \(HTTP.shortBody(data), privacy: .public)")
                return .failure(error)
            }
            _ = try client.parseChat(data)
            return .success(Int((clock.now - start) / .milliseconds(1)))
        } catch let error as ChatCompletionsError {
            return .failure(error)
        } catch let error as EnhancerError {
            return .failure(error)
        } catch {
            return .failure(ChatCompletionsError.network(error.localizedDescription))
        }
    }

    /// `GET {base}/models` with the key: the cheapest authenticated request Sherlock answers.
    static func modelsRequest(baseURL: URL, key: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The model id as typed, or the provider's default when the field is blank.
    static func model(_ typed: String, provider: CloudAIProvider = .sherlock) -> String {
        nonBlank(typed) ?? provider.defaultModel
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
