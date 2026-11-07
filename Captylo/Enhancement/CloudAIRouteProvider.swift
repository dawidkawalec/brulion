import Foundation
import os

/// "Bielik w chmurze" (docs/PRD.md 6 and 7.5): Bielik 11B in CloudFerro Sherlock on the user's
/// own key, straight from this Mac with no server of ours in between. A route only while
/// `AppSettings.cloudAIEnabled` is on (off by default) and a key is saved; it serves both roles.
/// The local model server's provider goes in front of this one at integration (`AppState`).
struct CloudAIRouteProvider: AIRouteProviding {
    /// What the provider reads from the settings, as a snapshot it can read off the main actor.
    struct Configuration: Sendable, Equatable {
        var isEnabled: Bool
        var model: String
    }

    /// Sherlock's OpenAI-compatible API. Source (checked 2026-11-07):
    /// https://docs.cloudferro.com/en/latest/sherlock/Sherlock-chat-completion-endpoint-on-CloudFerro-Cloud.html
    /// (`POST {base}/chat/completions` with `Authorization: Bearer <key>`).
    static let baseURL = URL(string: "https://api-sherlock.cloudferro.com/openai/v1/")!
    /// Bielik 11B v3.0 Instruct as the same page names it in its examples; the list of models is
    /// `GET {base}/models` (https://docs.cloudferro.com/en/latest/sherlock/Models-endpoints-on-CloudFerro-Cloud.html).
    /// The default of `AppSettings.cloudAIModel`, which the user can change.
    static let defaultModel = "Bielik-11B-v3.0-Instruct"
    /// How long a dictation-path prewarm may wait for the Keychain.
    static let prewarmKeyTimeout: Duration = .seconds(2)

    let keyStore: KeyStore
    let configuration: @Sendable () -> Configuration
    let client: ChatCompletionsClient
    let session: URLSession
    private let prewarmer = Prewarmer()

    init(
        keyStore: KeyStore,
        configuration: @escaping @Sendable () -> Configuration,
        client: ChatCompletionsClient = ChatCompletionsClient(baseURL: CloudAIRouteProvider.baseURL),
        session: URLSession = HTTP.llmSession
    ) {
        self.keyStore = keyStore
        self.configuration = configuration
        self.client = client
        self.session = session
    }

    func route(for role: AIRole, timeout: Duration) async -> AIRoute? {
        let current = configuration()
        guard current.isEnabled else { return nil }
        switch await keyStore.load(KeyStore.Account.cloudFerroSherlock, timeout: timeout) {
        case .timedOut:
            Log.enhancement.error("Cloud AI skipped: the Keychain did not answer in time")
            return nil
        case .value(let stored):
            guard let key = Self.nonBlank(stored) else { return nil }
            return AIRoute(client: client, key: key, model: Self.model(current.model), kind: .cloud)
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
    /// (saved or not, cloud on or off). The round trip in milliseconds, or why it failed.
    static func testConnection(
        key: String,
        model: String,
        client: ChatCompletionsClient = ChatCompletionsClient(baseURL: baseURL),
        session: URLSession = HTTP.llmSession,
        timeout: Duration = Enhancer.utilityDeadline
    ) async -> Result<Int, any Error> {
        guard let key = nonBlank(key) else { return .failure(ChatCompletionsError.missingKey) }
        let request = client.chatRequest(
            model: Self.model(model),
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

    /// The model id as typed, or the default when the field is blank.
    static func model(_ typed: String) -> String {
        nonBlank(typed) ?? defaultModel
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
