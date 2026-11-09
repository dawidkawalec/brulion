import Foundation

enum LlamaServerError: LocalizedError, Equatable, Sendable {
    /// Why a server process ended, read from its output (the output itself is never logged).
    enum ExitReason: String, Equatable, Sendable {
        case portInUse
        case outOfMemory
        case modelLoad
        case unknown

        static func classify(_ output: String) -> ExitReason {
            let text = output.lowercased()
            if text.contains("couldn't bind http server socket") { return .portInUse }
            if text.contains("failed to allocate") || text.contains("out of memory") { return .outOfMemory }
            if text.contains("failed to load model") || text.contains("error loading model") { return .modelLoad }
            return .unknown
        }
    }

    case helperMissing
    case modelMissing
    case launchFailed(String)
    case exited(status: Int32, reason: ExitReason)
    case startTimedOut
    /// Several starts failed in a row; the next try waits a moment.
    case coolingDown

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            String(localized: "Brakuje programu llama-server w aplikacji. Zainstaluj aplikację ponownie.", table: "LocalAI")
        case .modelMissing:
            String(localized: "Model nie jest pobrany.", table: "LocalAI")
        case .launchFailed(let message):
            String(localized: "Nie udało się uruchomić lokalnego modelu: \(message)", table: "LocalAI")
        case .exited(let status, let reason):
            switch reason {
            case .portInUse:
                String(localized: "Lokalny model nie znalazł wolnego portu. Spróbuj ponownie.", table: "LocalAI")
            case .outOfMemory:
                String(localized: "Za mało pamięci, aby wczytać model. Zamknij inne aplikacje albo wybierz mniejszy model.", table: "LocalAI")
            case .modelLoad:
                String(localized: "Nie udało się wczytać modelu. Plik może być uszkodzony: usuń go i pobierz ponownie.", table: "LocalAI")
            case .unknown:
                String(localized: "Lokalny model zakończył działanie nieoczekiwanie (kod \(Int(status))).", table: "LocalAI")
            }
        case .startTimedOut:
            String(localized: "Lokalny model nie uruchomił się na czas. Spróbuj ponownie.", table: "LocalAI")
        case .coolingDown:
            String(localized: "Lokalny model kilka razy nie wystartował. Spróbuję ponownie za chwilę.", table: "LocalAI")
        }
    }
}
