import Foundation

/// The system instructions of each meeting AI job, sent before the data (`MeetingChat`): the
/// open Polish prompts written for Bielik (`MeetingPrompts`, PRD 7.4). A long meeting's notes
/// also use the merge instructions (`MeetingNotesWriter`).
enum MeetingAIInstructions {
    static func system(for task: MeetingAITask) -> String {
        switch task {
        case .notes(let templateID): MeetingPrompts.notesSystem(templateID: templateID, customInstructions: nil)
        case .ask: MeetingPrompts.askSystem()
        case .libraryAsk: MeetingPrompts.libraryAskSystem()
        case .transcriptCorrection: MeetingPrompts.correctionSystem()
        }
    }
}
