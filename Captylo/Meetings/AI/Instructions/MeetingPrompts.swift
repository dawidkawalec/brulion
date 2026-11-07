import Foundation

/// The system prompts of the meeting AI, open and in Polish, written for small local models
/// (Bielik 7B for the notes and "Zapytaj", 1.5B for the transcript fixes): one job per prompt,
/// numbered rules, a worked example, the exact answer layout the app's parsers read, nothing
/// made up, every point tied to a time of the transcript. The user message is the data the
/// existing builders make (`MeetingNotesPrompt`, `MeetingCorrectionPrompt`, `MeetingAskPrompt`,
/// `LibraryAskPrompt`, and `TranscriptChunker` for the parts of a long meeting), followed by the
/// matching reminder below: a 7B model follows the layout and the citations far better when
/// they are restated after a long transcript.
enum MeetingPrompts {
    // MARK: Notes

    /// The AI notes of one meeting (or of one part of a long one: the part's data says so) in
    /// the sections of the template (`MeetingNotesSkeleton`), as `MeetingNotesDocument` and
    /// `MeetingNotesParser` read them. An unknown id writes the general sections;
    /// `customInstructions` (a custom template's own text) goes last and wins over the
    /// sections, never over the rules on facts and times.
    static func notesSystem(templateID: String, customInstructions: String?) -> String {
        let skeleton = MeetingNotesSkeleton.forTemplate(id: templateID)
        var rules = [
            "Pisz tylko to, co jest w transkrypcie albo w notatkach użytkownika. Nie wymyślaj faktów, liczb, nazwisk, dat ani terminów.",
            "Każdy punkt kończy się czasem w nawiasie kwadratowym: czasem z początku linii transkryptu, w której pada ta informacja, np. [12:34] albo [1:02:03]. Punkt bez czasu jest błędem. Czas to jeden moment, nigdy zakres. Każdy czas w osobnym nawiasie.",
            "Jeden punkt to jedno krótkie zdanie, najwyżej 20 słów. Lepiej kilka krótkich punktów niż jeden długi, także w podsumowaniu.",
        ]
        if skeleton.sections.contains(where: \.isTasks) {
            rules.append("W sekcji \(MeetingNotesSkeleton.tasksHeading) jedno zadanie to jeden punkt: \"Osoba: co zrobić, termin\". Gdy osoba ma kilka zadań, wpisz każde osobno.")
        }
        rules += [
            "Pisz w języku transkryptu, zwykle po polsku. Nagłówki przepisz dokładnie tak, jak są we wzorze.",
            "Osoby nazywaj tak jak w transkrypcie: imieniem, \"Ja\" albo \"Mówca 2\".",
            "Pomiń sekcję, do której nic nie pasuje. Nie pisz \"brak\". Bez wstępu i bez komentarza na końcu.",
            "Gdy dane mówią, że to część dłuższego spotkania, pisz tylko o tej części.",
        ]
        rules += skeleton.extraRules
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
            """
            Przykład, jak z linii transkryptu powstają punkty (inne spotkanie):
            [3:10] Ja: Proponuję przesunąć premierę katalogu na maj.
            [3:18] Ewa: Zgoda, maj. Przygotuję nowy plan do piątku.
            Punkty:
            - Premiera katalogu przesunięta na maj [3:18]
            - Ewa: nowy plan premiery, do piątku [3:18]
            """,
            layout(skeleton),
            custom(customInstructions),
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    /// Goes after the data of a notes call (`MeetingNotesWriter` adds it): the sections and the
    /// citation rule once more, where the model reads them last.
    static func notesReminder(templateID: String) -> String {
        let skeleton = MeetingNotesSkeleton.forTemplate(id: templateID)
        let headings = skeleton.sections.map(\.heading).joined(separator: ", ")
        return "Napisz teraz notatki z powyższych danych według wzoru z instrukcji, z sekcjami: \(headings). Każdy punkt to jedno krótkie zdanie zakończone czasem linii transkryptu w nawiasie kwadratowym, np. [12:34]."
    }

    /// One set of notes from the notes of a long meeting's parts (`TranscriptChunker.mergeUser`),
    /// same sections and layout as `notesSystem`, each point once.
    static func notesMergeSystem(templateID: String, customInstructions: String?) -> String {
        let skeleton = MeetingNotesSkeleton.forTemplate(id: templateID)
        let hasTasks = skeleton.sections.contains(where: \.isTasks)
        var rules = [
            "Używaj tylko treści z notatek części. Niczego nie dopisuj.",
            "Każdy punkt kończy się czasem w nawiasie kwadratowym, przepisanym dokładnie z notatek części, np. [12:34] albo [1:02:03]. Każdy czas w osobnym nawiasie.",
            "Ten sam fakt, decyzję albo zadanie zapisz tylko raz, z najwcześniejszym czasem.",
            "Gdy późniejsza część zmienia wcześniejsze ustalenie, np. termin albo kwotę, zostaw tylko wersję z późniejszej części i jej czas.",
            "Podsumowanie napisz od nowa dla całego spotkania: 3-7 krótkich punktów.",
        ]
        if hasTasks {
            rules.append("Jedno zadanie to jeden punkt: \"Osoba: co zrobić, termin\". Zadań nie łącz w jeden punkt. Wypisz wszystkie zadania.")
        }
        rules += [
            "Pisz o spotkaniu jako całości. Nie wspominaj o częściach.",
            "Pisz w języku notatek, zwykle po polsku. Nagłówki przepisz dokładnie tak, jak są we wzorze.",
            "Pomiń sekcję, do której nic nie pasuje. Nie pisz \"brak\". Bez wstępu i bez komentarza na końcu.",
        ]
        rules += skeleton.extraRules
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

    /// Goes after the data of a merge call (`MeetingNotesWriter` adds it).
    static func notesMergeReminder(templateID: String) -> String {
        let skeleton = MeetingNotesSkeleton.forTemplate(id: templateID)
        let headings = skeleton.sections.map(\.heading).joined(separator: ", ")
        return "Scal teraz te notatki w jedne według wzoru z instrukcji, z sekcjami: \(headings). Każdą informację zapisz raz, jako krótki punkt zakończony czasem z notatek części w nawiasie kwadratowym, np. [12:34]."
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

    /// "Zapytaj" about one meeting (`MeetingAskPrompt.user`, then `askReminder`): a short answer
    /// from the transcript and notes only, each claim cited with its line's `[mm:ss]`
    /// (`MeetingCitations`), exactly `MeetingAskPrompt.notFound` (or, asked in English, its
    /// English twin) when the meeting has no answer.
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
        1. Odpowiedź musi wynikać wprost z konkretnych linii transkryptu albo notatek. Nie zgaduj, nie myl podobnych rzeczy i nie dodawaj wiedzy spoza spotkania.
        2. Po każdym zdaniu albo punkcie podaj czas linii, z której pochodzi informacja, w nawiasie kwadratowym, np. [12:34] albo [1:02:03]. Każdy czas w osobnym nawiasie, np. [4:52] [5:10]. Przepisz czas dokładnie z transkryptu.
        3. Odpowiadaj krótko, własnymi słowami: 1-3 zdania albo krótka lista z punktami "- ". Bez wstępu. Nie przepisuj linii transkryptu.
        4. Odpowiadaj w języku pytania: na pytanie po polsku po polsku, na pytanie po angielsku po angielsku.
        5. Gdy spotkanie nie mówi o tym wprost, napisz tylko jedno zdanie: \(MeetingAskPrompt.notFound)
        Na pytanie po angielsku to zdanie brzmi: \(MeetingAskPrompt.notFoundEnglish)

        Przykład (inne spotkanie):
        [2:10] Ewa: Stany magazynowe liczymy w programie Stock.
        Pytanie: Jakiego programu do faktur używają?
        Odpowiedź: \(MeetingAskPrompt.notFound)
        Pytanie: Gdzie liczą stany magazynowe?
        Odpowiedź: W programie Stock [2:10].
        """
    }

    /// Goes after the data of a "Zapytaj" call, after `</question>`.
    static func askReminder() -> String {
        "Odpowiedz krótko, w języku pytania, na pytanie z <question>, tylko na podstawie tego spotkania, z czasem linii w nawiasie kwadratowym po każdym zdaniu, np. [12:34]. Gdy spotkanie nie mówi o tym wprost, napisz tylko: \(MeetingAskPrompt.notFound)"
    }

    /// "Zapytaj wszystkie spotkania" (`LibraryAskPrompt.user`, then `libraryAskReminder`): a
    /// short answer from the excerpts and notes it is given, each claim cited as `[S1 12:34]`,
    /// `[S1]` or `[N1]` (`LibraryCitation`), exactly `LibraryAskPrompt.notFound` (or, asked in
    /// English, its English twin) when nothing has the answer.
    static func libraryAskSystem() -> String {
        """
        Odpowiadasz na pytanie o spotkania i notatki użytkownika, tylko na podstawie podanych danych.

        Dane:
        - "Dzisiaj": dzisiejsza data, do pytań typu "w zeszłym tygodniu".
        - <meetings>: spotkania S1, S2 i dalej. Każde zaczyna się od "S1: tytuł, data, uczestnicy". Może mieć <ai_notes> (notatki AI z czasami), <user_notes> i <excerpts> (fragmenty transkryptu, linie "[czas] Mówca: tekst", fragmenty rozdziela "...").
        - <notes>: notatki użytkownika N1, N2 i dalej, z tytułem i datą.
        - <question>: pytanie, na które odpowiadasz.

        Zasady:
        1. Odpowiedź musi wynikać wprost z tych danych. Nie zgaduj, nie myl podobnych rzeczy i nie dopisuj szczegółów, których w nich nie ma, np. roku.
        2. Po każdym zdaniu albo punkcie podaj źródło w nawiasie kwadratowym. Informacja z linii z czasem: numer spotkania i ten czas, np. [S1 12:34]. Samo [S1] tylko wtedy, gdy przy informacji nie ma czasu. Notatka N1: [N1]. Każde źródło w osobnym nawiasie.
        3. Gdy odpowiedź pochodzi z kilku spotkań, podaj przy każdej informacji datę albo tytuł spotkania.
        4. Odpowiadaj krótko: 1-4 zdania albo krótka lista z punktami "- ". Bez wstępu.
        5. Odpowiadaj w języku pytania: na pytanie po polsku po polsku, na pytanie po angielsku po angielsku.
        6. Gdy dane nie mówią o tym wprost, napisz tylko jedno zdanie: \(LibraryAskPrompt.notFound)
        Na pytanie po angielsku to zdanie brzmi: \(LibraryAskPrompt.notFoundEnglish)

        Przykład (inne dane):
        S2: Kampania jesienna, 3 października 2026 10:00
        <excerpts>
        [14:05] Ewa: Na kampanię dajemy dwadzieścia tysięcy.
        </excerpts>
        N1: Hasła, 2 października 2026 9:00
        Kod do sejfu: 4512.
        Pytanie: Ile wydajemy na kampanię i jaki jest kod do sejfu?
        Odpowiedź: Na kampanię jesienną 20 tys. zł [S2 14:05]. Kod do sejfu to 4512 [N1].
        """
    }

    /// Goes after the data of a "Zapytaj wszystkie spotkania" call, after `</question>`.
    static func libraryAskReminder() -> String {
        "Odpowiedz krótko, w języku pytania, na pytanie z <question>, tylko na podstawie tych danych, ze źródłem w nawiasie kwadratowym po każdym zdaniu: numer spotkania z czasem linii, np. [S1 12:34], albo notatka, np. [N1]. Gdy dane nie mówią o tym wprost, napisz tylko: \(LibraryAskPrompt.notFound)"
    }

    // MARK: Pieces

    /// "Sekcje, w tej kolejności:" with each heading and its guide.
    private static func sectionList(_ skeleton: MeetingNotesSkeleton) -> String {
        let lines = skeleton.sections.map { "- \($0.heading): \($0.guide)" }
        return (["Sekcje, w tej kolejności:"] + lines).joined(separator: "\n")
    }

    /// The exact answer layout: every heading with sample rows (two in the first section and
    /// two tasks of one person, so the model sees short points and one task per row). `[czas]`
    /// stands for a stamp so the model never copies a made-up time.
    private static func layout(_ skeleton: MeetingNotesSkeleton, timesFrom source: String = "z transkryptu") -> String {
        var lines = ["Wzór odpowiedzi (sam Markdown: nagłówki \"## \", punkty \"- \", po każdym punkcie [czas] zamieniony na czas \(source)):"]
        for (index, section) in skeleton.sections.enumerated() {
            lines.append("## \(section.heading)")
            if section.isTasks {
                lines.append("- Osoba: pierwsze zadanie, termin [czas]")
                lines.append("- Osoba: drugie zadanie tej samej osoby [czas]")
            } else if index == 0 {
                lines.append("- Pierwsza najważniejsza sprawa w jednym zdaniu [czas]")
                lines.append("- Druga najważniejsza sprawa w jednym zdaniu [czas]")
            } else {
                lines.append("- Jedna informacja w jednym zdaniu [czas]")
            }
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
