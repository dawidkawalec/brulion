import Foundation

/// Progress of one model download, resumed bytes included.
struct LocalDownloadProgress: Equatable, Sendable {
    /// Bytes in the `.part` file so far.
    let receivedBytes: Int64
    let totalBytes: Int64
    /// Recent transfer speed (0 until it is known).
    let bytesPerSecond: Double

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    /// Seconds left at the current speed, nil while the speed is unknown.
    var secondsRemaining: Double? {
        guard bytesPerSecond > 0 else { return nil }
        return Double(max(0, totalBytes - receivedBytes)) / bytesPerSecond
    }
}

/// What a running download reports besides its result.
enum LocalDownloadEvent: Equatable, Sendable {
    case progress(LocalDownloadProgress)
    /// All bytes are in; the SHA-256 check runs (a few seconds for gigabytes).
    case verifying
}
