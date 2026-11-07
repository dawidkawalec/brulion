import Foundation
import os

/// One llama-server process for one model file, on 127.0.0.1 with a random port and a random
/// token. Starts on demand (concurrent callers share one start), waits for `/health`, retries
/// a port somebody else grabbed, notices a crash (the next request starts it again), stops
/// itself after `idleTimeout` without use, and backs off after repeated failed starts.
actor LlamaServer {
    enum Status: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int)
        case failed(LlamaServerError)
    }

    /// Seams for tests; the defaults run the real helper.
    struct Dependencies: Sendable {
        var launcher: any LlamaProcessLauncher = SystemLlamaProcessLauncher()
        var health: any LlamaHealthChecking = HTTPLlamaHealthCheck()
        var portPicker: @Sendable () throws -> Int = { try LoopbackPort.free() }
        var registry = LlamaProcessRegistry()
        var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    }

    static let healthPollInterval: Duration = .milliseconds(200)
    static let terminateGrace: Duration = .seconds(3)
    static let portAttempts = 3
    /// This many failed starts or crashes within `failureWindow` make the next start wait.
    static let maxFailures = 3
    static let failureWindow: Duration = .seconds(120)

    nonisolated let configuration: LlamaServerConfiguration
    nonisolated let executable: URL
    nonisolated var modelID: String { configuration.modelID }

    private let runDirectory: URL?
    private let idleTimeout: Duration?
    private let startTimeout: Duration
    private let dependencies: Dependencies
    private let onUnexpectedExit: (@Sendable (String, Int32) -> Void)?
    private let clock = ContinuousClock()

    private(set) var status: Status = .stopped
    private(set) var lastUse: ContinuousClock.Instant
    private var process: (any LlamaProcessHandle)?
    private var currentLaunch: UUID?
    private var startTask: Task<LocalEndpoint, Error>?
    private var generation = 0
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?
    private var recentFailures: [ContinuousClock.Instant] = []

    init(
        configuration: LlamaServerConfiguration,
        executable: URL,
        runDirectory: URL?,
        idleTimeout: Duration? = LocalAITuning.defaultIdleTimeout,
        startTimeout: Duration = LocalAITuning.startTimeout,
        dependencies: Dependencies = Dependencies(),
        onUnexpectedExit: (@Sendable (String, Int32) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.executable = executable
        self.runDirectory = runDirectory
        self.idleTimeout = idleTimeout
        self.startTimeout = startTimeout
        self.dependencies = dependencies
        self.onUnexpectedExit = onUnexpectedExit
        lastUse = ContinuousClock.now
    }

    /// Starting or running.
    var isActive: Bool {
        switch status {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }

    // MARK: Use

    /// The running server's start, or a new one. The returned task finishes with the endpoint
    /// once `/health` answers; cancelling a waiter never cancels the start itself.
    @discardableResult
    func start() -> Task<LocalEndpoint, Error> {
        touch()
        if let startTask { return startTask }
        generation += 1
        let current = generation
        status = .starting
        let task = Task { try await self.launch(generation: current) }
        startTask = task
        return task
    }

    /// Starts when needed and waits for the endpoint (up to the start timeout).
    func endpoint() async throws -> LocalEndpoint {
        try await start().value
    }

    /// Counts as activity for the idle stop.
    func touch() {
        lastUse = clock.now
    }

    /// A request is running: the idle stop waits for `endUse()`.
    func beginUse() {
        inFlight += 1
        touch()
    }

    func endUse() {
        inFlight = max(0, inFlight - 1)
        touch()
    }

    /// Stops the process (SIGTERM, SIGKILL after `terminateGrace`) and forgets the endpoint.
    func stop() async {
        generation += 1
        idleTask?.cancel()
        idleTask = nil
        startTask?.cancel()
        startTask = nil
        if let handle = process {
            discard(handle)
            await Self.terminateAndWait(handle)
            LocalAILog.logger.info("llama-server for \(self.modelID, privacy: .public) stopped")
        }
        status = .stopped
    }

    // MARK: Launch

    private enum HealthOutcome {
        case healthy
        case exited(Int32, LlamaServerError.ExitReason)
        case timedOut
        case superseded
    }

    private func launch(generation current: Int) async throws -> LocalEndpoint {
        let started = clock.now
        do {
            try checkCooldown()
            guard FileManager.default.fileExists(atPath: configuration.modelURL.path(percentEncoded: false)) else {
                throw LlamaServerError.modelMissing
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
                throw LlamaServerError.helperMissing
            }
            if let runDirectory {
                if LlamaPIDFile.killStale(at: LlamaPIDFile.url(modelID: modelID, in: runDirectory)) {
                    LocalAILog.logger.info("Stopped a stale llama-server for \(self.modelID, privacy: .public)")
                }
            }

            var attempt = 0
            while true {
                attempt += 1
                let port: Int
                do {
                    port = try dependencies.portPicker()
                } catch {
                    throw LlamaServerError.launchFailed(String(describing: error))
                }
                let token = LlamaServerConfiguration.makeToken()
                let launchID = UUID()
                let handle: any LlamaProcessHandle
                do {
                    handle = try dependencies.launcher.launch(
                        executable: executable,
                        arguments: configuration.arguments(port: port),
                        environment: LlamaServerConfiguration.environment(token: token, base: dependencies.baseEnvironment),
                        onExit: { [weak self] status in
                            guard let server = self else { return }
                            Task { await server.processExited(launchID: launchID, status: status) }
                        }
                    )
                } catch {
                    throw LlamaServerError.launchFailed(error.localizedDescription)
                }
                currentLaunch = launchID
                process = handle
                dependencies.registry.add(handle)
                if let runDirectory {
                    LlamaPIDFile.write(pid: handle.pid, executable: executable, modelID: modelID, in: runDirectory)
                }

                let base = URL(string: "http://\(LlamaServerConfiguration.host):\(port)")!
                switch await waitForHealth(handle, base: base, token: token, generation: current) {
                case .healthy:
                    status = .running(port: port)
                    recentFailures.removeAll()
                    scheduleIdleCheck(generation: current)
                    let elapsed = clock.now - started
                    LocalAILog.logger.info("llama-server for \(self.modelID, privacy: .public) ready on port \(port) in \(elapsed.components.seconds) s (pid \(handle.pid))")
                    return LocalEndpoint(baseURL: base.appending(path: "v1/"), token: token, modelID: modelID)
                case .superseded:
                    throw CancellationError()
                case .exited(let code, let reason):
                    discard(handle)
                    if reason == .portInUse, attempt < Self.portAttempts {
                        LocalAILog.logger.info("llama-server for \(self.modelID, privacy: .public): port \(port) taken, retrying")
                        continue
                    }
                    throw LlamaServerError.exited(status: code, reason: reason)
                case .timedOut:
                    discard(handle)
                    await Self.terminateAndWait(handle)
                    throw LlamaServerError.startTimedOut
                }
            }
        } catch {
            if generation == current {
                startTask = nil
                if error is CancellationError {
                    status = .stopped
                } else {
                    let failure = error as? LlamaServerError ?? .launchFailed(error.localizedDescription)
                    if failure != .coolingDown { recentFailures.append(clock.now) }
                    status = .failed(failure)
                    LocalAILog.logger.error("llama-server for \(self.modelID, privacy: .public) failed to start: \(String(describing: failure), privacy: .public)")
                }
            }
            throw error
        }
    }

    private func waitForHealth(_ handle: any LlamaProcessHandle, base: URL, token: String, generation current: Int) async -> HealthOutcome {
        let deadline = clock.now + startTimeout
        while clock.now < deadline {
            if generation != current { return .superseded }
            if !handle.isRunning {
                return .exited(handle.exitStatus ?? -1, .classify(handle.recentOutput))
            }
            if await dependencies.health.isHealthy(baseURL: base, token: token) {
                return generation == current ? .healthy : .superseded
            }
            try? await Task.sleep(for: Self.healthPollInterval)
        }
        return generation == current ? .timedOut : .superseded
    }

    private func checkCooldown() throws {
        let now = clock.now
        recentFailures.removeAll { now - $0 > Self.failureWindow }
        if recentFailures.count >= Self.maxFailures {
            throw LlamaServerError.coolingDown
        }
    }

    // MARK: Exit and idle

    private func processExited(launchID: UUID, status code: Int32) {
        guard launchID == currentLaunch, let handle = process else { return }
        // While starting, the health wait reports the exit itself.
        guard case .running = status else { return }
        discard(handle)
        generation += 1
        startTask = nil
        idleTask?.cancel()
        idleTask = nil
        let reason = LlamaServerError.ExitReason.classify(handle.recentOutput)
        status = .failed(.exited(status: code, reason: reason))
        recentFailures.append(clock.now)
        LocalAILog.logger.error("llama-server for \(self.modelID, privacy: .public) exited unexpectedly, status \(code), reason \(reason.rawValue, privacy: .public)")
        onUnexpectedExit?(modelID, code)
    }

    private func scheduleIdleCheck(generation current: Int) {
        idleTask?.cancel()
        guard let idleTimeout else { return }
        let interval = max(min(idleTimeout / 4, .seconds(30)), .milliseconds(20))
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                if await self.stopIfIdle(generation: current) { return }
            }
        }
    }

    /// True when this check is over (stopped now, or the server it watched is gone).
    private func stopIfIdle(generation current: Int) async -> Bool {
        guard generation == current, case .running = status else { return true }
        guard inFlight == 0, let idleTimeout, clock.now - lastUse >= idleTimeout else { return false }
        LocalAILog.logger.info("llama-server for \(self.modelID, privacy: .public) idle, stopping")
        await stop()
        return true
    }

    /// Forgets the process: no exit callback, registry entry or pid file outlives it.
    private func discard(_ handle: any LlamaProcessHandle) {
        dependencies.registry.remove(handle)
        if let runDirectory {
            LlamaPIDFile.remove(modelID: modelID, in: runDirectory)
        }
        if process === handle {
            process = nil
            currentLaunch = nil
        }
    }

    private static func terminateAndWait(_ handle: any LlamaProcessHandle) async {
        handle.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now + terminateGrace
        while handle.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if handle.isRunning {
            handle.kill()
        }
    }
}
