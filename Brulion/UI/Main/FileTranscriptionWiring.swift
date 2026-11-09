import Foundation

extension FileTranscriptionQueue.Services {
    /// Production wiring: the same router, dictionary and database the dictation path uses,
    /// plus a dedicated `Enhancer` with the 15 s file deadline when AI cleanup is on, on the same
    /// AI routes as dictation (the active mode's role picks the model, PRD 7.3).
    /// Takes the services one by one so `AppState.init` can build the queue it owns.
    @MainActor
    static func make(
        settings: AppSettings,
        router: any TranscriptionRouting,
        dictionary: DictionaryStore,
        database: Database,
        routes: any AIRouteProviding,
        stats: StatsTicker,
        persistsHistory: Bool
    ) -> FileTranscriptionQueue.Services {
        FileTranscriptionQueue.Services(
            router: router,
            engine: { settings.sttEngine },
            language: { settings.transcriptionLanguage },
            vocabulary: { dictionary.data.vocabulary },
            processor: { dictionary.processor },
            enhancement: {
                guard settings.aiEnabled else { return nil }
                // Own session: the dictation LLM session is tuned for short takes, and a long
                // transcript needs the 15 s file deadline.
                let enhancer = Enhancer(
                    routes: routes,
                    session: HTTP.fileLLMSession,
                    deadline: FileTranscriptionQueue.enhancementDeadline,
                    tokenCap: FileTranscriptionQueue.enhancementTokenCap
                )
                return FileTranscriptionQueue.FileEnhancement(
                    enhancer: enhancer,
                    mode: settings.activeMode,
                    vocabulary: dictionary.data.vocabulary
                )
            },
            save: { record in try await database.upsert(record) },
            didSave: { stats.bump() },
            // The in-memory fallback store loses its rows at quit: keep no WAV for them either.
            saveHistory: { settings.saveHistory && persistsHistory }
        )
    }
}
