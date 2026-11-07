import Foundation

/// Finds the llama-server helper: an explicit override (tests, the integration), in Debug
/// builds the `SZPAK_LLAMA_SERVER` environment variable (a dev build without the embedded
/// helper), otherwise `Contents/MacOS/llama-server` in the app bundle.
enum LlamaServerLocator {
    static let executableName = "llama-server"
    static let environmentOverride = "SZPAK_LLAMA_SERVER"

    static func locate(
        override: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let override { return override }
        #if DEBUG
        if let path = environment[environmentOverride], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        return bundle.url(forAuxiliaryExecutable: executableName)
    }
}
