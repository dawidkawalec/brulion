import Foundation

/// Result of one AI call. Raw text is delivered whenever `text` is nil.
enum EnhancementOutcome: Sendable, Equatable {
    case enhanced(text: String, ms: Int, model: String)
    /// The model was not called.
    case skipped(EnhancementSkip)
    case failed(EnhancementFailure, ms: Int)

    var text: String? {
        if case .enhanced(let text, _, _) = self { return text }
        return nil
    }

    var ms: Int? {
        switch self {
        case .enhanced(_, let ms, _), .failed(_, let ms): return ms
        case .skipped: return nil
        }
    }

    /// Short Polish note for the history row when AI produced no text, nil on success.
    var note: String? {
        switch self {
        case .enhanced: return nil
        case .skipped(let skip): return skip.note
        case .failed(let failure, _): return failure.note
        }
    }

    /// Full Polish message for toasts and inline errors, nil on success.
    var errorMessage: String? {
        switch self {
        case .enhanced: return nil
        case .skipped(let skip): return skip.errorDescription
        case .failed(let failure, _): return failure.errorDescription
        }
    }
}

/// What one AI call sends and how its answer is judged (built from an `AIMode`).
struct EnhancementJob: Sendable, Equatable {
    var systemPrompt: String
    var kind: AIModeKind
    /// Which model serves the call: the small correction model or the stronger one (PRD 5-6).
    var role: AIRole
    /// Hard deadline of the call; nil = the enhancer's own (3 s dictation, 15 s files).
    var deadline: Duration?

    init(systemPrompt: String, kind: AIModeKind = .cleanup, role: AIRole = .features, deadline: Duration? = nil) {
        self.systemPrompt = systemPrompt
        self.kind = kind
        self.role = role
        self.deadline = deadline
    }
}

/// Why the model was not called.
enum EnhancementSkip: LocalizedError, Sendable, Equatable {
    /// Empty text, or 3 words or fewer for a cleanup mode.
    case tooShort
    /// No route: no local model ready and the cloud off (or without a key).
    case noKey

    var errorDescription: String? {
        switch self {
        case .tooShort:
            return String(localized: "Tekst jest za krótki dla tego trybu (3 słowa lub mniej).")
        case .noKey:
            return ChatCompletionsError.missingKey.errorDescription
        }
    }

    var note: String {
        switch self {
        case .tooShort: return String(localized: "Za krótkie (3 słowa lub mniej)")
        case .noKey: return String(localized: "Brak modelu AI")
        }
    }
}

/// Why the model's answer was not used.
enum EnhancementFailure: LocalizedError, Sendable, Equatable {
    /// No answer within the deadline, in seconds.
    case deadline(seconds: Double)
    /// The model server answered with an error status (401, 429, 5xx...).
    case http(status: Int)
    case network(String)
    /// The answer could not be decoded.
    case invalidResponse
    /// The sanity guard threw the answer away.
    case rejected(EnhancementRejection)

    var errorDescription: String? {
        switch self {
        case .deadline:
            return EnhancerError.deadline.errorDescription
        case .http(let status):
            return ChatCompletionsError.forStatus(status).errorDescription
        case .network(let detail):
            return ChatCompletionsError.network(detail).errorDescription
        case .invalidResponse:
            return ChatCompletionsError.decoding.errorDescription
        case .rejected(let rejection):
            return rejection.errorDescription
        }
    }

    var note: String {
        switch self {
        case .deadline(let seconds):
            let limit = seconds.formatted(.number.precision(.fractionLength(0...1)).locale(AppLocale.current))
            return String(localized: "Przekroczono limit \(limit) s")
        case .http(let status):
            return String(localized: "Błąd AI \(String(status))")
        case .network:
            return String(localized: "Błąd sieci")
        case .invalidResponse:
            return String(localized: "Nieoczekiwana odpowiedź AI")
        case .rejected(let rejection):
            return rejection.note
        }
    }
}

/// Sanity guard verdicts (gotcha 68).
enum EnhancementRejection: Sendable, Equatable {
    case empty
    /// `finish_reason == "length"`.
    case truncated
    /// Cleanup output below 0.4 x the transcript length.
    case tooShort
    /// Cleanup output above 2.5 x the transcript length.
    case tooLong

    var errorDescription: String {
        switch self {
        case .empty: return String(localized: "Model zwrócił pustą odpowiedź.")
        case .truncated: return String(localized: "Odpowiedź modelu została ucięta.")
        case .tooShort, .tooLong: return String(localized: "Odpowiedź modelu ma podejrzaną długość.")
        }
    }

    var note: String {
        switch self {
        case .empty: return String(localized: "Odrzucono: pusta odpowiedź")
        case .truncated: return String(localized: "Odrzucono: odpowiedź ucięta")
        case .tooShort: return String(localized: "Odrzucono: wynik podejrzanie krótki")
        case .tooLong: return String(localized: "Odrzucono: wynik podejrzanie długi")
        }
    }
}

