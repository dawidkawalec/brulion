import Foundation
import Testing
@testable import Captylo

/// Runs the real llama-server with a real model. Off in `make test`; the command is in
/// docs/local-ai.md ("Tests"): environment variables `TEST_RUNNER_CAPTYLO_LLAMA_E2E=1`,
/// `TEST_RUNNER_CAPTYLO_LLAMA_SERVER` and `TEST_RUNNER_CAPTYLO_LLAMA_MODEL` on xcodebuild
/// (it hands them to the tests without the prefix). It loads the model into memory, so take
/// the shared heavy-work lock first. The model file is only read where it is.
struct LocalAIEndToEndTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var isEnabled: Bool {
        environment["CAPTYLO_LLAMA_E2E"] == "1" && environment["CAPTYLO_LLAMA_SERVER"] != nil && environment["CAPTYLO_LLAMA_MODEL"] != nil
    }

    @Test(.enabled(if: LocalAIEndToEndTests.isEnabled), .timeLimit(.minutes(3)))
    func correctsASyntheticSentence() async throws {
        let executable = URL(fileURLWithPath: try #require(Self.environment["CAPTYLO_LLAMA_SERVER"]))
        let model = URL(fileURLWithPath: try #require(Self.environment["CAPTYLO_LLAMA_MODEL"]))
        let size = try #require(LocalModelFiles.size(of: model))
        let spec = LocalModelSpec(
            id: "e2e-model",
            displayName: "E2E",
            defaultRole: .correction,
            repository: "local",
            revision: "local",
            fileName: model.lastPathComponent,
            bytes: size,
            sha256: "",
            contextLength: 2048,
            licence: "Apache-2.0"
        )
        let run = LocalAITempDirectory()
        defer { run.remove() }
        let service = LocalAIService(
            roleModels: [.correction: spec],
            modelsDirectory: model.deletingLastPathComponent(),
            runDirectory: run.url,
            executable: executable,
            options: LocalAIService.Options(idleTimeout: nil)
        )

        let clock = ContinuousClock()
        let started = clock.now
        let endpoint = try #require(await service.endpoint(for: .correction, timeout: .seconds(90)))
        let loadTime = clock.now - started
        #expect(endpoint.baseURL.host() == "127.0.0.1")

        let raw = "jutro o dziesiatej mamy spotkanie z zespolem w sprawie nowej strony internetowej"
        let body: [String: Any] = [
            "model": endpoint.modelID,
            "temperature": 0,
            "max_tokens": 96,
            "messages": [
                ["role": "system", "content": "Popraw interpunkcję, wielkie litery i polskie znaki. Nie zmieniaj treści. Zwróć tylko poprawiony tekst."],
                ["role": "user", "content": raw],
            ],
        ]
        var request = URLRequest(url: endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let requestStart = clock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        let requestTime = clock.now - requestStart
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let choices = try #require(json["choices"] as? [[String: Any]])
        let message = try #require(choices.first?["message"] as? [String: Any])
        let content = try #require(message["content"] as? String)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let verdict = CorrectionGuard.check(input: raw, output: content)
        print("LocalAI e2e: load \(loadTime), request \(requestTime), guard \(verdict.map(\.code) ?? "accepted")")

        var unauthorized = request
        unauthorized.setValue(nil, forHTTPHeaderField: "Authorization")
        let (_, denied) = try await URLSession.shared.data(for: unauthorized)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)

        await service.shutdown()
        #expect(service.registry.count == 0)
        #expect(await service.status(for: .correction) == .stopped)
    }
}
