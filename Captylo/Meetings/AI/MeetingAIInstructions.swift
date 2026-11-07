import Foundation

/// The system instructions of each meeting AI job, sent before the data (`MeetingChat`).
/// A stub for now: the open Polish instructions written for Bielik (PRD 7.4, the files under
/// `Meetings/AI/Instructions/`) plug in here at integration. Until then every job sends only
/// its data.
enum MeetingAIInstructions {
    static func system(for task: MeetingAITask) -> String? { nil }
}
