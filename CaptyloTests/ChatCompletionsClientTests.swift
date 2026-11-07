import Foundation
import Testing
@testable import Captylo

struct ChatCompletionsClientTests {
    private let client = ChatCompletionsClient(baseURL: URL(string: "http://127.0.0.1:8080/v1/")!)

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Requests

    @Test func chatRequestCarriesTheOpenAIShape() throws {
        let request = client.chatRequest(
            model: "bielik-1.5b",
            system: "Popraw interpunkcję.",
            transcript: "no więc to jest test",
            maxTokens: 128,
            key: "local-token"
        )
        #expect(request.url?.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // Nothing vendor-specific left in the headers or the body.
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)

        let json = try Self.json(request)
        #expect(json["model"] as? String == "bielik-1.5b")
        #expect(json["temperature"] as? Double == 0)
        #expect(json["max_tokens"] as? Int == 128)
        #expect(json["stream"] == nil)
        #expect(json["reasoning"] == nil)
        #expect(json["provider"] == nil)
        #expect(Set(json.keys) == ["model", "messages", "temperature", "max_tokens"])

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "Popraw interpunkcję."],
            ["role": "user", "content": "no więc to jest test"],
        ])
    }

    @Test func aFullMessagesArrayKeepsItsOrderAndRoles() throws {
        let messages: [ChatMessage] = [
            .system("Zasady."),
            .user("przykład jeden"),
            .assistant("Przykład jeden."),
            .user("przykład dwa"),
            .assistant("Przykład dwa."),
            .user("właściwy tekst"),
        ]
        let request = client.chatRequest(model: "m", messages: messages, maxTokens: 64, key: "k", temperature: 0.2)
        let json = try Self.json(request)
        let sent = try #require(json["messages"] as? [[String: String]])
        #expect(sent.map { $0["role"] } == ["system", "user", "assistant", "user", "assistant", "user"])
        #expect(sent.map { $0["content"] } == messages.map(\.content))
        #expect(json["temperature"] as? Double == 0.2)
    }

    @Test func temperatureIsLeftOutWhenNil() throws {
        let request = client.chatRequest(model: "m", messages: [.user("x")], maxTokens: 8, key: "k", temperature: nil)
        let json = try Self.json(request)
        #expect(json["temperature"] == nil)
        #expect(json["max_tokens"] as? Int == 8)
    }

    @Test func anEmptyKeySendsNoAuthorization() {
        let request = client.chatRequest(model: "m", messages: [.user("x")], maxTokens: 8, key: "")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func baseURLWithOrWithoutTrailingSlashGivesTheSamePath() {
        let bare = ChatCompletionsClient(baseURL: URL(string: "https://api-sherlock.cloudferro.com/openai/v1")!)
        let slash = ChatCompletionsClient(baseURL: CloudAIRouteProvider.baseURL)
        let expected = "https://api-sherlock.cloudferro.com/openai/v1/chat/completions"
        #expect(bare.chatRequest(model: "m", messages: [.user("x")], maxTokens: 1, key: "k").url?.absoluteString == expected)
        #expect(slash.chatRequest(model: "m", messages: [.user("x")], maxTokens: 1, key: "k").url?.absoluteString == expected)
    }

    // MARK: parseChat

    @Test func parseChatReadsContentAndFinishReason() throws {
        let data = Data(Fixtures.chat(content: "\"Czysty tekst.\"", finish: "stop").utf8)
        let parsed = try client.parseChat(data)
        #expect(parsed.text == "Czysty tekst.")
        #expect(parsed.finishReason == "stop")
    }

    @Test func parseChatToleratesNullContent() throws {
        let data = Data(Fixtures.chat(content: "null", finish: "stop").utf8)
        let parsed = try client.parseChat(data)
        #expect(parsed.text == nil)
        #expect(parsed.finishReason == "stop")
    }

    @Test func parseChatReportsLengthFinish() throws {
        let data = Data(Fixtures.chat(content: "\"ucięte\"", finish: "length").utf8)
        let parsed = try client.parseChat(data)
        #expect(parsed.text == "ucięte")
        #expect(parsed.finishReason == "length")
    }

    @Test func parseChatMapsAPIErrorObjects() {
        let data = Data(#"{"error":{"message":"Rate limit exceeded","code":429}}"#.utf8)
        #expect(throws: ChatCompletionsError.rateLimited) { try client.parseChat(data) }
        // llama-server's shape.
        let server = Data(#"{"error":{"code":500,"message":"context overflow","type":"server_error"}}"#.utf8)
        #expect(throws: ChatCompletionsError.server(500)) { try client.parseChat(server) }
        // A string code is not a number: still an error, read as a server error.
        let named = Data(#"{"error":{"message":"bad key","code":"invalid_api_key"}}"#.utf8)
        #expect(throws: ChatCompletionsError.server(500)) { try client.parseChat(named) }
        #expect(throws: ChatCompletionsError.decoding) { try client.parseChat(Data("not json".utf8)) }
        #expect(throws: ChatCompletionsError.decoding) { try client.parseChat(Data(#"{"choices":[]}"#.utf8)) }
    }

    // MARK: Status mapping and errors

    @Test func statusMapping() {
        #expect(ChatCompletionsClient.mapStatus(200) == nil)
        #expect(ChatCompletionsClient.mapStatus(204) == nil)
        #expect(ChatCompletionsClient.mapStatus(401) == .unauthorized)
        #expect(ChatCompletionsClient.mapStatus(403) == .unauthorized)
        #expect(ChatCompletionsClient.mapStatus(429) == .rateLimited)
        #expect(ChatCompletionsClient.mapStatus(500) == .server(500))
        #expect(ChatCompletionsClient.mapStatus(503) == .server(503))
        #expect(ChatCompletionsError.forStatus(401) == .unauthorized)
        #expect(ChatCompletionsError.forStatus(418) == .server(418))
        #expect(ChatCompletionsError.unauthorized.status == 401)
        #expect(ChatCompletionsError.decoding.status == nil)
    }

    @Test func errorsHavePolishDescriptions() {
        let errors: [ChatCompletionsError] = [.unauthorized, .rateLimited, .server(503), .network("x"), .decoding, .missingKey]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty, "\(error)")
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
        }
        #expect(ChatCompletionsError.server(503).errorDescription?.contains("503") == true)
        #expect(ChatCompletionsError.missingKey.errorDescription == ChatCompletionsError.missingKeyMessage)
        #expect(ChatCompletionsError.missingKeyMessage.contains("Bielika w chmurze"))
    }
}

// MARK: - Fixtures

enum Fixtures {
    /// An OpenAI-compatible chat answer; `content` is raw JSON (a quoted string or `null`).
    static func chat(content: String, finish: String) -> String {
        """
        {
          "id": "chatcmpl-1",
          "model": "bielik-test",
          "choices": [
            {
              "index": 0,
              "message": { "role": "assistant", "content": \(content) },
              "finish_reason": "\(finish)"
            }
          ],
          "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
        }
        """
    }
}
