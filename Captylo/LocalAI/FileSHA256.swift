import CryptoKit
import Foundation
import os

/// SHA-256 of a file read in chunks on a utility queue, so a 5 GB model never sits in memory
/// and never blocks the cooperative pool. Cancelling the calling task stops between chunks.
enum FileSHA256 {
    static let chunkSize = 8 * 1024 * 1024

    /// Lowercase hex digest. `progress` gets the bytes hashed so far after every chunk.
    static func hex(of url: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try compute(url, cancelled: cancelled, progress: progress))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static func compute(
        _ url: URL,
        cancelled: OSAllocatedUnfairLock<Bool>,
        progress: (@Sendable (Int64) -> Void)?
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var hashed: Int64 = 0
        while true {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            hashed += Int64(chunk.count)
            progress?(hashed)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
