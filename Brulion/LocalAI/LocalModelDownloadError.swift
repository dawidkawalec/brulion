import Foundation

enum LocalModelDownloadError: LocalizedError, Equatable {
    case unknownModel
    case alreadyDownloading
    case notEnoughSpace(needed: Int64, available: Int64)
    case httpStatus(Int)
    /// A redirect pointed outside huggingface.co and its CDN (or away from HTTPS).
    case unexpectedHost
    /// The server answered something a resumable download cannot use.
    case badResponse
    /// The connection ended before all bytes arrived; the `.part` stays for resuming.
    case incomplete
    /// More bytes than the spec says arrived; the `.part` was removed.
    case sizeMismatch
    /// The SHA-256 differs from the spec; the `.part` was removed.
    case checksumMismatch
    case network(String)
    case file(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel:
            String(localized: "Nieznany model.", table: "LocalAI")
        case .alreadyDownloading:
            String(localized: "Ten model już się pobiera.", table: "LocalAI")
        case .notEnoughSpace(let needed, let available):
            String(localized: "Za mało miejsca na dysku: potrzeba \(LocalAIFormat.gigabytes(needed)), wolne \(LocalAIFormat.gigabytes(available)).", table: "LocalAI")
        case .httpStatus(let status):
            String(localized: "Serwer pobierania odpowiedział błędem \(status).", table: "LocalAI")
        case .unexpectedHost:
            String(localized: "Pobieranie przekierowało do nieznanego serwera, więc zostało przerwane.", table: "LocalAI")
        case .badResponse:
            String(localized: "Serwer pobierania odpowiedział w nieoczekiwany sposób. Spróbuj ponownie.", table: "LocalAI")
        case .incomplete:
            String(localized: "Pobieranie zostało przerwane. Spróbuj ponownie, aby je wznowić.", table: "LocalAI")
        case .sizeMismatch:
            String(localized: "Pobrany plik modelu ma zły rozmiar. Spróbuj ponownie.", table: "LocalAI")
        case .checksumMismatch:
            String(localized: "Pobrany plik modelu jest uszkodzony (suma kontrolna się nie zgadza). Spróbuj ponownie.", table: "LocalAI")
        case .network(let message):
            String(localized: "Błąd sieci: \(message)", table: "LocalAI")
        case .file(let message):
            String(localized: "Nie udało się zapisać modelu na dysku: \(message)", table: "LocalAI")
        }
    }
}
