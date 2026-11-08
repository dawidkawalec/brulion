#!/bin/bash
# Checks the Swift bug behind the "Queue bridges" rule in docs/coding-standards.md: a generic
# nonisolated(nonsending) helper that awaits a checked continuation returns its @MainActor caller
# on a cooperative thread in an -O build for the project's macOS target. Compiles one minimal
# program shaped like the dictation start (hotkey task -> coordinator -> capture -> onQueue)
# twice, with a plain and with a @concurrent helper, and prints where the caller resumed.
#
#   scripts/check-nonsending-resume.sh            # target from project.yml
#   scripts/check-nonsending-resume.sh 15.0       # another deployment target
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-$(awk '/deploymentTarget:/{f=1} f && /macOS:/{gsub(/[" ]/,"",$2); print $2; exit}' "$ROOT/project.yml")}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/repro.swift" <<'SWIFT'
import Foundation

protocol Capturing: AnyObject, Sendable {
    func start() async throws
}

final class Capture: Capturing, @unchecked Sendable {
    let queue = DispatchQueue(label: "capture")
    func start() async throws {
        try await onQueue { () }
    }
    ATTR private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

protocol Coordinator: AnyObject {
    func start() async
}

@MainActor
final class Controller: Coordinator {
    let capture: any Capturing = Capture()
    func start() async {
        try? await capture.start()
        print(pthread_main_np() != 0 ? "main thread (ok)" : "cooperative thread (BUG)")
        exit(0)
    }
}

@MainActor
final class Hotkey {
    let coordinator: any Coordinator
    var last: Task<Void, Never>?
    init(coordinator: any Coordinator) { self.coordinator = coordinator }
    func down() {
        let previous = last
        let coordinator = self.coordinator
        let operation: @MainActor (any Coordinator) async -> Void = { await $0.start() }
        last = Task { @MainActor in
            await previous?.value
            await operation(coordinator)
        }
    }
}

let hotkey = Hotkey(coordinator: Controller())
hotkey.down()
RunLoop.main.run()
SWIFT

FLAGS=(-O -target "arm64-apple-macos$TARGET" -swift-version 6
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -enable-upcoming-feature InferIsolatedConformances)

echo "Swift: $(swift --version 2>&1 | grep -o 'Apple Swift version [0-9.]*')"
echo "Target: macOS $TARGET, -O"
for variant in plain concurrent; do
    attr=""
    [ "$variant" = concurrent ] && attr="@concurrent"
    sed "s/ATTR/$attr/" "$WORK/repro.swift" > "$WORK/$variant.swift"
    swiftc "${FLAGS[@]}" "$WORK/$variant.swift" -o "$WORK/$variant" 2>/dev/null
    printf '  %-11s helper: caller resumed on %s\n' "$variant" "$("$WORK/$variant")"
done
