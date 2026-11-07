import Foundation

/// Asks a starting server whether its model is loaded; injected so tests need no server.
protocol LlamaHealthChecking: Sendable {
    func isHealthy(baseURL: URL, token: String) async -> Bool
}

/// `GET /health` on the loopback server: 200 once the model is loaded, 503 while loading.
struct HTTPLlamaHealthCheck: LlamaHealthChecking {
    let session: URLSession

    init(session: URLSession = HTTPLlamaHealthCheck.makeSession()) {
        self.session = session
    }

    /// Short timeouts, no cache, no proxy (the server is on 127.0.0.1).
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    func isHealthy(baseURL: URL, token: String) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
