import CryptoKit
import Foundation
import os
@testable import Captylo

/// A unique folder under the temp directory, removed by `remove()`.
struct LocalAITempDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "localai-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum LocalAIFixtures {
    /// Deterministic synthetic bytes standing in for a model file.
    static func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func spec(id: String = "test-model", bytes: Int64, sha256: String = String(repeating: "0", count: 64), role: LocalRole? = .correction) -> LocalModelSpec {
        LocalModelSpec(
            id: id,
            displayName: "Test \(id)",
            defaultRole: role,
            repository: "speakleash/Test-GGUF",
            revision: "0123456789abcdef0123456789abcdef01234567",
            fileName: "\(id).gguf",
            bytes: bytes,
            sha256: sha256,
            contextLength: 2048,
            licence: "Apache-2.0"
        )
    }

    static func spec(for payload: Data, id: String = "test-model") -> LocalModelSpec {
        spec(id: id, bytes: Int64(payload.count), sha256: sha256(payload))
    }

    /// A model file of exactly `spec.bytes` bytes, so it counts as installed.
    static func install(_ spec: LocalModelSpec, in directory: URL) {
        let url = LocalModelFiles.fileURL(for: spec, in: directory)
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data(count: Int(spec.bytes)))
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func localAIWaitUntil(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: HTTP stub

/// HTTP stub for the downloader tests: replies per host (each test registers its own hosts),
/// bodies streamed in chunks, optional redirects. Never touches the network.
final class LocalAIStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var chunkSize = 32 * 1024
        var chunkDelay: TimeInterval = 0
        var redirect: URL?
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// Registers `handler` for `host` (a fresh one by default) and returns `https://host`.
    @discardableResult
    static func register(host: String = "stub-\(UUID().uuidString.lowercased()).test", _ handler: @escaping Handler) -> URL {
        handlers.withLock { $0[host.lowercased()] = handler }
        return URL(string: "https://\(host)")!
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalAIStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let host = request.url?.host()?.lowercased() else { return nil }
        return handlers.withLock { $0[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        handler(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = handler(request)
        if let redirect = reply.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString])!
            var next = request
            next.url = redirect
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        DispatchQueue.global().async { [self] in
            guard let client else { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < reply.body.count {
                if cancelled.withLock({ $0 }) { return }
                if reply.chunkDelay > 0 { Thread.sleep(forTimeInterval: reply.chunkDelay) }
                let end = min(offset + reply.chunkSize, reply.body.count)
                client.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
                offset = end
            }
            if cancelled.withLock({ $0 }) { return }
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        cancelled.withLock { $0 = true }
    }
}

/// Records what the stub server was asked.
final class LocalAIRequestLog: Sendable {
    struct Entry: Sendable {
        let host: String
        let range: String?
    }

    private let entries = OSAllocatedUnfairLock<[Entry]>(initialState: [])

    func append(_ request: URLRequest) {
        let entry = Entry(host: request.url?.host() ?? "", range: request.value(forHTTPHeaderField: "Range"))
        entries.withLock { $0.append(entry) }
    }

    var all: [Entry] { entries.withLock { $0 } }
}

extension LocalAIStubURLProtocol {
    /// A file server for `payload` that honours `Range: bytes=N-` (or ignores it).
    static func fileServer(
        _ payload: Data,
        log: LocalAIRequestLog,
        honorRange: Bool = true,
        chunkSize: Int = 32 * 1024,
        chunkDelay: TimeInterval = 0
    ) -> Handler {
        { request in
            log.append(request)
            if honorRange, let range = request.value(forHTTPHeaderField: "Range"),
               range.hasPrefix("bytes="), range.hasSuffix("-"),
               let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                guard start < payload.count else { return Reply(status: 416) }
                let body = payload.subdata(in: start..<payload.count)
                return Reply(
                    status: 206,
                    headers: ["Content-Range": "bytes \(start)-\(payload.count - 1)/\(payload.count)", "Content-Length": "\(body.count)"],
                    body: body,
                    chunkSize: chunkSize,
                    chunkDelay: chunkDelay
                )
            }
            return Reply(status: 200, headers: ["Content-Length": "\(payload.count)"], body: payload, chunkSize: chunkSize, chunkDelay: chunkDelay)
        }
    }
}
