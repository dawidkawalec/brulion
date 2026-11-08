import SwiftUI

/// "Modele AI" on Modele > Zaawansowane: which Bielik serves each role and how long a model stays
/// in memory. "Korekta dyktowania": Bielik 1.5B (recommended), Minitron 7B (more accurate,
/// slower), 4.5B or the cloud; "Funkcje AI": Minitron 7B (recommended from 16 GB), 4.5B, 1.5B or
/// the cloud; "Zwalniaj model z pamięci po" N minutes without a request (10 by default).
/// "Zalecany" keeps the Mac's default plan (`AIRoleRouting`). Changes apply at once
/// (`AppState.applyAIRouting`).
@MainActor
struct AIRoleModelsPanel: View {
    @Bindable var settings: AppSettings
    let localAI: LocalAIServices
    let cloudReady: Bool

    private var routing: AIRoleRouting {
        settings.aiRoleRouting(hardware: localAI.hardware)
    }

    var body: some View {
        GlassPanel(spacing: 6) {
            GlassSectionHeader("Modele AI", systemImage: "cpu")
            ToolCaption("Który Bielik obsługuje każdą rolę. Zalecany wybór zależy od pamięci tego Maca.")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.bottom, 4)
            roleRow(
                .correction,
                subtitle: String(localized: "Czyszczenie dyktowania, poprawki transkryptu spotkań, tytuły notatek."),
                systemImage: "text.badge.checkmark"
            )
            roleRow(
                .features,
                subtitle: String(localized: "Pozostałe tryby AI, własne prompty, Przetwórz przez AI, notatki ze spotkań i Zapytaj."),
                systemImage: "sparkles"
            )
            GlassRowSeparator()
                .padding(.vertical, 6)
            idleRow
        }
    }

    // MARK: Roles

    private func roleRow(_ role: AIRole, subtitle: String, systemImage: String) -> some View {
        let current = routing.effectiveChoice(for: role, cloudReady: cloudReady)
        return VStack(alignment: .leading, spacing: 6) {
            GlassRow(title: Text(verbatim: LocalAIText.roleName(role)), subtitle: Text(verbatim: subtitle), systemImage: systemImage) {
                GlassMenuValue(menuTitle(role, current: current)) {
                    Picker(selection: binding(for: role)) {
                        Text("Zalecany dla tego Maca (\(LocalAIText.title(recommended(role))))")
                            .tag(AIModelChoice?.none)
                        Divider()
                        ForEach(AIModelChoice.options(for: role), id: \.self) { choice in
                            optionLabel(choice, role: role)
                                .tag(AIModelChoice?.some(choice))
                        }
                    } label: {
                        Text(verbatim: LocalAIText.roleName(role))
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .accessibilityLabel(Text(verbatim: LocalAIText.roleName(role)))
                .accessibilityValue(Text(verbatim: LocalAIText.title(current)))
            }
            ForEach(notes(role, current: current), id: \.self) { note in
                ToolStatusLine(text: note, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
    }

    /// The menu value: the model now serving the role, "(zalecany)" when the plan picked it.
    private func menuTitle(_ role: AIRole, current: AIModelChoice) -> String {
        let name = LocalAIText.title(current)
        guard settings.aiModelChoice(for: role) == nil else { return name }
        return String(localized: "\(name) (zalecany)")
    }

    /// What the plan would pick for the role on this Mac now.
    private func recommended(_ role: AIRole) -> AIModelChoice {
        AIRoleRouting(hardware: localAI.hardware).effectiveChoice(for: role, cloudReady: cloudReady)
    }

    @ViewBuilder
    private func optionLabel(_ choice: AIModelChoice, role: AIRole) -> some View {
        let name = LocalAIText.title(choice)
        if role == .correction, choice == .local(LocalModelCatalog.bielikMinitron7B.id) {
            Text("\(name): dokładniej, wolniej")
        } else if choice.localModel.map(localAI.hardware.needsMemoryWarning) == true {
            Text("\(name): może zabraknąć pamięci")
        } else {
            Text(verbatim: name)
        }
    }

    private func binding(for role: AIRole) -> Binding<AIModelChoice?> {
        Binding(
            get: { settings.aiModelChoice(for: role) },
            set: { settings.setAIModelChoice($0, for: role) }
        )
    }

    /// Why the pick will not work as it stands: the model is not downloaded, the cloud is off or
    /// has no key, or the model may not fit this Mac's memory.
    private func notes(_ role: AIRole, current: AIModelChoice) -> [String] {
        switch current {
        case .cloud:
            return cloudReady ? [] : [String(localized: "Brak klucza CloudFerro Sherlock: ta rola działa bez AI, dopóki nie dodasz klucza w zakładce Podstawowe (Gdzie działa Bielik).")]
        case .local(let id):
            var notes: [String] = []
            switch localAI.store.state(for: id) {
            case .installed:
                break
            case .downloading, .verifying:
                notes.append(String(localized: "Ten model jeszcze się pobiera. Do tego czasu ta rola działa bez AI."))
            case .notInstalled, .failed:
                notes.append(String(localized: "Ten model nie jest pobrany. Pobierz go w zakładce Podstawowe, do tego czasu ta rola działa bez AI."))
            }
            if let spec = current.localModel, localAI.hardware.needsMemoryWarning(spec) {
                notes.append(String(localized: "Na tym Macu ten model może nie zmieścić się w pamięci."))
            }
            return notes
        }
    }

    // MARK: Idle

    private var idleRow: some View {
        GlassRow(
            title: Text("Zwalniaj model z pamięci"),
            subtitle: Text("Po tylu minutach bez użycia Bielik oddaje pamięć RAM. Następne użycie uruchamia go ponownie, co trwa kilka sekund."),
            systemImage: "memorychip"
        ) {
            GlassMenuValue(idleLabel(settings.localAIIdleMinutes)) {
                Picker("Zwalniaj model z pamięci", selection: $settings.localAIIdleMinutes) {
                    ForEach(AppSettings.localAIIdleMinuteOptions, id: \.self) { minutes in
                        Text(verbatim: idleLabel(minutes)).tag(minutes)
                    }
                    if !AppSettings.localAIIdleMinuteOptions.contains(settings.localAIIdleMinutes) {
                        Text(verbatim: idleLabel(settings.localAIIdleMinutes)).tag(settings.localAIIdleMinutes)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .accessibilityLabel(Text("Zwalniaj model z pamięci"))
            .accessibilityValue(Text(verbatim: idleLabel(settings.localAIIdleMinutes)))
        }
    }

    private func idleLabel(_ minutes: Int) -> String {
        minutes == 0 ? String(localized: "Nigdy") : String(localized: "Po \(minutes) min")
    }
}
