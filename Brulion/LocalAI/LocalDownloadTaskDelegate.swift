import Foundation
import os

/// Streams one model download into its `.part` file as the bytes arrive (never the whole file
/// in memory). Runs on URLSession's delegate queue; the state sits behind a lock because the
/// owner reads nothing else. `completion` is called exactly once, from `didCompleteWithError`.
final class LocalDownloadTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let reportInterval: Duration = .milliseconds(250)
    static let speedWindow: Duration = .seconds(1)

    private struct State {
        var handle: FileHandle?
        var received: Int64
        var failure: LocalModelDownloadError?
        var lastReport: ContinuousClock.Instant?
        var windowStart: ContinuousClock.Instant?
        var windowBytes: Int64 = 0
        var bytesPerSecond: Double = 0
    }

    private let partURL: URL
    private let startOffset: Int64
    private let totalBytes: Int64
    private let rangeHeader: String?
    private let isAllowedHost: @Sendable (String) -> Bool
    private let onProgress: @Sendable (LocalDownloadProgress) -> Void
    private let completion: @Sendable (Result<Void, Error>) -> Void
    private let state: OSAllocatedUnfairLock<State>
    private let clock = ContinuousClock()

    init(
        partURL: URL,
        startOffset: Int64,
        totalBytes: Int64,
        rangeHeader: String?,
        isAllowedHost: @escaping @Sendable (String) -> Bool,
        onProgress: @escaping @Sendable (LocalDownloadProgress) -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.partURL = partURL
        self.startOffset = startOffset
        self.totalBytes = totalBytes
        self.rangeHeader = rangeHeader
        self.isAllowedHost = isAllowedHost
        self.onProgress = onProgress
        self.completion = completion
        state = OSAllocatedUnfairLock(initialState: State(received: startOffset))
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.scheme?.lowercased() == "https", let host = url.host(), isAllowedHost(host) else {
            fail(.unexpectedHost)
            completionHandler(nil)
            task.cancel()
            return
        }
        var redirected = request
        if let rangeHeader {
            redirected.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(.badResponse)
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206 where startOffset > 0:
                // Resume: the server must continue exactly where the .part ends.
                guard Self.contentRangeStart(http.value(forHTTPHeaderField: "Content-Range")) == startOffset else {
                    fail(.badResponse)
                    completionHandler(.cancel)
                    return
                }
                try openPart(truncatingTo: startOffset)
            case 200:
                // A full body (no range asked, or the server ignored it): start the file over.
                try openPart(truncatingTo: 0)
            default:
                fail(.httpStatus(http.statusCode))
                completionHandler(.cancel)
                return
            }
        } catch {
            fail(.file(error.localizedDescription))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = clock.now
        let report: LocalDownloadProgress? = state.withLock { state in
            guard state.failure == nil, let handle = state.handle else { return nil }
            guard state.received + Int64(data.count) <= totalBytes else {
                state.failure = .sizeMismatch
                return nil
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                state.failure = .file(error.localizedDescription)
                return nil
            }
            state.received += Int64(data.count)
            updateSpeed(&state, bytes: Int64(data.count), now: now)
            if let last = state.lastReport, now - last < Self.reportInterval, state.received < totalBytes {
                return nil
            }
            state.lastReport = now
            return LocalDownloadProgress(receivedBytes: state.received, totalBytes: totalBytes, bytesPerSecond: state.bytesPerSecond)
        }
        if let report {
            onProgress(report)
        }
        if state.withLock({ $0.failure != nil }) {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let failure = state.withLock { state -> LocalModelDownloadError? in
            try? state.handle?.close()
            state.handle = nil
            return state.failure
        }
        if let failure {
            completion(.failure(failure))
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                completion(.failure(CancellationError()))
            } else {
                completion(.failure(LocalModelDownloadError.network(error.localizedDescription)))
            }
        } else {
            completion(.success(()))
        }
    }

    // MARK: Helpers

    /// The first failure wins; later ones (the cancel it causes) are ignored.
    private func fail(_ failure: LocalModelDownloadError) {
        state.withLock { state in
            if state.failure == nil { state.failure = failure }
        }
    }

    private func openPart(truncatingTo offset: Int64) throws {
        let handle = try FileHandle(forWritingTo: partURL)
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()
        state.withLock { state in
            try? state.handle?.close()
            state.handle = handle
            state.received = offset
        }
    }

    private func updateSpeed(_ state: inout State, bytes: Int64, now: ContinuousClock.Instant) {
        guard let start = state.windowStart else {
            state.windowStart = now
            state.windowBytes = bytes
            return
        }
        state.windowBytes += bytes
        let elapsed = now - start
        guard elapsed >= Self.speedWindow else { return }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = Double(state.windowBytes) / seconds
        state.bytesPerSecond = state.bytesPerSecond == 0 ? rate : state.bytesPerSecond * 0.6 + rate * 0.4
        state.windowStart = now
        state.windowBytes = 0
    }

    /// First byte of `Content-Range: bytes 100-999/1000`, nil when missing or malformed.
    static func contentRangeStart(_ header: String?) -> Int64? {
        guard let header, header.lowercased().hasPrefix("bytes ") else { return nil }
        let range = header.dropFirst("bytes ".count)
        guard let dash = range.firstIndex(of: "-") else { return nil }
        return Int64(range[range.startIndex..<dash].trimmingCharacters(in: .whitespaces))
    }
}
