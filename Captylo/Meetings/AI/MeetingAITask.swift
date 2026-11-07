import Foundation

/// One meeting AI job. It picks the model (`role`) and the instructions
/// (`MeetingAIInstructions.system(for:)`); the data payload comes from the prompt builders
/// (`MeetingNotesPrompt`, `MeetingAskPrompt`, `LibraryAskPrompt`, `MeetingCorrectionPrompt`).
enum MeetingAITask: Sendable, Equatable {
    /// AI notes with the template picked for the meeting (`MeetingTemplate.id`).
    case notes(templateID: String)
    /// "Zapytaj" about one meeting.
    case ask
    /// "Zapytaj wszystkie spotkania".
    case libraryAsk
    /// "Poprawiaj transkrypt przez AI", one batch of numbered lines.
    case transcriptCorrection

    /// Transcript fixes run on the small correction model, everything else on the stronger
    /// one (PRD 7.4).
    var role: AIRole {
        switch self {
        case .transcriptCorrection: return .correction
        case .notes, .ask, .libraryAsk: return .features
        }
    }
}
