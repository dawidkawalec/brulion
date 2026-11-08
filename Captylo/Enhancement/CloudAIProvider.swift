import Foundation

/// Who serves "Bielik w chmurze" (docs/PRD.md 7.5, decision of 2026-11-08: only providers that
/// keep the data in Poland, plus the user's own OpenAI-compatible server). Each one is the same
/// OpenAI-compatible chat API, so a provider is only its base URL, its Bielik model id and its
/// own Keychain item (switching never loses a saved key). Sources, checked 2026-11-08: the
/// providers listed on https://www.bielik.ai/blog/jak-korzystac-z-bielika and their API docs.
enum CloudAIProvider: String, CaseIterable, Hashable, Sendable {
    /// CloudFerro Sherlock, Polish cloud; CloudFerro states zero retention of prompts and answers.
    /// https://docs.cloudferro.com/en/latest/sherlock/Sherlock-chat-completion-endpoint-on-CloudFerro-Cloud.html
    case sherlock
    /// PCSS AI HUB, Poznań Supercomputing and Networking Center (paid subscription for companies,
    /// free for scientists and students). https://help.pcss.plcloud.pl/portal/ai/
    case pcss
    /// Any OpenAI-compatible server the user points at (`AppSettings.cloudAICustomURL`), e.g. a
    /// company's own vLLM with Bielik.
    case custom

    /// The API base (`{base}/chat/completions`), nil for `custom` (the user's URL).
    var presetBaseURL: URL? {
        switch self {
        case .sherlock: URL(string: "https://api-sherlock.cloudferro.com/openai/v1/")!
        case .pcss: URL(string: "https://llm.hpc.psnc.pl/v1/")!
        case .custom: nil
        }
    }

    /// Bielik 11B v3.0 Instruct as the provider names it (model ids are case-sensitive).
    var defaultModel: String {
        switch self {
        case .sherlock: "Bielik-11B-v3.0-Instruct"
        case .pcss: "bielik:11b"
        case .custom: "speakleash/Bielik-11B-v3.0-Instruct"
        }
    }

    /// The provider's own Keychain item (`KeyStore`); Sherlock keeps the item of earlier builds.
    var keyAccount: String {
        switch self {
        case .sherlock: KeyStore.Account.cloudFerroSherlock
        case .pcss: KeyStore.Account.pcssAIHub
        case .custom: KeyStore.Account.customCloud
        }
    }

    /// Where the user creates an account and a key.
    var setupURL: URL {
        switch self {
        case .sherlock: URL(string: "https://docs.cloudferro.com/en/latest/sherlock/How-to-set-up-Sherlock-AI-on-CloudFerro-Cloud.html")!
        case .pcss: URL(string: "https://help.pcss.plcloud.pl/portal/ai/")!
        case .custom: URL(string: "https://www.bielik.ai/blog/jak-korzystac-z-bielika")!
        }
    }

    /// The base URL for `customURL` (custom only): `https://host/v1` with a trailing slash so
    /// `appending(path:)` keeps the path; nil unless it is an http(s) URL with a host.
    func baseURL(customURL: String) -> URL? {
        if let preset = presetBaseURL { return preset }
        var text = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else {
            return nil
        }
        return url
    }

    /// The provider's name where Szpak says where the text goes: a proper name, or the host of
    /// the user's server.
    func displayName(customURL: String) -> String {
        switch self {
        case .sherlock: "CloudFerro Sherlock"
        case .pcss: "PCSS AI HUB"
        case .custom: baseURL(customURL: customURL)?.host() ?? customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
