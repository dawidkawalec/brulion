import SwiftUI

/// "Zapytaj wszystkie spotkania": a glass sheet over Spotkania. The field at the bottom
/// (Return sends) asks `MeetingAskRuns.askLibrary`; the session's last answers stack above it,
/// oldest first (`LibraryAnswerView`), with a spinner "Szukam w spotkaniach..." while one runs.
/// A citation or a source opens that meeting (the caller closes the panel, selects the meeting
/// and jumps in "Transkrypt"). With no answers yet, three suggested questions. The answers live
/// while the app runs and are never stored.
@MainActor
struct LibraryAskPanel: View {
    let runs: MeetingAskRuns
    /// Opens a meeting, at that second of its transcript when given; the caller closes the panel.
    let onOpen: (_ meetingID: UUID, _ seconds: Double?) -> Void
    /// Opens a note in Notatki; the caller closes the panel.
    var onOpenNote: (UUID) -> Void = { _ in }
    /// Opens Modele, where the AI models and "Bielik w chmurze" are.
    let onAddKey: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private static let endID = "library-end"

    /// Suggested first questions, in the UI language (the answer follows the question's).
    static var suggestions: [String] {
        [
            String(localized: "Co ustaliliśmy w tym tygodniu?"),
            String(localized: "Jakie zadania są na mnie?"),
            String(localized: "Co klienci mówili o cenie?"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)
            conversation
                .padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 10) {
                if runs.libraryAnswers.isEmpty, runs.libraryPending == nil {
                    suggestionChips
                }
                inputRow
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 860, minHeight: 460, idealHeight: 620, maxHeight: 980)
        .background {
            DuskBackground(role: .sheet)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(GlassColor.textPrimary)
        .tint(GlassColor.accent)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassIconBadge(systemImage: "bubble.left.and.text.bubble.right", size: 34, tint: VTColor.brandViolet)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Zapytaj wszystkie spotkania")
                    .font(GlassFont.sectionTitle)
                    .foregroundStyle(GlassColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ToolCaption("Odpowiedź z Twoich spotkań, ze źródłami i odnośnikami do momentów rozmowy. Pytania znikają po zamknięciu Captylo.")
            }
            Spacer(minLength: 10)
            ToolIconButton("xmark", label: Text("Zamknij"), size: GlassTokens.Size.buttonHeightSmall) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if runs.libraryAnswers.isEmpty, runs.libraryPending == nil {
                        ToolCaption("Zapytaj o cokolwiek ze spotkań i notatek na tym Macu. Captylo znajdzie pasujące rozmowy i notatki i pokaże, skąd pochodzi odpowiedź.")
                    }
                    ForEach(runs.libraryAnswers) { answer in
                        LibraryAnswerView(answer: answer, onOpen: onOpen, onOpenNote: onOpenNote, onAddKey: onAddKey)
                    }
                    if let pending = runs.libraryPending {
                        VStack(alignment: .leading, spacing: 10) {
                            MeetingQuestionBubble(text: pending)
                            searchingLine
                        }
                        .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.endID)
                }
                .padding(.top, 6)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
            .mask(MeetingDetailView.edgeFade)
            .frame(maxHeight: .infinity)
            .animation(GlassMotion.press, value: runs.libraryPending)
            .onChange(of: runs.libraryAnswers.count) { _, _ in
                withAnimation(GlassMotion.spring) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            .onChange(of: runs.libraryPending) { _, _ in
                withAnimation(GlassMotion.spring) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
        }
    }

    private var searchingLine: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(GlassColor.textPrimary)
            Text("Szukam w spotkaniach...")
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textSecondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: Input

    private var suggestionChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chips
            }
            VStack(alignment: .leading, spacing: 8) {
                chips
            }
        }
    }

    private var chips: some View {
        ForEach(Self.suggestions, id: \.self) { suggestion in
            Button {
                send(suggestion)
            } label: {
                Text(verbatim: suggestion)
                    .lineLimit(1)
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .fixedSize()
        }
    }

    private var isBusy: Bool {
        runs.libraryPending != nil
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Zapytaj o wszystkie spotkania...", text: $draft)
                .textFieldStyle(.glass)
                .onSubmit { send(draft) }
                .disabled(isBusy)
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
            .fixedSize()
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            .help(Text("Zapytaj"))
            .accessibilityLabel(Text("Zapytaj"))
        }
    }

    private func send(_ question: String) {
        guard runs.askLibrary(question: question) != nil else { return }
        draft = ""
    }
}
