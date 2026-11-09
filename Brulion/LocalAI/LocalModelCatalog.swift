import Foundation

/// The Bielik models the app offers (PRD 6). All Apache-2.0, ungated, plain HTTPS from
/// SpeakLeash's Hugging Face repositories, pinned to a commit; never bundled with the app.
enum LocalModelCatalog {
    /// Where downloads start. Hugging Face redirects to its CDN; the downloader follows only
    /// redirects to `downloadHostSuffixes` (docs/local-ai.md, "Hosts contacted").
    static let downloadBase = URL(string: "https://huggingface.co")!

    /// Every host the local AI ever contacts, for the privacy screen: huggingface.co and the
    /// CDN it redirects downloads to (subdomains of huggingface.co and hf.co, e.g.
    /// `cdn-lfs.hf.co`, `cas-bridge.xethub.hf.co`). Only while a model downloads; inference
    /// runs on 127.0.0.1.
    static let downloadHostSuffixes = ["huggingface.co", "hf.co"]

    static let bielik15B = LocalModelSpec(
        id: "bielik-1.5b-v3-q8",
        displayName: "Bielik 1.5B v3 (Q8_0)",
        defaultRole: .correction,
        repository: "speakleash/Bielik-1.5B-v3.0-Instruct-GGUF",
        revision: "99d72cc757be4f8b958018f12d6898bad5c19c9e",
        fileName: "Bielik-1.5B-v3.0-Instruct.Q8_0.gguf",
        bytes: 1_699_568_288,
        sha256: "e206ebbd9ee00cc8f14af5a096ad3f193a59608c63905316e8dc680c96655a60",
        contextLength: LocalAITuning.correctionContext,
        licence: "Apache-2.0"
    )

    static let bielikMinitron7B = LocalModelSpec(
        id: "bielik-minitron-7b-v3-q4km",
        displayName: "Bielik Minitron 7B v3 (Q4_K_M)",
        defaultRole: .features,
        repository: "speakleash/Bielik-Minitron-7B-v3.0-Instruct-GGUF",
        revision: "2d8c947d590de1602ca60c73939822a2e7d55b23",
        fileName: "minitron-Bielik-7B-v3.0-Instruct-GGUF.Q4_K_M.gguf",
        bytes: 4_501_556_256,
        sha256: "0c1475426645924970b9ed1383df1ce89c47b991e7b78ce9a12d3fde94455b16",
        contextLength: LocalAITuning.featuresContext,
        licence: "Apache-2.0"
    )

    static let bielik45B = LocalModelSpec(
        id: "bielik-4.5b-v3-q8",
        displayName: "Bielik 4.5B v3 (Q8_0)",
        defaultRole: nil,
        repository: "speakleash/Bielik-4.5B-v3.0-Instruct-GGUF",
        revision: "3ee7b47bcd0ad7bc6a4c45bb7bad3e0b2fe066ad",
        fileName: "Bielik-4.5B-v3.0-Instruct.Q8_0.gguf",
        bytes: 5_061_215_424,
        sha256: "562f2291de257890adf2b4a914da8b194affe6a7a838a6b7ef3d342f306c1b7f",
        contextLength: LocalAITuning.featuresContext,
        licence: "Apache-2.0"
    )

    /// Every model, in the order Modele lists them.
    static let all: [LocalModelSpec] = [bielik15B, bielikMinitron7B, bielik45B]

    static func model(id: String) -> LocalModelSpec? {
        all.first { $0.id == id }
    }

    /// The model a role uses when nothing else is chosen (the 16 GB tier, `HardwareProfile`).
    static func defaultModel(for role: LocalRole) -> LocalModelSpec {
        switch role {
        case .correction: bielik15B
        case .features: bielikMinitron7B
        }
    }

    /// Whether `host` is huggingface.co or its download CDN.
    static func isDownloadHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return downloadHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
