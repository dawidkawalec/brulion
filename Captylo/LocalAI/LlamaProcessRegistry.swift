import Foundation
import os

/// Every helper process the app started, reachable without awaiting an actor, so the app's
/// quit path (`applicationWillTerminate`, which cannot wait for async work) can still send
/// SIGTERM to all of them.
final class LlamaProcessRegistry: Sendable {
    private let processes = OSAllocatedUnfairLock<[Int32: any LlamaProcessHandle]>(initialState: [:])

    func add(_ process: any LlamaProcessHandle) {
        processes.withLock { $0[process.pid] = process }
    }

    func remove(_ process: any LlamaProcessHandle) {
        processes.withLock { $0[process.pid] = nil }
    }

    var count: Int {
        processes.withLock { $0.count }
    }

    /// SIGTERM to every registered process, right now.
    func terminateAll() {
        let all = processes.withLock { state -> [any LlamaProcessHandle] in
            defer { state.removeAll() }
            return Array(state.values)
        }
        all.forEach { $0.terminate() }
    }
}
