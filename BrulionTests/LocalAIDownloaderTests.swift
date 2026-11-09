import Foundation
import os
import Testing
@testable import Brulion

struct LocalAIDownloaderTests {
    private let payload = LocalAIFixtures.payload(300_000)

    private func downloader(base: URL, in directory: URL, freeSpace: Int64? = nil) -> LocalModelDownloader {
        LocalModelDownloader(
            modelsDirectory: directory,
            session: LocalAIStubURLProtocol.makeSession(),
            base: base,
            freeSpace: { _ in freeSpace ?? 100_000_000_000 }
        )
    }

    private func writePart(_ data: Data, for spec: LocalModelSpec, in directory: URL) throws {
        try data.write(to: LocalModelFiles.partURL(for: spec, in: directory))
    }

    @Test func downloadsVerifiesAndMovesIntoPlace() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let log = LocalAIRequestLog()
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: log))
        let spec = LocalAIFixtures.spec(for: payload)
        let events = OSAllocatedUnfairLock<[LocalDownloadEvent]>(initialState: [])

        let url = try await downloader(base: base, in: folder.url).download(spec) { event in
            events.withLock { $0.append(event) }
        }

        #expect(url == LocalModelFiles.fileURL(for: spec, in: folder.url))
        #expect(try Data(contentsOf: url) == payload)
        #expect(!FileManager.default.fileExists(atPath: LocalModelFiles.partURL(for: spec, in: folder.url).path(percentEncoded: false)))
        #expect(LocalModelFiles.isInstalled(spec, in: folder.url))
        #expect(log.all.count == 1)
        #expect(log.all.first?.range == nil)
        let recorded = events.withLock { $0 }
        #expect(recorded.last == .verifying)
        let progress = recorded.compactMap { event -> LocalDownloadProgress? in
            if case .progress(let value) = event { return value }
            return nil
        }
        #expect(progress.last?.receivedBytes == Int64(payload.count))
        #expect(progress.last?.fraction == 1)
    }

    @Test func resumesAPartialFileWithRange() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let log = LocalAIRequestLog()
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: log))
        let spec = LocalAIFixtures.spec(for: payload)
        try writePart(payload.prefix(100_000), for: spec, in: folder.url)

        let url = try await downloader(base: base, in: folder.url).download(spec)

        #expect(log.all.map(\.range) == ["bytes=100000-"])
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test func startsOverWhenTheServerIgnoresRange() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let log = LocalAIRequestLog()
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: log, honorRange: false))
        let spec = LocalAIFixtures.spec(for: payload)
        try writePart(Data(repeating: 0xFF, count: 50_000), for: spec, in: folder.url)

        let url = try await downloader(base: base, in: folder.url).download(spec)

        #expect(log.all.map(\.range) == ["bytes=50000-"])
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test func checksumMismatchRemovesThePartialFile() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: LocalAIRequestLog()))
        let spec = LocalAIFixtures.spec(id: "bad-sum", bytes: Int64(payload.count), sha256: String(repeating: "a", count: 64))

        await #expect(throws: LocalModelDownloadError.checksumMismatch) {
            try await downloader(base: base, in: folder.url).download(spec)
        }
        #expect(LocalModelFiles.partialBytes(of: spec, in: folder.url) == 0)
        #expect(!LocalModelFiles.isInstalled(spec, in: folder.url))
    }

    @Test func cancelKeepsThePartialFileForResuming() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let slowLog = LocalAIRequestLog()
        let slow = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: slowLog, chunkSize: 10_000, chunkDelay: 0.03))
        let spec = LocalAIFixtures.spec(for: payload)
        let slowDownloader = downloader(base: slow, in: folder.url)

        let task = Task { try await slowDownloader.download(spec) }
        let started = await localAIWaitUntil { LocalModelFiles.partialBytes(of: spec, in: folder.url) >= 20_000 }
        #expect(started)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let kept = LocalModelFiles.partialBytes(of: spec, in: folder.url)
        #expect(kept > 0 && kept < Int64(payload.count))
        #expect(!LocalModelFiles.isInstalled(spec, in: folder.url))

        let fastLog = LocalAIRequestLog()
        let fast = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: fastLog))
        let url = try await downloader(base: fast, in: folder.url).download(spec)
        #expect(fastLog.all.first?.range?.hasPrefix("bytes=") == true)
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test func refusesToStartWithoutDiskSpace() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let log = LocalAIRequestLog()
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: log))
        let spec = LocalAIFixtures.spec(for: payload)

        await #expect(throws: LocalModelDownloadError.notEnoughSpace(needed: Int64(payload.count) + LocalModelDownloader.diskMargin, available: 500_000_000)) {
            try await downloader(base: base, in: folder.url, freeSpace: 500_000_000).download(spec)
        }
        #expect(log.all.isEmpty)
    }

    @Test func followsARedirectToTheCDNWithTheRange() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let cdnLog = LocalAIRequestLog()
        let cdn = LocalAIStubURLProtocol.register(host: "cdn-\(UUID().uuidString.lowercased()).hf.co", LocalAIStubURLProtocol.fileServer(payload, log: cdnLog))
        let spec = LocalAIFixtures.spec(for: payload)
        let base = LocalAIStubURLProtocol.register { request in
            LocalAIStubURLProtocol.Reply(redirect: cdn.appending(path: request.url?.path() ?? "/"))
        }
        try writePart(payload.prefix(1000), for: spec, in: folder.url)

        let url = try await downloader(base: base, in: folder.url).download(spec)

        #expect(cdnLog.all.map(\.range) == ["bytes=1000-"])
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test func refusesARedirectOutsideHuggingFace() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let foreignLog = LocalAIRequestLog()
        let foreign = LocalAIStubURLProtocol.register(host: "mirror-\(UUID().uuidString.lowercased()).example", LocalAIStubURLProtocol.fileServer(payload, log: foreignLog))
        let base = LocalAIStubURLProtocol.register { _ in LocalAIStubURLProtocol.Reply(redirect: foreign) }
        let spec = LocalAIFixtures.spec(for: payload)

        await #expect(throws: LocalModelDownloadError.unexpectedHost) {
            try await downloader(base: base, in: folder.url).download(spec)
        }
        #expect(foreignLog.all.isEmpty)
    }

    @Test func httpErrorsFail() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let base = LocalAIStubURLProtocol.register { _ in LocalAIStubURLProtocol.Reply(status: 404) }
        let spec = LocalAIFixtures.spec(for: payload)

        await #expect(throws: LocalModelDownloadError.httpStatus(404)) {
            try await downloader(base: base, in: folder.url).download(spec)
        }
    }

    @Test func installedModelNeedsNoRequest() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let log = LocalAIRequestLog()
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: log))
        let spec = LocalAIFixtures.spec(for: payload)
        LocalAIFixtures.install(spec, in: folder.url)

        _ = try await downloader(base: base, in: folder.url).download(spec)
        #expect(log.all.isEmpty)
    }

    @Test func streamedHashMatchesCryptoKit() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let data = LocalAIFixtures.payload(FileSHA256.chunkSize + 12_345)
        let url = folder.url.appending(path: "blob")
        try data.write(to: url)
        #expect(try await FileSHA256.hex(of: url) == LocalAIFixtures.sha256(data))
    }

    @Test func parsesContentRange() {
        #expect(LocalDownloadTaskDelegate.contentRangeStart("bytes 100-999/1000") == 100)
        #expect(LocalDownloadTaskDelegate.contentRangeStart("bytes 0-9/10") == 0)
        #expect(LocalDownloadTaskDelegate.contentRangeStart("items 1-2/3") == nil)
        #expect(LocalDownloadTaskDelegate.contentRangeStart(nil) == nil)
    }
}

@MainActor
struct LocalAIModelStoreTests {
    private let payload = LocalAIFixtures.payload(120_000)

    private func store(base: URL, folder: URL, models: [LocalModelSpec]) -> LocalAIModelStore {
        let downloader = LocalModelDownloader(
            modelsDirectory: folder,
            session: LocalAIStubURLProtocol.makeSession(),
            base: base,
            freeSpace: { _ in 100_000_000_000 }
        )
        return LocalAIModelStore(modelsDirectory: folder, models: models, downloader: downloader)
    }

    @Test func downloadEndsInstalled() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: LocalAIRequestLog()))
        let spec = LocalAIFixtures.spec(for: payload)
        let store = store(base: base, folder: folder.url, models: [spec])
        var installed: [String] = []
        store.onInstalled = { installed.append($0.id) }

        #expect(store.state(for: spec.id) == .notInstalled)
        store.download(spec.id)
        if case .downloading = store.state(for: spec.id) {} else { Issue.record("expected downloading right away") }
        #expect(await localAIWaitUntil { store.state(for: spec.id) == .installed })
        #expect(installed == [spec.id])
        #expect(store.installedModels == [spec])
    }

    @Test func checksumFailureShowsAMessage() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let base = LocalAIStubURLProtocol.register(LocalAIStubURLProtocol.fileServer(payload, log: LocalAIRequestLog()))
        let spec = LocalAIFixtures.spec(id: "broken", bytes: Int64(payload.count), sha256: String(repeating: "b", count: 64))
        let store = store(base: base, folder: folder.url, models: [spec])

        store.download(spec.id)
        let failed = await localAIWaitUntil {
            if case .failed = store.state(for: spec.id) { return true }
            return false
        }
        #expect(failed)
        if case .failed(let message) = store.state(for: spec.id) {
            #expect(!message.isEmpty)
        }
    }

    @Test func refreshReadsTheDiskAndDeleteRemovesTheFiles() async throws {
        let folder = LocalAITempDirectory()
        defer { folder.remove() }
        let installed = LocalAIFixtures.spec(id: "on-disk", bytes: 64)
        let partial = LocalAIFixtures.spec(id: "half", bytes: 64)
        LocalAIFixtures.install(installed, in: folder.url)
        try Data(count: 10).write(to: LocalModelFiles.partURL(for: partial, in: folder.url))
        let store = store(base: URL(string: "https://unused.test")!, folder: folder.url, models: [installed, partial])

        #expect(store.state(for: installed.id) == .installed)
        #expect(store.state(for: partial.id) == .notInstalled)
        #expect(store.partialBytes[partial.id] == 10)
        #expect(store.spaceNeeded(for: partial.id) == 54 + LocalModelDownloader.diskMargin)

        var stopped: [String] = []
        store.willDelete = { stopped.append($0.id) }
        try await store.delete(installed.id)
        try await store.delete(partial.id)
        #expect(stopped == [installed.id, partial.id])
        #expect(store.state(for: installed.id) == .notInstalled)
        #expect(store.partialBytes[partial.id] == 0)
        #expect(!LocalModelFiles.isInstalled(installed, in: folder.url))
    }
}
