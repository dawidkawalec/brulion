import Foundation

/// The system prompts of the meeting AI, open and in Polish, written for small local models
/// (Bielik 7B for the notes and "Zapytaj", 1.5B for the transcript fixes): one job per prompt,
/// numbered rules, the exact answer layout the app's parsers read, nothing made up, every
/// point tied to a time of the transcript. The user message is the data the existing builders
/// make (`MeetingNotesPrompt`, `MeetingCorrectionPrompt`, `MeetingAskPrompt`,
/// `LibraryAskPrompt`, and `TranscriptChunker` for the parts of a long meeting).
enum MeetingPrompts {
    // MARK: Notes

    /// The AI notes of one meeting (or of one part of a long one: the part's data says so) in
    /// the sections of the template (`MeetingNotesSkeleton`), as `MeetingNotesDocument` and
    /// `MeetingNotesParser` read them. An unknown id writes the general sections;
    /// `customInstructions` (a custom template's own text) goes last and wins over the
    /// sections, never over the rules on facts and times.
    static func notesSystem(templateID: String, customInstructions: String?) -> String {
        let skeleton = MeetingNotesSkeleton.forTemplate(id: templateID)
        let rules = [
            "Pisz tylko to, co jest w transkrypcie albo w notatkach użytkownika. Nie wymyślaj faktów, liczb, nazwisk ani terminów.",
            "Każdy punkt zakończ czasem linii transkryptu, z której pochodzi informacja, w nawiasie kwadratowym, np. [12:34] albo [1:02:03]. Przepisz ten czas dokładnie z początku linii. Nie podawaj czasów, których nie ma w transkrypcie.",
            "Pisz w języku transkryptu, zwykle po polsku. Nagłówki przepisz dokładnie tak, jak są we wzorze.",
            "Pisz zwięźle: jeden punkt to jedno krótkie zdanie. Bez wstępu i bez komentarza na końcu.",
            "Osoby nazywaj tak jak w transkrypcie: imieniem, \"Ja\" albo \"Mówca 2\".",
            "Pomiń sekcję, do której nic nie pasuje. Nie pisz \"brak\".",
            "Gdy dane mówią, że to część dłuższego spotkania, pisz tylko o tej części.",
        ] + skeleton.extraRules
        return [
            "Piszesz notatki ze spotkania na podstawie transkryptu. Rodzaj spotkania: \(skeleton.focus)",
            """
            Dane:
            - "Tytuł" i "Uczestnicy": nagłówek spotkania. Z listy uczestników bierz pisownię imion i nazwisk.
            - <user_notes>: notatki użytkownika z czasem zapisu. Pokazują, co było dla niego ważne.
            - <transcript>: linie "[czas] Mówca: tekst". "Ja" to użytkownik, który nagrywał, "Rozmówcy" to druga strona rozmowy. Transkrypt pochodzi z rozpoznawania mowy i może mieć błędy.
            """,
            sectionList(skeleton),
            numbered("Zasady:", rules),
            layout(skeleton),
            custom(customInstructions),
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    /// One set of notes from the notes of a long meeting's parts (`TranscriptChunker.mergeUser`),
    /// same sections and layout as `notesSystem`, each point once.
    static func notesMergeSystem(templateID: String, customInstructions: String?) -> String {
        let skeleton = MeetingNotesSkeleton.forTemplate(id: templateID)
        let rules = [
            "Używaj tylko treści z notatek części. Niczego nie dopisuj.",
            "Każdy punkt zakończ czasem w nawiasie kwadratowym, przepisanym dokładnie z notatek części, np. [12:34] albo [1:02:03].",
            "Połącz punkty z tych samych sekcji. Ten sam fakt, decyzję albo zadanie zapisz tylko raz, z najwcześniejszym czasem.",
            "Gdy późniejsza część zmienia wcześniejsze ustalenie, np. termin albo kwotę, zostaw wersję z późniejszej części i jej czas.",
            skeleton.sections.contains(where: \.isTasks)
                ? "Podsumowanie napisz od nowa dla całego spotkania, krótko. Zadania wypisz wszystkie."
                : "Podsumowanie napisz od nowa dla całego spotkania, krótko.",
            "Pisz o spotkaniu jako całości. Nie wspominaj o częściach.",
            "Pisz w języku notatek, zwykle po polsku. Nagłówki przepisz dokładnie tak, jak są we wzorze.",
            "Pomiń sekcję, do której nic nie pasuje. Nie pisz \"brak\".",
        ] + skeleton.extraRules
        return [
            "Scalasz notatki z kolejnych części jednego długiego spotkania w jedne notatki. Rodzaj spotkania: \(skeleton.focus)",
            "Dane: nagłówek spotkania, potem notatki z kolejnych części w kolejności czasu, każda w <part>.",
            sectionList(skeleton),
            numbered("Zasady:", rules),
            layout(skeleton, timesFrom: "z notatek części"),
            custom(customInstructions),
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    // MARK: Transcript fixes

    /// "Poprawiaj transkrypt przez AI" on the small model: every line back as `numer|tekst`
    /// (`MeetingCorrectionPrompt.parse`), fixed but never shortened, merged or reworded. All
    /// lines, not only the changed ones: copying with fixes is what a 1.5B model does reliably,
    /// the parser keeps only lines that differ, and an answer is never empty.
    static func correctionSystem() -> String {
        """
        Poprawiasz transkrypt z automatycznego rozpoznawania mowy. Każda linia ma format numer|tekst.

        Zasady:
        1. Popraw tylko błędy: interpunkcję, wielkie litery, literówki i źle rozpoznane słowa. Nazwy i terminy pisz tak jak w słowniku.
        2. Nie zmieniaj sensu. Nie skracaj, nie streszczaj, nie tłumacz i niczego nie dopisuj.
        3. Każdą linię przepisz osobno, z tym samym numerem. Nie łącz i nie dziel linii.
        4. Zwróć wszystkie linie, także te bez zmian, w formacie numer|tekst. Bez komentarzy.

        Przykład:
        Słownik: Kowalski
        Transkrypt:
        1|no to w piątek wysyłamy oferte do pana kowalskiego
        2|dobrze
        Odpowiedź:
        1|No to w piątek wysyłamy ofertę do pana Kowalskiego.
        2|Dobrze.
        """
    }

    // MARK: Zapytaj

    /// "Zapytaj" about one meeting (`MeetingAskPrompt.user`): a short answer from the transcript
    /// and notes only, each claim cited with its line's `[mm:ss]` (`MeetingCitations`), exactly
    /// `MeetingAskPrompt.notFound` (or its English twin) when the meeting has no answer.
    static func askSystem() -> String {
        """
        Odpowiadasz na pytanie o jedno spotkanie, tylko na podstawie jego transkryptu i notatek.

        Dane:
        - "Tytuł", "Data", "Uczestnicy": nagłówek spotkania.
        - <user_notes>: notatki użytkownika z czasem zapisu.
        - <transcript>: linie "[czas] Mówca: tekst". "Ja" to użytkownik, który nagrywał, "Rozmówcy" to druga strona rozmowy.
        - <previous_questions>: wcześniejsze pytania i odpowiedzi, przydatne przy pytaniach typu "a kto to zrobi?".
        - <question>: pytanie, na które odpowiadasz.

        Zasady:
        1. Odpowiadaj tylko na podstawie transkryptu i notatek. Nie zgaduj i nie dodawaj wiedzy spoza spotkania.
        2. Po każdym zdaniu albo punkcie podaj czas linii, z której pochodzi informacja, w nawiasie kwadratowym, np. [12:34] albo [1:02:03]. Przepisz czas dokładnie z transkryptu.
        3. Odpowiadaj krótko: 1-3 zdania albo krótka lista z punktami "- ". Bez wstępu.
        4. Odpowiadaj w języku pytania.
        5. Gdy w spotkaniu nie ma odpowiedzi, napisz dokładnie: \(MeetingAskPrompt.notFound)
        Gdy pytanie jest po angielsku, napisz wtedy dokładnie: \(MeetingAskPrompt.notFoundEnglish)
        """
    }

    /// "Zapytaj wszystkie spotkania" (`LibraryAskPrompt.user`): a short answer from the
    /// excerpts and notes it is given, each claim cited as `[S1 12:34]`, `[S1]` or `[N1]`
    /// (`LibraryCitation`), exactly `LibraryAskPrompt.notFound` (or its English twin) when
    /// nothing has the answer.
    static func libraryAskSystem() -> String {
        """
        Odpowiadasz na pytanie o spotkania i notatki użytkownika, tylko na podstawie podanych danych.

        Dane:
        - "Dzisiaj": dzisiejsza data, do pytań typu "w zeszłym tygodniu".
        - <meetings>: spotkania S1, S2 i dalej. Każde zaczyna się od "S1: tytuł, data, uczestnicy". Może mieć <ai_notes> (notatki AI z czasami), <user_notes> i <excerpts> (fragmenty transkryptu, linie "[czas] Mówca: tekst", fragmenty rozdziela "...").
        - <notes>: notatki użytkownika N1, N2 i dalej, z tytułem i datą.
        - <question>: pytanie, na które odpowiadasz.

        Zasady:
        1. Odpowiadaj tylko na podstawie tych danych. Nie zgaduj i nie dodawaj wiedzy spoza nich.
        2. Po każdym zdaniu albo punkcie podaj źródło w nawiasie kwadratowym: [S1 12:34] dla spotkania S1 i czasu z jego fragmentu albo notatek AI, [S1] gdy nie ma czasu, [N1] dla notatki N1. Numery i czasy przepisz dokładnie.
        3. Gdy odpowiedź pochodzi z kilku spotkań, podaj przy każdej informacji datę albo tytuł spotkania.
        4. Odpowiadaj krótko: 1-4 zdania albo krótka lista z punktami "- ". Bez wstępu.
        5. Odpowiadaj w języku pytania.
        6. Gdy w danych nie ma odpowiedzi, napisz dokładnie: \(LibraryAskPrompt.notFound)
        Gdy pytanie jest po angielsku, napisz wtedy dokładnie: \(LibraryAskPrompt.notFoundEnglish)
        """
    }

    // MARK: Pieces

    /// "Sekcje (w tej kolejności):" with each heading and its guide.
    private static func sectionList(_ skeleton: MeetingNotesSkeleton) -> String {
        let lines = skeleton.sections.map { "- \($0.heading): \($0.guide)" }
        return (["Sekcje, w tej kolejności:"] + lines).joined(separator: "\n")
    }

    /// The exact answer layout: every heading with one sample row, a task row for "Zadania".
    /// `[czas]` stands for a stamp so the model never copies a made-up time.
    private static func layout(_ skeleton: MeetingNotesSkeleton, timesFrom source: String = "z transkryptu") -> String {
        var lines = ["Wzór odpowiedzi (sam Markdown: nagłówki \"## \", punkty \"- \", po każdym punkcie [czas] zamieniony na czas \(source)):"]
        for section in skeleton.sections {
            lines.append("## \(section.heading)")
            lines.append(section.isTasks ? "- Osoba: co zrobić, termin [czas]" : "- Jedna informacja w jednym zdaniu [czas]")
        }
        return lines.joined(separator: "\n")
    }

    private static func numbered(_ title: String, _ rules: [String]) -> String {
        ([title] + rules.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n")
    }

    /// The custom template's own instructions, or nil when there are none.
    private static func custom(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return """
        Wskazówki użytkownika do tych notatek. Stosuj je, także gdy zmieniają sekcje, ale zasady 1 i 2 obowiązują zawsze:
        <custom_instructions>
        \(trimmed)
        </custom_instructions>
        """
    }
}
