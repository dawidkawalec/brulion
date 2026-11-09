import Foundation

/// What the AI notes of one template hold: the kind of meeting in one line and the sections in
/// order, each with its exact Markdown heading (what `MeetingNotesDocument` shows, the five
/// with icons in `MeetingNotesSections` reused where they fit) and what goes under it. The text
/// is Polish whatever the UI language: it goes only into `MeetingPrompts`.
struct MeetingNotesSkeleton: Sendable, Equatable {
    struct Section: Sendable, Equatable {
        /// The heading without "## ".
        let heading: String
        /// What goes under it, one short Polish sentence for the model.
        let guide: String

        /// The bullets of "Zadania" are the checkable tasks (`MeetingNotesParser.actionItems`).
        var isTasks: Bool { heading == MeetingNotesSkeleton.tasksHeading }
    }

    /// The template id it belongs to (`MeetingTemplate.id`).
    let templateID: String
    /// The kind of meeting, one Polish sentence.
    let focus: String
    let sections: [Section]
    /// Template rules on top of the shared ones (e.g. what an interview never judges).
    var extraRules: [String] = []

    /// The heading whose bullets are tasks; the parser reads exactly this word.
    static let tasksHeading = "Zadania"

    /// The skeleton of a built-in template id; `general` for any other id (a custom template
    /// then adds its own instructions in `MeetingPrompts`).
    static func forTemplate(id: String) -> MeetingNotesSkeleton {
        all.first { $0.templateID == id } ?? general
    }

    /// One skeleton per `BuiltInMeetingTemplates.all`, same order.
    static let all: [MeetingNotesSkeleton] = [general, oneOnOne, standup, client, interview, lecture]

    private static let summary = Section(heading: "Podsumowanie", guide: "3-6 punktów: najważniejsze sprawy i wnioski.")
    private static let decisions = Section(heading: "Decyzje", guide: "co ustalono, zatwierdzono albo odrzucono.")
    private static let tasks = Section(
        heading: tasksHeading,
        guide: "każde zadanie jako \"Osoba: co zrobić, termin\"; termin tylko, gdy padł."
    )
    private static let openQuestions = Section(heading: "Otwarte pytania", guide: "sprawy bez odpowiedzi albo do sprawdzenia.")
    private static let nextSteps = Section(heading: "Następne kroki", guide: "co dalej: kolejne spotkanie, termin, kolejny etap.")

    static let general = MeetingNotesSkeleton(
        templateID: "general",
        focus: "spotkanie robocze.",
        sections: [summary, decisions, tasks, openQuestions, nextSteps]
    )

    static let oneOnOne = MeetingNotesSkeleton(
        templateID: "oneOnOne",
        focus: "rozmowa 1:1, zwykle przełożonego z członkiem zespołu.",
        sections: [
            summary,
            Section(heading: "Postępy", guide: "co się udało od ostatniej rozmowy."),
            Section(heading: "Problemy i blokery", guide: "trudności, ryzyka i prośby o pomoc."),
            Section(heading: "Informacja zwrotna", guide: "feedback w obie strony i cele rozwojowe."),
            tasks,
            nextSteps,
        ]
    )

    static let standup = MeetingNotesSkeleton(
        templateID: "standup",
        focus: "krótkie spotkanie zespołu (daily, standup).",
        sections: [
            Section(heading: "Podsumowanie", guide: "1-3 punkty: ogólny stan prac."),
            Section(heading: "Zrobione", guide: "\"Osoba: co skończyła\"."),
            Section(heading: "W planie", guide: "\"Osoba: nad czym pracuje teraz\"."),
            Section(heading: "Blokery", guide: "\"Osoba: co ją blokuje\" i kto może pomóc."),
            tasks,
        ]
    )

    static let client = MeetingNotesSkeleton(
        templateID: "client",
        focus: "rozmowa z klientem: sprzedaż, oferta, demo albo wdrożenie.",
        sections: [
            summary,
            Section(heading: "Potrzeby klienta", guide: "problemy, cele, wymagania i budżet, jeśli padł."),
            Section(heading: "Decyzje", guide: "ustalenia: zakres, ceny, terminy i warunki, które padły."),
            Section(heading: "Obiekcje i ryzyka", guide: "wątpliwości i zastrzeżenia klienta, ryzyka."),
            tasks,
            nextSteps,
        ]
    )

    static let interview = MeetingNotesSkeleton(
        templateID: "interview",
        focus: "rozmowa rekrutacyjna z kandydatem.",
        sections: [
            Section(heading: "Podsumowanie", guide: "kandydat, stanowisko i przebieg rozmowy w 2-4 punktach."),
            Section(heading: "Doświadczenie i umiejętności", guide: "projekty, technologie, staż, osiągnięcia."),
            Section(heading: "Oczekiwania kandydata", guide: "wynagrodzenie, forma współpracy, termin startu, tryb pracy, jeśli padły."),
            Section(heading: "Mocne strony", guide: "to, co kandydat pokazał w rozmowie."),
            Section(heading: "Wątpliwości", guide: "braki i sprawy do sprawdzenia."),
            nextSteps,
        ],
        extraRules: [
            "Opisuj tylko kompetencje i fakty z rozmowy. Nie oceniaj wieku, wyglądu, zdrowia, rodziny ani innych cech osobistych.",
        ]
    )

    static let lecture = MeetingNotesSkeleton(
        templateID: "lecture",
        focus: "wykład, webinar, szkolenie albo prezentacja.",
        sections: [
            Section(heading: "Podsumowanie", guide: "główna myśl i 3-6 najważniejszych wniosków."),
            Section(heading: "Główne tematy", guide: "\"Temat: najważniejsza treść\"."),
            Section(heading: "Pojęcia i definicje", guide: "\"Pojęcie: wyjaśnienie z wykładu\"."),
            Section(heading: "Przykłady i liczby", guide: "przykłady, dane i wyniki podane przez prowadzącego."),
            Section(heading: "Pytania i odpowiedzi", guide: "pytania słuchaczy i odpowiedzi prowadzącego."),
            Section(heading: tasksHeading, guide: "prace domowe, polecone materiały i rzeczy do zrobienia, jeśli padły."),
        ]
    )
}
