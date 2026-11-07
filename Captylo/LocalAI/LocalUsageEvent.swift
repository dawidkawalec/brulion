import Foundation

/// Something the local AI did, counted by `LocalUsageStats` (never with any text).
enum LocalUsageEvent: Equatable, Sendable {
    case dictation
    case correctionAccepted(milliseconds: Int)
    /// `reason` is `CorrectionGuard.Rejection.code`.
    case correctionRejected(reason: String, milliseconds: Int)
    case timeout(LocalRole)
    /// An AI mode or custom prompt ran; `id` is the mode's id, never its prompt.
    case modeUsed(id: String)
    case meetingProcessed
    case serverFailure
}
