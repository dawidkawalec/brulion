import Foundation
import os

/// Waits for a task's value for at most `timeout`, without cancelling the task: a dictation
/// that gives up on a loading model pastes the raw text, while the model keeps loading for
/// the next one. Also returns nil at once when the waiting task is cancelled.
enum LocalAITimeout {
    /// `@concurrent` on purpose: see "Queue bridges" in docs/coding-standards.md.
    @concurrent static func value<T: Sendable>(of task: Task<T, Error>, within timeout: Duration) async -> T? {
        let gate = ResumeGate<T?>()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            gate.resume(nil)
        }
        let waiter = Task {
            gate.resume(try? await task.value)
        }
        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.resume(nil)
        }
        timer.cancel()
        _ = waiter
        return result
    }
}

/// A one-shot value: the first `resume` wins, `wait` returns it (also when it came first).
private final class ResumeGate<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
        var value: Value?
        var resolved = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Value? in
                if state.resolved { return state.value }
                state.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func resume(_ value: Value) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard !state.resolved else { return nil }
            state.resolved = true
            state.value = value
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: value)
    }
}
