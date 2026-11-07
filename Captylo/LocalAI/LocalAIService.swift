import Foundation
import os

/// The local AI behind the app's AI route: role -> model -> llama-server process. Two roles
/// on one model share one process (started with the larger context). A memory budget keeps
/// the running servers within reach of the Mac's RAM: before a new server starts, the least
/// recently used others stop until it fits (on 8 GB that means one at a time).
///
/// Call `endpoint(for:timeout:)` (or `withEndpoint`) for every request: it is also the
/// activity signal for the idle stop. Paths and settings come in from the integration.
actor LocalAIService {
    struct Options: Equatable, Sendable {
        /// Stop a server after this long without requests (nil = never).
        var idleTimeout: Duration?
        var startTimeout: Duration
        /// Bytes all servers may take together (`HardwareProfile.memoryBudgetBytes`), nil = no limit.
        var memoryBudgetBytes: Int64?

        init(
            idleTimeout: Duration? = LocalAITuning.defaultIdleTimeout,
            startTimeout: Duration = LocalAITuning.startTimeout,
            memoryBudgetBytes: Int64? = nil
        ) {
            self.idleTimeout = idleTimeout
            self.startTimeout = startTimeout
            self.memoryBudgetBytes = memoryBudgetBytes
        }
    }

    enum RoleStatus: Equatable, Sendable {
        /// No local model for this role (it may run in the cloud).
        case unassigned
        case helperMissing
        case notInstalled
        case stopped
        case starting
        case running
        /// Polish message.
        case failed(String)
    }

    private struct Entry {
        let spec: LocalModelSpec
        let server: LlamaServer
    }

    /// Every process this service started, for `terminateAllNow()`.
    nonisolated let registry: LlamaProcessRegistry

    private let modelsDirectory: URL
    private let runDirectory: URL
    private let executable: URL?
    private let dependencies: LlamaServer.Dependencies
    private let onUnexpectedExit: (@Sendable (String, Int32) -> Void)?
    private var options: Options
    private var roleModels: [LocalRole: LocalModelSpec]
    private var servers: [String: Entry] = [:]
    private var admitting = false
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - roleModels: which model each local role uses (`LocalAIPlan.roleModels`).
    ///   - modelsDirectory: where `LocalAIModelStore` keeps the GGUF files.
    ///   - runDirectory: where the pid files live (in the app's data folder); stale servers
    ///     recorded there by a crashed run are stopped right here.
    ///   - executable: the helper (`LlamaServerLocator.locate()`); nil = no local AI.
    init(
        roleModels: [LocalRole: LocalModelSpec],
        modelsDirectory: URL,
        runDirectory: URL,
        executable: URL? = LlamaServerLocator.locate(),
        options: Options = Options(),
        dependencies: LlamaServer.Dependencies = LlamaServer.Dependencies(),
        onUnexpectedExit: (@Sendable (String, Int32) -> Void)? = nil
    ) {
        self.roleModels = roleModels
        self.modelsDirectory = modelsDirectory
        self.runDirectory = runDirectory
        self.executable = executable
        self.options = options
        self.dependencies = dependencies
        self.onUnexpectedExit = onUnexpectedExit
        registry = dependencies.registry
        let stale = LlamaPIDFile.sweep(runDirectory)
        if stale > 0 {
            LocalAILog.logger.info("Stopped \(stale) stale llama-server process(es) from an earlier run")
        }
    }

    // MARK: Settings

    /// New role -> model mapping; servers no longer needed (or needing another context) stop.
    func setRoleModels(_ models: [LocalRole: LocalModelSpec]) async {
        roleModels = models
        for (id, entry) in servers {
            let stillUsed = roleModels.values.contains { $0.id == id }
            if !stillUsed || configuration(for: entry.spec) != entry.server.configuration {
                servers[id] = nil
                await entry.server.stop()
            }
        }
    }

    /// New options (idle time, budget); running servers stop and start again on next use.
    func setOptions(_ options: Options) async {
        guard options != self.options else { return }
        self.options = options
        await stopAll()
    }

    // MARK: Use

    /// The endpoint for `role`, starting its server when needed. nil when the role has no
    /// local model, the model is not installed, the helper is missing, the server failed,
    /// or it was not ready within `timeout` (the start goes on in the background).
    func endpoint(for role: LocalRole, timeout: Duration) async -> LocalEndpoint? {
        guard let entry = await availableEntry(for: role) else { return nil }
        let work = Task { try await self.admit(entry).value }
        return await LocalAITimeout.value(of: work, within: timeout)
    }

    /// Runs `body` with the role's endpoint; the server is never stopped for idleness while
    /// `body` runs. nil when no endpoint was available within `timeout`.
    func withEndpoint<T: Sendable>(
        for role: LocalRole,
        timeout: Duration,
        _ body: @Sendable (LocalEndpoint) async throws -> T
    ) async throws -> T? {
        guard let entry = await availableEntry(for: role) else { return nil }
        let work = Task { try await self.admit(entry).value }
        guard let endpoint = await LocalAITimeout.value(of: work, within: timeout) else { return nil }
        await entry.server.beginUse()
        do {
            let result = try await body(endpoint)
            await entry.server.endUse()
            return result
        } catch {
            await entry.server.endUse()
            throw error
        }
    }

    /// Starts the role's server without waiting for it (the dictation hotkey went down).
    func prewarm(_ role: LocalRole) async {
        guard let entry = await availableEntry(for: role) else { return }
        _ = await admit(entry)
    }

    func status(for role: LocalRole) async -> RoleStatus {
        guard let spec = roleModels[role] else { return .unassigned }
        guard executable != nil else { return .helperMissing }
        guard LocalModelFiles.isInstalled(spec, in: modelsDirectory) else { return .notInstalled }
        guard let entry = servers[spec.id] else { return .stopped }
        switch await entry.server.status {
        case .stopped: return .stopped
        case .starting: return .starting
        case .running: return .running
        case .failed(let error): return .failed(error.errorDescription ?? String(describing: error))
        }
    }

    /// Ids of the models whose server is starting or running.
    func activeModelIDs() async -> Set<String> {
        var active = Set<String>()
        for (id, entry) in servers {
            if await entry.server.isActive { active.insert(id) }
        }
        return active
    }

    /// Stops one model's server (before its file is deleted).
    func stop(modelID: String) async {
        guard let entry = servers.removeValue(forKey: modelID) else { return }
        await entry.server.stop()
    }

    /// Stops every server and waits for them (app quit with time to spare, settings changes).
    func shutdown() async {
        await stopAll()
    }

    /// SIGTERM to every server right now, without awaiting the actor (`applicationWillTerminate`).
    nonisolated func terminateAllNow() {
        registry.terminateAll()
    }

    // MARK: Servers

    private func availableEntry(for role: LocalRole) async -> Entry? {
        guard let spec = roleModels[role], let executable else { return nil }
        guard LocalModelFiles.isInstalled(spec, in: modelsDirectory) else { return nil }
        let wanted = configuration(for: spec)
        if let entry = servers[spec.id], entry.server.configuration == wanted {
            return entry
        }
        if let outdated = servers.removeValue(forKey: spec.id) {
            await outdated.server.stop()
            // Another caller may have created the replacement while this one waited.
            if let entry = servers[spec.id], entry.server.configuration == wanted {
                return entry
            }
        }
        let server = LlamaServer(
            configuration: wanted,
            executable: executable,
            runDirectory: runDirectory,
            idleTimeout: options.idleTimeout,
            startTimeout: options.startTimeout,
            dependencies: dependencies,
            onUnexpectedExit: onUnexpectedExit
        )
        let entry = Entry(spec: spec, server: server)
        servers[spec.id] = entry
        return entry
    }

    /// The model's process configuration: the largest context of the roles it serves.
    private func configuration(for spec: LocalModelSpec) -> LlamaServerConfiguration {
        let contexts = roleModels.filter { $0.value.id == spec.id }.map { LocalAITuning.contextLength(for: $0.key) }
        var configuration = LlamaServerConfiguration(
            modelID: spec.id,
            modelURL: LocalModelFiles.fileURL(for: spec, in: modelsDirectory),
            contextLength: contexts.max() ?? spec.contextLength
        )
        if let idle = options.idleTimeout {
            configuration.serverSleepSeconds = Int(idle.components.seconds) + 120
        }
        return configuration
    }

    /// Makes room within the memory budget, then starts (or joins) the server. One admission
    /// at a time, so two starts never both fit into the same free memory.
    private func admit(_ entry: Entry) async -> Task<LocalEndpoint, Error> {
        await acquireAdmission()
        defer { releaseAdmission() }
        if !(await entry.server.isActive) {
            await makeRoom(for: entry)
        }
        return await entry.server.start()
    }

    private func makeRoom(for entry: Entry) async {
        guard let budget = options.memoryBudgetBytes else { return }
        var others: [(entry: Entry, lastUse: ContinuousClock.Instant)] = []
        var used: Int64 = 0
        for (id, other) in servers where id != entry.spec.id {
            guard await other.server.isActive else { continue }
            used += other.spec.approximateRAMBytes
            others.append((other, await other.server.lastUse))
        }
        var needed = used + entry.spec.approximateRAMBytes
        for other in others.sorted(by: { $0.lastUse < $1.lastUse }) where needed > budget {
            LocalAILog.logger.info("Memory budget: stopping \(other.entry.spec.id, privacy: .public) for \(entry.spec.id, privacy: .public)")
            await other.entry.server.stop()
            needed -= other.entry.spec.approximateRAMBytes
        }
    }

    private func stopAll() async {
        let all = servers.values.map(\.server)
        servers.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for server in all {
                group.addTask { await server.stop() }
            }
        }
    }

    private func acquireAdmission() async {
        guard admitting else {
            admitting = true
            return
        }
        await withCheckedContinuation { admissionWaiters.append($0) }
    }

    private func releaseAdmission() {
        if admissionWaiters.isEmpty {
            admitting = false
        } else {
            admissionWaiters.removeFirst().resume()
        }
    }
}
