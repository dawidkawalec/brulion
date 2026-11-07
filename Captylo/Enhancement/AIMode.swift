import Foundation

/// One "Tryb AI": a named system prompt the user switches between (clean up, translate to
/// English, organize thoughts, ...). Stored as JSON in `AppSettings.aiModes`.
struct AIMode: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// SF Symbol shown next to the name.
    var symbol: String
    /// System prompt; may contain `{DICTIONARY}` (see `CleanupPrompt.system`). For a cleanup
    /// mode it replaces only the system text: the few-shot turns and the `<tekst>` wrapping stay.
    var prompt: String
    var kind: AIModeKind
    /// Hard deadline of one call in seconds, clamped to `deadlineRange` when used.
    var deadlineSeconds: Double
    /// Set for the built-in modes (`BuiltInAIModes`), nil for the user's own.
    var builtInKey: String?

    /// Allowed deadline in seconds.
    static let deadlineRange: ClosedRange<Double> = 1...20
    static let defaultSymbol = "wand.and.stars"

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = AIMode.defaultSymbol,
        prompt: String,
        kind: AIModeKind,
        deadlineSeconds: Double,
        builtInKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.prompt = prompt
        self.kind = kind
        self.deadlineSeconds = deadlineSeconds
        self.builtInKey = builtInKey
    }

    var isBuiltIn: Bool { builtInKey != nil }

    /// `deadlineSeconds` clamped to 1...20 s.
    var clampedDeadlineSeconds: Double {
        guard deadlineSeconds.isFinite else { return BuiltInAIModes.cleanupDeadline }
        return min(max(deadlineSeconds, Self.deadlineRange.lowerBound), Self.deadlineRange.upperBound)
    }

    var deadline: Duration { .milliseconds(Int((clampedDeadlineSeconds * 1000).rounded())) }

    /// The system prompt with the vocabulary filled in (or its line removed when empty) and the
    /// learned "heard -> meant" hints appended (the style profile only for a rewrite).
    func systemPrompt(vocabulary: [String], learned: LearningPromptContext = .none) -> String {
        CleanupPrompt.system(template: prompt, vocabulary: vocabulary, learned: learned, kind: kind)
    }

    /// What the usage counter calls this mode: the built-in key, else the id (never the prompt).
    var usageID: String {
        builtInKey ?? id.uuidString
    }

    /// Which model serves this mode (PRD 7.2-7.3): the built-in "Czyszczenie" runs on the small
    /// correction model, every other mode (built-in or the user's own) on the stronger one.
    var role: AIRole {
        builtInKey == BuiltInAIModes.Key.cleanup ? .correction : .features
    }

    /// What one call of this mode sends and how its answer is judged. The mode's own limit is the
    /// floor of the call's deadline (the dictation enhancer stretches it for longer input).
    func job(vocabulary: [String], learned: LearningPromptContext = .none) -> EnhancementJob {
        EnhancementJob(
            systemPrompt: systemPrompt(vocabulary: vocabulary, learned: learned),
            kind: kind,
            role: role,
            deadline: deadline,
            vocabulary: CleanupPrompt.guardVocabulary(vocabulary, learned: learned),
            usageID: usageID
        )
    }

    /// Starting point for "Dodaj tryb": a rewrite mode with the house rules already in place.
    static func newCustom() -> AIMode {
        AIMode(
            name: String(localized: "Nowy tryb"),
            symbol: defaultSymbol,
            prompt: BuiltInAIModes.customTemplate,
            kind: .rewrite,
            deadlineSeconds: 6
        )
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, prompt, kind, deadlineSeconds, builtInKey
    }

    /// Tolerant decoding: a missing or unknown field falls back to a default instead of
    /// dropping the whole list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? Self.defaultSymbol
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        kind = AIModeKind(rawValue: rawKind) ?? .cleanup
        deadlineSeconds = try container.decodeIfPresent(Double.self, forKey: .deadlineSeconds) ?? BuiltInAIModes.cleanupDeadline
        builtInKey = try container.decodeIfPresent(String.self, forKey: .builtInKey)
    }
}
