import Foundation

/// What a local model is used for (PRD 6). The app maps its own AI roles onto these two at
/// integration: dictation cleanup, meeting transcript fixes and note titles are `correction`;
/// AI modes, custom prompts, meeting notes, "Zapytaj" and the style profile are `features`.
enum LocalRole: String, Codable, CaseIterable, Sendable {
    /// Dictation cleanup and transcript fixes: the smallest model, latency first.
    case correction
    /// AI modes, meeting notes and questions: the stronger model, quality first.
    case features
}
