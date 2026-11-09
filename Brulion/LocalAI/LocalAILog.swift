import os

/// The local AI's logger: states, model ids, sizes, ports and exit codes only. Never a prompt,
/// a model answer, the server's output or the access token.
enum LocalAILog {
    static let logger = Logger(subsystem: Log.subsystem, category: "localai")
}
