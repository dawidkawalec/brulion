import Foundation
import Observation

/// Download state of every Bielik model for Modele and the onboarding: start, cancel (the
/// partial file stays, the next download resumes it), delete, and what is installed.
/// Named apart from the Whisper `LocalModelStore`.
@MainActor
@Observable
final class LocalAIModelStore {
    enum State: Equatable, Sendable {
        case notInstalled
        case downloading(LocalDownloadProgress)
        /// All bytes are in, the SHA-256 check runs.
        case verifying
        case installed
        /// Polish message for the row (a `LocalizedError` description).
        case failed(String)
    }

    let models: [LocalModelSpec]
    let modelsDirectory: URL
    private(set) var states: [String: State] = [:]
    /// Bytes of unfinished downloads on disk, per model id (shown as "Wznów").
    private(set) var partialBytes: [String: Int64] = [:]

    /// Runs after a model was verified and moved into place.
    @ObservationIgnored var onInstalled: (@MainActor (LocalModelSpec) -> Void)?
    /// Runs before a model file is deleted, so the integration can stop its server first.
    @ObservationIgnored var willDelete: (@MainActor (LocalModelSpec) async -> Void)?

    @ObservationIgnored private let downloader: LocalModelDownloader
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeGeneration: [String: Int] = [:]
    @ObservationIgnored private var lastGeneration = 0
    /// Fixed states for a design preview: nothing is read, downloaded or deleted.
    @ObservationIgnored private let pinnedStates: [String: State]?

    /// - Parameter pinnedStates: states shown regardless of the files (a design preview); the
    ///   store then never downloads, deletes or reads the disk.
    init(
        modelsDirectory: URL,
        models: [LocalModelSpec] = LocalModelCatalog.all,
        downloader: LocalModelDownloader? = nil,
        pinnedStates: [String: State]? = nil
    ) {
        self.modelsDirectory = modelsDirectory
        self.models = models
        self.downloader = downloader ?? LocalModelDownloader(modelsDirectory: modelsDirectory)
        self.pinnedStates = pinnedStates
        refresh()
    }

    /// True while the states are pinned (a design preview).
    var isPinned: Bool { pinnedStates != nil }

    func model(id: String) -> LocalModelSpec? {
        models.first { $0.id == id }
    }

    func state(for id: String) -> State {
        states[id] ?? .notInstalled
    }

    func isInstalled(_ id: String) -> Bool {
        state(for: id) == .installed
    }

    var installedModels: [LocalModelSpec] {
        models.filter { isInstalled($0.id) }
    }

    /// Free space a download of `id` still needs (remaining bytes plus the margin).
    func spaceNeeded(for id: String) -> Int64 {
        guard let spec = model(id: id) else { return 0 }
        return max(0, spec.bytes - (partialBytes[id] ?? 0)) + LocalModelDownloader.diskMargin
    }

    /// Re-reads the files on disk; running downloads keep their state.
    func refresh() {
        if let pinnedStates {
            states = pinnedStates
            return
        }
        for spec in models where tasks[spec.id] == nil {
            partialBytes[spec.id] = LocalModelFiles.partialBytes(of: spec, in: modelsDirectory)
            states[spec.id] = LocalModelFiles.isInstalled(spec, in: modelsDirectory) ? .installed : .notInstalled
        }
    }

    /// Starts or resumes a download; does nothing while one runs or when installed.
    func download(_ id: String) {
        guard pinnedStates == nil else { return }
        guard let spec = model(id: id), tasks[id] == nil, !LocalModelFiles.isInstalled(spec, in: modelsDirectory) else { return }
        lastGeneration += 1
        let generation = lastGeneration
        activeGeneration[id] = generation
        let resumed = LocalModelFiles.partialBytes(of: spec, in: modelsDirectory)
        states[id] = .downloading(LocalDownloadProgress(receivedBytes: resumed, totalBytes: spec.bytes, bytesPerSecond: 0))
        let downloader = self.downloader
        let onEvent: @Sendable (LocalDownloadEvent) -> Void = { [weak self] event in
            guard let store = self else { return }
            Task { @MainActor in
                store.apply(event, to: id, generation: generation)
            }
        }
        tasks[id] = Task { [weak self] in
            let outcome: State
            do {
                _ = try await downloader.download(spec, onEvent: onEvent)
                outcome = .installed
            } catch is CancellationError {
                outcome = .notInstalled
            } catch {
                outcome = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finish(spec, generation: generation, state: outcome)
        }
    }

    /// Stops a running download; the partial file stays for resuming.
    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Cancels a running download, lets `willDelete` stop the model's server, then removes
    /// the file and any partial download.
    func delete(_ id: String) async throws {
        guard let spec = model(id: id) else { throw LocalModelDownloadError.unknownModel }
        guard pinnedStates == nil else { return }
        if let task = tasks[id] {
            task.cancel()
            await task.value
        }
        await willDelete?(spec)
        try await downloader.delete(spec)
        refresh()
    }

    private func apply(_ event: LocalDownloadEvent, to id: String, generation: Int) {
        guard activeGeneration[id] == generation else { return }
        switch event {
        case .progress(let progress):
            if case .verifying = states[id] { return }
            states[id] = .downloading(progress)
        case .verifying:
            states[id] = .verifying
        }
    }

    private func finish(_ spec: LocalModelSpec, generation: Int, state: State) {
        guard activeGeneration[spec.id] == generation else { return }
        activeGeneration[spec.id] = nil
        tasks[spec.id] = nil
        partialBytes[spec.id] = LocalModelFiles.partialBytes(of: spec, in: modelsDirectory)
        states[spec.id] = state
        if state == .installed {
            onInstalled?(spec)
        }
    }
}
