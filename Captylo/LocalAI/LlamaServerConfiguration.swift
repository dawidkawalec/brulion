import Foundation

/// How one llama-server process is started: the model file, its context and the flags.
/// Pure (arguments and environment are built here and unit-tested).
struct LlamaServerConfiguration: Equatable, Sendable {
    /// The server only ever listens here.
    static let host = "127.0.0.1"
    /// llama-server reads its `--api-key` from this variable; passing the token through the
    /// environment keeps it out of `ps` (arguments are visible to every user of the Mac).
    static let apiKeyVariable = "LLAMA_API_KEY"
    /// The only variables the server inherits. Everything else is dropped on purpose:
    /// llama-server reads `LLAMA_ARG_*` (tools, prompt logging, web UI, ...) and `HF_*` from
    /// its environment, and none of that may come from the user's shell.
    static let inheritedVariables: Set<String> = ["HOME", "TMPDIR", "USER", "LOGNAME"]

    let modelID: String
    let modelURL: URL
    var contextLength: Int
    /// Layers on the GPU (99 = all).
    var gpuLayers = 99
    /// One request at a time: dictation and modes never overlap per model, and every slot
    /// would take its own share of the context.
    var parallelSlots = 1
    var promptCacheMiB = LocalAITuning.promptCacheMiB
    /// llama-server's own idle sleep (frees the model), set a bit above the app's idle stop:
    /// it only matters for a server orphaned by a crashed app. nil = off.
    var serverSleepSeconds: Int?

    /// Command line for `llama-server`. Never holds the token or any text.
    func arguments(port: Int) -> [String] {
        var arguments = [
            "--model", modelURL.path(percentEncoded: false),
            "--alias", modelID,
            "--host", Self.host,
            "--port", String(port),
            "--ctx-size", String(contextLength),
            "--n-gpu-layers", String(gpuLayers),
            "--parallel", String(parallelSlots),
            "--jinja",
            "--flash-attn", "auto",
            "--cache-ram", String(promptCacheMiB),
            // No web UI, no /slots (it shows the prompts in the cache), no downloads.
            "--no-webui",
            "--no-slots",
            "--offline",
            // Errors and warnings only: request and response bodies are logged at debug level,
            // and the output is kept in memory for failure reasons, never written anywhere.
            "--log-verbosity", "2",
            "--log-colors", "off",
        ]
        if let serverSleepSeconds {
            arguments += ["--sleep-idle-seconds", String(serverSleepSeconds)]
        }
        return arguments
    }

    /// The server's whole environment: `inheritedVariables` from `base`, a fixed PATH and the token.
    static func environment(token: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base.filter { inheritedVariables.contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment[apiKeyVariable] = token
        return environment
    }

    /// 32 random bytes as 64 lowercase hex characters (`SystemRandomNumberGenerator` is
    /// cryptographically secure on Apple platforms).
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
