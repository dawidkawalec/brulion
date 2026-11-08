import Foundation

/// One message of an OpenAI-compatible chat request: the system instructions, few-shot
/// user / assistant pairs, then the user's data.
struct ChatMessage: Sendable, Equatable, Encodable {
    enum Role: String, Sendable, Equatable, Encodable {
        case system
        case user
        case assistant
    }

    var role: Role
    var content: String

    static func system(_ content: String) -> ChatMessage { ChatMessage(role: .system, content: content) }
    static func user(_ content: String) -> ChatMessage { ChatMessage(role: .user, content: content) }
    static func assistant(_ content: String) -> ChatMessage { ChatMessage(role: .assistant, content: content) }
}

/// Request builder and parser for any OpenAI-compatible chat server: the local model server on
/// 127.0.0.1 and CloudFerro Sherlock (docs/PRD.md section 5). `POST {baseURL}/chat/completions`
/// with `Authorization: Bearer <key>`, non-streaming. Pure value type: no networking here, so
/// every request and parser is unit-tested with fixtures.
struct ChatCompletionsClient: Sendable, Equatable {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: Chat completions

    /// A full conversation: `messages` as given, bounded `max_tokens`, and `temperature` when set
    /// (nil leaves the server's default). An empty `key` sends no `Authorization` header.
    func chatRequest(
        model: String,
        messages: [ChatMessage],
        maxTokens: Int,
        key: String,
        temperature: Double? = 0
    ) -> URLRequest {
        let body = ChatBody(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens)
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(body)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// The dictation shape: the system prompt first, the transcript alone as the user message.
    func chatRequest(
        model: String,
        system: String,
        transcript: String,
        maxTokens: Int,
        key: String,
        temperature: Double? = 0
    ) -> URLRequest {
        chatRequest(
            model: model,
            messages: [.system(system), .user(transcript)],
            maxTokens: maxTokens,
            key: key,
            temperature: temperature
        )
    }

    /// `choices[0].message.content` as an optional string plus `finish_reason` (gotcha 68).
    func parseChat(_ data: Data) throws -> (text: String?, finishReason: String?) {
        let response: ChatResponse
        do {
            response = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw ChatCompletionsError.decoding
        }
        if let error = response.error {
            let code = error.code ?? 500
            throw Self.mapStatus(code) ?? .server(code)
        }
        guard let choice = response.choices?.first else {
            throw ChatCompletionsError.decoding
        }
        return (choice.message?.content, choice.finishReason)
    }

    /// nil for 2xx, a typed error otherwise.
    static func mapStatus(_ code: Int) -> ChatCompletionsError? {
        switch code {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .server(code)
        }
    }

    // MARK: Wire types

    private struct ChatBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case maxTokens = "max_tokens"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encode(maxTokens, forKey: .maxTokens)
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        /// `{"error": {"code": 500, "message": ...}}`. Some servers send a string code
        /// ("invalid_api_key"): it reads as no code rather than failing the whole answer.
        struct APIError: Decodable {
            let message: String?
            let code: Int?

            enum CodingKeys: String, CodingKey {
                case message, code
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                message = try? container.decodeIfPresent(String.self, forKey: .message)
                code = try? container.decodeIfPresent(Int.self, forKey: .code)
            }
        }

        let choices: [Choice]?
        let error: APIError?
    }
}

enum ChatCompletionsError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case rateLimited
    case server(Int)
    case network(String)
    case decoding
    /// No AI route: no local model and the cloud is off (or has no key).
    case missingKey

    /// The error for a non-2xx status (a 2xx maps to `.server` too: callers only pass failures).
    static func forStatus(_ code: Int) -> ChatCompletionsError {
        ChatCompletionsClient.mapStatus(code) ?? .server(code)
    }

    /// HTTP status this error stands for (history notes), nil for transport errors.
    var status: Int? {
        switch self {
        case .unauthorized: return 401
        case .rateLimited: return 429
        case .server(let code): return code
        case .network, .decoding, .missingKey: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String(localized: "Nieprawidłowy klucz AI.")
        case .rateLimited:
            return String(localized: "AI: przekroczono limit zapytań. Spróbuj za chwilę.")
        case .server(let code):
            return String(localized: "AI: błąd serwera (kod \(String(code))).")
        case .network(let detail):
            return String(localized: "Błąd sieci: \(detail)")
        case .decoding:
            return String(localized: "Nieoczekiwana odpowiedź AI.")
        case .missingKey:
            return Self.missingKeyMessage
        }
    }

    /// The one "no AI" message of the app ("Przetwórz przez AI", "Testuj tryb", the test call).
    static var missingKeyMessage: String {
        String(localized: "AI jest niedostępne: pobierz model lokalny albo dodaj klucz Bielika w chmurze w Modele.")
    }
}
