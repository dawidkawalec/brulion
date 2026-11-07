import Darwin
import Foundation
import os

/// A running helper process. The real one wraps `Process`; tests use fakes.
protocol LlamaProcessHandle: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// Exit status (or signal) once the process ended, nil while it runs.
    var exitStatus: Int32? { get }
    /// The last few KB the process printed. Kept in memory only to classify a failure;
    /// never logged (it could echo a prompt in a warning).
    var recentOutput: String { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
}

/// Starts helper processes; injected so tests never spawn llama-server.
protocol LlamaProcessLauncher: Sendable {
    /// `onExit` gets the exit status (or the signal) once, from any thread.
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any LlamaProcessHandle
}

struct SystemLlamaProcessLauncher: LlamaProcessLauncher {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any LlamaProcessHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        let handle = SystemLlamaProcess(process: process)
        process.terminationHandler = { finished in
            handle.stopReading()
            onExit(finished.terminationStatus)
        }
        try process.run()
        return handle
    }
}

/// `Process` with its output drained into a small in-memory tail (an undrained pipe would
/// block the server once it fills).
final class SystemLlamaProcess: LlamaProcessHandle, @unchecked Sendable {
    static let tailBytes = 16 * 1024

    private let process: Process
    private let pipe = Pipe()
    private let tail = OSAllocatedUnfairLock(initialState: Data())

    init(process: Process) {
        self.process = process
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [tail] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            tail.withLock { buffer in
                buffer.append(data)
                if buffer.count > SystemLlamaProcess.tailBytes {
                    buffer.removeFirst(buffer.count - SystemLlamaProcess.tailBytes)
                }
            }
        }
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var exitStatus: Int32? { process.isRunning ? nil : process.terminationStatus }
    var recentOutput: String { String(decoding: tail.withLock { $0 }, as: UTF8.self) }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func stopReading() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }
}
