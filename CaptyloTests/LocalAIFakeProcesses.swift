import Foundation
import os
@testable import Captylo

/// Fakes for `LlamaServer` and `LocalAIService`: no llama-server is ever spawned.
final class FakeLlamaProcess: LlamaProcessHandle, @unchecked Sendable {
    private struct State {
        var running = true
        var exitStatus: Int32?
        var terminateCalls = 0
    }

    let pid: Int32
    let arguments: [String]
    let environment: [String: String]
    let output: String
    private let onExit: @Sendable (Int32) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pid: Int32, arguments: [String], environment: [String: String], output: String, onExit: @escaping @Sendable (Int32) -> Void) {
        self.pid = pid
        self.arguments = arguments
        self.environment = environment
        self.output = output
        self.onExit = onExit
    }

    var isRunning: Bool { state.withLock { $0.running } }
    var exitStatus: Int32? { state.withLock { $0.exitStatus } }
    var recentOutput: String { output }
    var terminateCalls: Int { state.withLock { $0.terminateCalls } }

    var port: Int? {
        value(after: "--port").flatMap { Int($0) }
    }

    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func terminate() {
        state.withLock { $0.terminateCalls += 1 }
        finish(status: 15)
    }

    func kill() {
        finish(status: 9)
    }

    /// Ends the process like a crash or a normal exit would.
    func finish(status: Int32) {
        let fire = state.withLock { state -> Bool in
            guard state.running else { return false }
            state.running = false
            state.exitStatus = status
            return true
        }
        if fire { onExit(status) }
    }
}

final class FakeLlamaLauncher: LlamaProcessLauncher, @unchecked Sendable {
    enum Behavior: Sendable {
        case serve
        case exitImmediately(status: Int32, output: String)
    }

    private struct State {
        var behaviors: [Behavior]
        var processes: [FakeLlamaProcess] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// The first launches follow `behaviors`, every later one serves.
    init(behaviors: [Behavior] = []) {
        state = OSAllocatedUnfairLock(initialState: State(behaviors: behaviors))
    }

    var processes: [FakeLlamaProcess] { state.withLock { $0.processes } }
    var launchCount: Int { processes.count }
    var running: [FakeLlamaProcess] { processes.filter(\.isRunning) }

    func process(onPort port: Int) -> FakeLlamaProcess? {
        processes.last { $0.port == port }
    }

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any LlamaProcessHandle {
        let (process, behavior) = state.withLock { state -> (FakeLlamaProcess, Behavior) in
            let behavior: Behavior = state.behaviors.isEmpty ? .serve : state.behaviors.removeFirst()
            var output = ""
            if case .exitImmediately(_, let text) = behavior { output = text }
            // Far above macOS's highest pid, so no pid file check can ever match a real process.
            let process = FakeLlamaProcess(pid: Int32(4_000_000 + state.processes.count), arguments: arguments, environment: environment, output: output, onExit: onExit)
            state.processes.append(process)
            return (process, behavior)
        }
        if case .exitImmediately(let status, _) = behavior {
            process.finish(status: status)
        }
        return process
    }
}

/// Healthy once the fake process on that port runs and was given that token.
struct FakeLlamaHealth: LlamaHealthChecking {
    let launcher: FakeLlamaLauncher
    var delay: Duration = .zero
    var neverHealthy = false

    func isHealthy(baseURL: URL, token: String) async -> Bool {
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !neverHealthy, let port = baseURL.port, let process = launcher.process(onPort: port) else { return false }
        return process.isRunning && process.environment[LlamaServerConfiguration.apiKeyVariable] == token
    }
}

/// Ports 50001, 50002, ... (the fakes never bind them).
final class FakePortPicker: Sendable {
    private let next = OSAllocatedUnfairLock(initialState: 50_000)

    func pick() -> Int {
        next.withLock { $0 += 1; return $0 }
    }
}

extension LlamaServer.Dependencies {
    static func fake(_ launcher: FakeLlamaLauncher, health: FakeLlamaHealth? = nil, registry: LlamaProcessRegistry = LlamaProcessRegistry()) -> Self {
        let ports = FakePortPicker()
        return LlamaServer.Dependencies(
            launcher: launcher,
            health: health ?? FakeLlamaHealth(launcher: launcher),
            portPicker: { ports.pick() },
            registry: registry,
            baseEnvironment: ["HOME": "/Users/test", "LLAMA_ARG_TOOLS": "all"]
        )
    }
}

/// Any executable file works: the fake launcher never runs it.
let localAIFakeExecutable = URL(fileURLWithPath: "/usr/bin/true")
