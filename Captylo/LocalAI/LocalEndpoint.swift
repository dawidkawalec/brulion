import Foundation

/// Where to send an OpenAI-compatible request for a role: a running llama-server on loopback.
/// Send `Authorization: Bearer <token>` and `model: modelID`.
struct LocalEndpoint: Equatable, Sendable, CustomStringConvertible {
    /// `http://127.0.0.1:<port>/v1/`
    let baseURL: URL
    let token: String
    let modelID: String

    var chatCompletionsURL: URL {
        baseURL.appending(path: "chat/completions")
    }

    var authorizationHeader: String {
        "Bearer \(token)"
    }

    /// Never prints the token (endpoints may end up in logs or test output).
    var description: String {
        "LocalEndpoint(\(baseURL.absoluteString), model: \(modelID))"
    }
}
