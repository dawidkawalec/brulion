import Foundation

/// Widget state for `--show-widget` screenshots.
enum WidgetDebugState: String, CaseIterable, Sendable {
    case recording
    case transcribing
    case enhancing
}

/// Headless CLI flags kept in Release (docs/architecture.md "Debug CLI flags").
enum DebugCommand: Sendable, Equatable {
    /// `--transcribe <file> [--ai] [--mode <key|name>] [--language pl] [--engine local]`. `language`
    /// is the raw flag value (nil = use the app setting; "auto" is passed through and mapped by the
    /// runner); `engine` nil = the app setting (always local; any other engine name fails to parse).
    /// `mode` picks the AI mode for this run only (a built-in key such as `email`, or a mode's
    /// name; nil = the active mode), implies `--ai` and never changes the setting. `moreFiles` are
    /// the paths typed after the first one (`--transcribe a.wav b.wav --ai`), done in the same run.
    case transcribe(url: URL, ai: Bool, language: String?, engine: STTEngine? = nil, mode: String? = nil, moreFiles: [URL] = [])
    /// `--show-widget <recording|transcribing|enhancing>`
    case showWidget(WidgetDebugState)
    /// `--check`
    case check
    /// `--reset-onboarding`
    case resetOnboarding
    /// `--open-section <pulpit|spotkania|notatki|historia|plik|slownik|modele|ustawienia>` (hidden, for screenshots):
    /// a normal GUI launch that skips the onboarding and opens the main window on that section.
    case openSection(MainSection)
    /// `--design-preview <target>` (hidden, for design screenshots, see `DesignPreviewTarget`):
    /// one screen on fake data with no services (no hotkey tap, audio, model, store on disk).
    /// The raw target is kept as typed ("" when missing) so a typo fails loudly in the runner
    /// instead of falling through to a normal GUI launch with a second hotkey tap.
    case designPreview(String)
    /// `--ax-probe [--show-text]` (hidden, self-learning spike): prints one JSON line whenever the
    /// focused text field changes (app, role, length, selection) until killed. The field text is
    /// printed only with `--show-text`, so a pasted probe log never carries it by accident.
    case axProbe(showText: Bool)
    /// `--watch-paste <text>` (hidden, self-learning check): pastes the text into the focused
    /// field like a dictation, watches it for edits and prints what was learned. Use with
    /// `CAPTYLO_DATA_DIR` so the learning lands in a scratch folder.
    case watchPaste(String)
    /// `--meeting-from-files <me-audio> <them-audio>`: the meeting transcription pipeline on two files
    /// instead of live capture (no mic, no system audio tap, in-memory store). `me` stands for the
    /// mic track and `them` for the system track; both start at meeting time 0.
    case meetingFromFiles(me: URL, them: URL)
    /// `--meeting-ai <transcript.json> [--template <id>] [--fix] [--ask <question>]...`: the AI after
    /// a meeting on a saved transcript (`DebugMeetingInput`: the JSON `--meeting-from-files` prints,
    /// or the same with a title and speaker names), in an in-memory store and on the app's AI
    /// routes: the transcript fixes with `--fix` (correction model), the AI notes (features model,
    /// in parts when long) and "Zapytaj" for each `--ask`. Prints each step's text, model and time.
    case meetingAI(url: URL, templateID: String?, fix: Bool, questions: [String])
    /// `--benchmark <audio file> [--reference <txt file>] [--language pl]`: transcribes the file with
    /// the local model (`ModelBenchmark`) and prints the text with timings, peak memory and, with a
    /// reference transcript, the word error rate. `language` is the raw flag value like
    /// `--transcribe` (nil = the app setting).
    case benchmark(url: URL, reference: URL?, language: String?)
    /// `--rebuild-search-index`: empties the meeting search index and fills it again from the
    /// store at `AppPaths` (point `CAPTYLO_DATA_DIR` at a copy), then prints meetings, rows and ms.
    case rebuildSearchIndex
    /// `--mcp`: the read-only MCP server over stdin/stdout (`MCPServer`), started by the user's
    /// AI assistant from the config "Skopiuj konfigurację" copies. Served by `CaptyloMain`
    /// before AppKit starts (no app state, UI, services or LaunchServices check-in); the library
    /// is read from `AppPaths` read-only. Runs until stdin closes.
    case mcp

    static let primaryFlags: [String] = [
        "--transcribe", "--show-widget", "--check", "--reset-onboarding", "--open-section", "--design-preview",
        "--ax-probe", "--watch-paste", "--meeting-from-files", "--meeting-ai", "--benchmark", "--rebuild-search-index", "--mcp",
    ]

    /// Headless commands never start the services; all but `--open-section` go to `DebugRunner`.
    /// `--design-preview` shows windows too, but on fake services, so it counts as headless.
    var isHeadless: Bool {
        if case .openSection = self { return false }
        return true
    }

    /// Parses `CommandLine.arguments`. Tokens before the first known flag (the executable path,
    /// Xcode's own arguments) are ignored. Returns nil when no flag is present or it is malformed.
    static func parse(_ args: [String]) -> DebugCommand? {
        guard let start = args.firstIndex(where: { primaryFlags.contains($0) }) else { return nil }
        let rest = Array(args[(start + 1)...])
        switch args[start] {
        case "--check":
            return .check
        case "--rebuild-search-index":
            return .rebuildSearchIndex
        case "--mcp":
            return .mcp
        case "--reset-onboarding":
            return .resetOnboarding
        case "--show-widget":
            guard let raw = rest.first, let state = WidgetDebugState(rawValue: raw) else { return nil }
            return .showWidget(state)
        case "--open-section":
            // Accepts the raw value with or without Polish diacritics ("slownik", "Słownik").
            guard let raw = rest.first else { return nil }
            let key = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "ł", with: "l")
            guard let section = MainSection(rawValue: key) else { return nil }
            return .openSection(section)
        case "--design-preview":
            guard let raw = rest.first, !raw.hasPrefix("--") else { return .designPreview("") }
            return .designPreview(raw.lowercased())
        case "--ax-probe":
            return .axProbe(showText: rest.contains("--show-text"))
        case "--watch-paste":
            guard let text = rest.first, !text.hasPrefix("--"), !text.isEmpty else { return nil }
            return .watchPaste(text)
        case "--transcribe":
            guard let path = rest.first, !path.hasPrefix("--"), !path.isEmpty else { return nil }
            var ai = false
            var language: String?
            var engine: STTEngine?
            var mode: String?
            // More files up to the first flag (or defaults-domain argument such as "-ai.enabled").
            let moreFiles = rest.dropFirst().prefix { !$0.hasPrefix("-") && !$0.isEmpty }.map(fileURL)
            var index = 1 + moreFiles.count
            while index < rest.count {
                switch rest[index] {
                case "--ai":
                    ai = true
                case "--mode":
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--"), !rest[index + 1].isEmpty else { return nil }
                    mode = rest[index + 1]
                    ai = true
                    index += 1
                case "--language":
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { return nil }
                    language = rest[index + 1]
                    index += 1
                case "--engine":
                    guard index + 1 < rest.count else { return nil }
                    switch rest[index + 1].lowercased() {
                    case "local", "whisper", "parakeet": engine = .local
                    default: return nil
                    }
                    index += 1
                default:
                    break
                }
                index += 1
            }
            return .transcribe(url: fileURL(path), ai: ai, language: language, engine: engine, mode: mode, moreFiles: moreFiles)
        case "--meeting-from-files":
            let paths = rest.prefix(2)
            guard paths.count == 2, paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("--") }) else { return nil }
            return .meetingFromFiles(me: fileURL(paths[paths.startIndex]), them: fileURL(paths[paths.startIndex + 1]))
        case "--meeting-ai":
            guard let path = rest.first, !path.hasPrefix("--"), !path.isEmpty else { return nil }
            var templateID: String?
            var fix = false
            var questions: [String] = []
            var index = 1
            while index < rest.count {
                switch rest[index] {
                case "--fix":
                    fix = true
                case "--template":
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--"), !rest[index + 1].isEmpty else { return nil }
                    templateID = rest[index + 1]
                    index += 1
                case "--ask":
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { return nil }
                    let question = rest[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !question.isEmpty else { return nil }
                    questions.append(question)
                    index += 1
                default:
                    break
                }
                index += 1
            }
            return .meetingAI(url: fileURL(path), templateID: templateID, fix: fix, questions: questions)
        case "--benchmark":
            guard let path = rest.first, !path.hasPrefix("--"), !path.isEmpty else { return nil }
            var reference: URL?
            var language: String?
            var index = 1
            while index < rest.count {
                switch rest[index] {
                case "--reference":
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { return nil }
                    reference = fileURL(rest[index + 1])
                    index += 1
                case "--language":
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { return nil }
                    language = rest[index + 1]
                    index += 1
                default:
                    break
                }
                index += 1
            }
            return .benchmark(url: fileURL(path), reference: reference, language: language)
        default:
            return nil
        }
    }

    /// A file URL for a path typed on the command line (`~` expanded).
    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The mode `--mode` names: a built-in key (`cleanup`, `email`...) or a mode's name, both
    /// without regard to case or Polish diacritics ("e-mail", "Lista zadan").
    static func mode(matching query: String, in modes: [AIMode]) -> AIMode? {
        let key = folded(query)
        return modes.first { $0.builtInKey.map(folded) == key } ?? modes.first { folded($0.name) == key }
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l")
    }
}

/// The transcript `--meeting-ai` reads: the JSON `--meeting-from-files` prints, or the same shape
/// with a title, participants and speaker names (`speakerNames` maps a diarization label such as
/// "1" to a name). `track` defaults to `them`; a missing `end` runs to just before the next segment.
struct DebugMeetingInput: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        var track: MeetingTrack?
        var start: Double
        var end: Double?
        var text: String
        var speaker: String?
        var echo: Bool?
    }

    var title: String?
    var participants: [String]?
    var speakerNames: [String: String]?
    var segments: [Segment]

    /// The meeting, completed like after its stop, and its segments in file order.
    func records(fallbackTitle: String) -> (meeting: MeetingRecord, segments: [MeetingSegmentRecord]) {
        var meeting = MeetingRecord(title: title ?? fallbackTitle)
        meeting.status = .completed
        meeting.participants = participants ?? []
        meeting.speakerNames = speakerNames ?? [:]
        var records = segments.map { segment in
            MeetingSegmentRecord(
                meetingID: meeting.id,
                track: segment.track ?? .them,
                start: segment.start,
                end: segment.end ?? segment.start,
                text: segment.text,
                speaker: segment.speaker,
                isEcho: segment.echo ?? false
            )
        }
        for index in records.indices where segments[index].end == nil {
            let next = index + 1 < records.count ? records[index + 1].start : records[index].start + 6
            records[index].end = max(records[index].start + 1, next - 0.3)
        }
        meeting.duration = records.map(\.end).max() ?? 0
        return (meeting, records)
    }
}

/// Executes a parsed command headless: prints JSON to stdout and returns the exit code.
/// Wired by the integrator (`AppState.debugRunner`).
@MainActor
protocol DebugCommandRunner: AnyObject {
    func run(_ command: DebugCommand) async -> Int32
}
