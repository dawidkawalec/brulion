import Foundation
import os

/// Downloads model files into `<modelsDirectory>/<file>.part` with HTTP Range resume (the
/// `.part` survives cancels and app restarts), checks the size and the SHA-256 (streamed),
/// then renames the file into place in one step. Contacts only the download base
/// (huggingface.co) and redirects to `LocalModelCatalog.downloadHostSuffixes` over HTTPS.
actor LocalModelDownloader {
    /// Free space kept on top of the bytes still to download.
    static let diskMargin: Int64 = 1_000_000_000

    nonisolated let modelsDirectory: URL
    private let session: URLSession
    private let base: URL
    private let freeSpace: @Sendable (URL) -> Int64?
    private var active: Set<String> = []

    init(
        modelsDirectory: URL,
        session: URLSession = LocalModelDownloader.makeSession(),
        base: URL = LocalModelCatalog.downloadBase,
        freeSpace: @escaping @Sendable (URL) -> Int64? = { DiskSpace.availableBytes(at: $0) }
    ) {
        self.modelsDirectory = modelsDirectory
        self.session = session
        self.base = base
        self.freeSpace = freeSpace
    }

    /// Ephemeral (no cookies, no cache on disk), never waits for connectivity, 60 s without a
    /// byte fails the request; a whole model may take hours on a slow line.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: configuration)
    }

    /// Downloads (or resumes) `spec` and returns the verified file. Already installed: returns
    /// at once. Cancel the calling task to pause; the `.part` stays for the next call.
    func download(
        _ spec: LocalModelSpec,
        onEvent: @escaping @Sendable (LocalDownloadEvent) -> Void = { _ in }
    ) async throws -> URL {
        guard !active.contains(spec.id) else { throw LocalModelDownloadError.alreadyDownloading }
        active.insert(spec.id)
        defer { active.remove(spec.id) }

        let fileManager = FileManager.default
        let finalURL = LocalModelFiles.fileURL(for: spec, in: modelsDirectory)
        let partURL = LocalModelFiles.partURL(for: spec, in: modelsDirectory)
        if LocalModelFiles.isInstalled(spec, in: modelsDirectory) { return finalURL }

        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            throw LocalModelDownloadError.file(error.localizedDescription)
        }

        var offset = LocalModelFiles.size(of: partURL) ?? 0
        if offset > spec.bytes {
            try? fileManager.removeItem(at: partURL)
            offset = 0
        }
        if offset < spec.bytes {
            let needed = spec.bytes - offset + Self.diskMargin
            if let available = freeSpace(modelsDirectory), available < needed {
                throw LocalModelDownloadError.notEnoughSpace(needed: needed, available: available)
            }
            LocalAILog.logger.info("Model download \(spec.id, privacy: .public): starting at \(offset) of \(spec.bytes) bytes")
            try await transfer(spec, to: partURL, from: offset, onEvent: onEvent)
        }

        let size = LocalModelFiles.size(of: partURL) ?? 0
        guard size == spec.bytes else {
            if size > spec.bytes {
                try? fileManager.removeItem(at: partURL)
                throw LocalModelDownloadError.sizeMismatch
            }
            throw LocalModelDownloadError.incomplete
        }

        onEvent(.verifying)
        let digest = try await FileSHA256.hex(of: partURL)
        guard digest == spec.sha256.lowercased() else {
            try? fileManager.removeItem(at: partURL)
            LocalAILog.logger.error("Model download \(spec.id, privacy: .public): checksum mismatch, partial file removed")
            throw LocalModelDownloadError.checksumMismatch
        }

        do {
            if fileManager.fileExists(atPath: finalURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: finalURL)
            }
            // Same directory, same volume: a rename, so the final name never holds a partial file.
            try fileManager.moveItem(at: partURL, to: finalURL)
        } catch {
            throw LocalModelDownloadError.file(error.localizedDescription)
        }
        LocalModelFiles.excludeFromBackup(finalURL)
        LocalAILog.logger.info("Model download \(spec.id, privacy: .public): installed")
        return finalURL
    }

    /// Removes the model file and any partial download.
    func delete(_ spec: LocalModelSpec) throws {
        let fileManager = FileManager.default
        for url in [LocalModelFiles.fileURL(for: spec, in: modelsDirectory), LocalModelFiles.partURL(for: spec, in: modelsDirectory)]
        where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: Transfer

    private func transfer(
        _ spec: LocalModelSpec,
        to partURL: URL,
        from offset: Int64,
        onEvent: @escaping @Sendable (LocalDownloadEvent) -> Void
    ) async throws {
        if !FileManager.default.fileExists(atPath: partURL.path(percentEncoded: false)) {
            guard FileManager.default.createFile(atPath: partURL.path(percentEncoded: false), contents: nil) else {
                throw LocalModelDownloadError.file(partURL.lastPathComponent)
            }
            LocalModelFiles.excludeFromBackup(partURL)
        }

        var request = URLRequest(url: spec.downloadURL(base: base))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let rangeHeader = offset > 0 ? "bytes=\(offset)-" : nil
        if let rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }
        let baseHost = base.host()?.lowercased()
        let isAllowedHost: @Sendable (String) -> Bool = { host in
            host.lowercased() == baseHost || LocalModelCatalog.isDownloadHost(host)
        }

        let session = self.session
        let taskBox = LocalDownloadTaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = LocalDownloadTaskDelegate(
                    partURL: partURL,
                    startOffset: offset,
                    totalBytes: spec.bytes,
                    rangeHeader: rangeHeader,
                    isAllowedHost: isAllowedHost,
                    onProgress: { onEvent(.progress($0)) },
                    completion: { continuation.resume(with: $0) }
                )
                let task = session.dataTask(with: request)
                task.delegate = delegate
                taskBox.set(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

/// Lets the cancellation handler reach the URLSession task, even when it fires before the
/// task exists (it is then cancelled as soon as it is set).
private final class LocalDownloadTaskBox: Sendable {
    private struct State {
        var task: URLSessionTask?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func set(_ task: URLSessionTask) {
        let cancelNow = state.withLock { state -> Bool in
            state.task = task
            return state.cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state -> URLSessionTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}
