import Foundation

/// The speech engine. Only the on-device engine is left (no cloud transcription in this app);
/// the type stays so the setting, the debug flags and the transcription seam keep their shape.
/// Persisted as the raw value under `AppSettings.Key.sttEngine`; any other stored value reads
/// as `.local`.
enum STTEngine: String, Codable, CaseIterable, Hashable, Sendable {
    /// The on-device engine (`WhisperEngine`). The raw value is from the Parakeet era and stays,
    /// so the stored setting keeps meaning "local" without a migration.
    case local = "parakeet"

    /// Model id reported in `TranscriptionResult.modelName` and shown in history.
    var modelName: String {
        switch self {
        case .local: return "whisper-large-v3-turbo"
        }
    }

    var displayName: String {
        switch self {
        case .local: return String(localized: "Lokalnie")
        }
    }
}

struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let modelName: String
    let ms: Int

    init(text: String, modelName: String, ms: Int) {
        self.text = text
        self.modelName = modelName
        self.ms = ms
    }
}
