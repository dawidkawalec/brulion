import Foundation

/// Long-lived sessions and small HTTP helpers shared by the cloud modules (gotcha 64).
/// Never create a session per request: the warm TLS / H2 connection is what keeps the
/// cleanup call under the deadline.
enum HTTP {
    /// One session for every dictation LLM call: no cache, no waiting for connectivity.
    /// The real deadline is enforced in Swift (`Enhancer`, the AI mode's 1...20 s), so the
    /// timeouts only sit above the longest mode deadline: a non-streaming rewrite sends nothing
    /// until the whole answer is ready, and a 4 s idle timeout would cut an 8 s mode short.
    static let llmSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 21
        configuration.timeoutIntervalForResource = 25
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// LLM session for file transcripts: a non-streaming completion of a long transcript sends
    /// nothing until the whole answer is ready, so the timeouts sit just above the 15 s file deadline.
    static let fileLLMSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 16
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    /// Meeting AI notes: one non-streaming request over a whole transcript (up to about 4000
    /// tokens of answer), so nothing arrives for a long while. A local model reads a 1 h
    /// transcript and writes the notes in minutes, not seconds: 10 min idle, 30 min in total.
    /// Meeting AI has no other deadline (it runs in the background with progress).
    static let meetingLLMSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1800
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    /// Captylo account calls (`AccountClient`: sign-in, `/me`, billing links): small JSON
    /// requests, never cached, 15 s per request.
    static let accountSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    /// Log-friendly preview of a response body: single line, at most 200 characters.
    static func shortBody(_ data: Data) -> String {
        let limit = 200
        let text = String(decoding: data.prefix(limit * 4), as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        if text.count <= limit {
            return text
        }
        return String(text.prefix(limit - 3)) + "..."
    }
}

/// Fire-and-forget connection warm-up, debounced so hotkey mashing does not spam the host.
actor Prewarmer {
    private var lastFired: ContinuousClock.Instant?

    init() {}

    /// Sends `request` at most once per `minInterval`; the response and any error are ignored.
    func fire(_ request: URLRequest, using session: URLSession, minInterval: Duration = .seconds(20)) {
        let now = ContinuousClock.now
        if let lastFired, now - lastFired < minInterval {
            return
        }
        lastFired = now
        Task.detached(priority: .utility) {
            _ = try? await session.data(for: request)
        }
    }
}
