import AppKit
import SwiftUI

/// "Modele" in two tabs (`SettingsLevel`). "Podstawowe": the speech engine (local model
/// download, language), "Gdzie działa Bielik" (`AILocationPanel`: this Mac, the AI features in
/// the cloud or everything in the cloud, with the CloudFerro Sherlock key), "Bielik na tym Macu"
/// (`LocalModelsPanel`: requirements, the Bielik downloads), the "Tryby AI" list
/// (`AIModesPanel`) and AI cleanup (master switch, where each role runs, test call).
/// "Zaawansowane": the model per role and the idle time (`AIRoleModelsPanel`) and the local usage
/// counter (`LocalAIStatsPanel`). "Podstawowe" always says where the AI runs, so nothing goes to
/// the cloud unseen.
@MainActor
struct ModelsView: View {
    @Environment(AppState.self) private var appState
    @State private var level: SettingsLevel = .basic

    var body: some View {
        ToolPage(subtitle: "Silnik, który zamienia mowę na tekst, i Bielik, który poprawia dyktowanie i obsługuje funkcje AI.") {
            SettingsLevelPicker(level: $level)
        } content: {
            switch level {
            case .basic: basic
            case .advanced: advanced
            }
        }
        .onAppear {
            if appState.isDesignPreview, let previewLevel = DesignPreviewData.settingsLevel() {
                level = previewLevel
            }
        }
    }

    private var showAdvanced: () -> Void {
        { withAnimation(GlassMotion.spring) { level = .advanced } }
    }

    @ViewBuilder
    private var basic: some View {
        @Bindable var settings = appState.settings

        GlassPanel {
            GlassSectionHeader("Silnik mowy", systemImage: "waveform")
            LocalModelSection(store: appState.modelStore, detector: appState.speechDetectorStatus)
            if appState.modelStore.hasLegacyParakeet {
                GlassRowSeparator()
                LegacyParakeetRow(store: appState.modelStore)
            }

            GlassRowSeparator()
            LanguagePicker(language: $settings.language)
        }

        AILocationPanel(
            keyStore: appState.keyStore,
            settings: settings,
            routing: appState.aiRoleRouting,
            onKeyChange: appState.cloudKeyDidChange
        )

        LocalModelsPanel(localAI: appState.localAI, routing: appState.aiRoleRouting, cloudReady: appState.isCloudAIReady)

        AIModesPanel(settings: settings, tester: appState.modeTester)

        GlassPanel {
            GlassSectionHeader("Poprawianie przez AI", systemImage: "sparkles")
            GlassToggleRow("Poprawiaj transkrypcję przez AI", systemImage: "wand.and.stars", isOn: $settings.aiEnabled)
            GlassRowSeparator()
            AIRouteSummary(
                routing: appState.aiRoleRouting,
                cloudReady: appState.isCloudAIReady,
                cloudModel: settings.cloudAIModel,
                cloudProvider: settings.cloudAIProvider,
                cloudCustomURL: settings.cloudAICustomURL,
                store: appState.localAI.store,
                onChange: showAdvanced
            )
            TestButtonRow(enhancer: appState.enhancer)
        }
    }

    @ViewBuilder
    private var advanced: some View {
        AIRoleModelsPanel(settings: appState.settings, localAI: appState.localAI, cloudReady: appState.isCloudAIReady)
        LocalAIStatsPanel(usage: appState.localAI.usage)
    }
}

// MARK: - Where the AI runs

/// "Podstawowe", AI cleanup: where each role runs (a model on this Mac, or the cloud), with
/// "Zmień" opening "Zaawansowane".
@MainActor
private struct AIRouteSummary: View {
    let routing: AIRoleRouting
    let cloudReady: Bool
    let cloudModel: String
    let cloudProvider: CloudAIProvider
    let cloudCustomURL: String
    let store: LocalAIModelStore
    let onChange: () -> Void

    var body: some View {
        GlassRow(title: Text("Gdzie działa AI"), subtitle: subtitle, systemImage: "brain") {
            Button("Zmień", action: onChange)
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
    }

    private var subtitle: Text {
        Text(verbatim: line(.correction)) + Text(verbatim: "\n") + Text(verbatim: line(.features))
    }

    /// "Korekta dyktowania: Bielik 1.5B na tym Macu" (or "nie pobrano", or the cloud).
    private func line(_ role: AIRole) -> String {
        let name = LocalAIText.roleName(role)
        switch routing.effectiveChoice(for: role, cloudReady: cloudReady) {
        case .cloud:
            let model = CloudAIRouteProvider.model(cloudModel, provider: cloudProvider)
            let provider = cloudProvider.displayName(customURL: cloudCustomURL)
            return cloudReady
                ? String(localized: "\(name): Bielik w chmurze \(provider) (\(model)), na Twój klucz")
                : String(localized: "\(name): Bielik w chmurze, wyłączony (bez AI)")
        case .local(let id):
            let model = LocalAIText.title(.local(id))
            return store.isInstalled(id)
                ? String(localized: "\(name): \(model) na tym Macu")
                : String(localized: "\(name): \(model), jeszcze nie pobrany (bez AI)")
        }
    }
}

// MARK: - Where Bielik runs

/// "Podstawowe": "Gdzie działa Bielik" (PRD 7.5). On this Mac (the default), the AI features in
/// the cloud, or everything in the cloud: Bielik 11B v3.0, the strongest Bielik, at a Polish
/// provider (`CloudAIProvider`: CloudFerro Sherlock by default, PCSS AI HUB) or on the user's own
/// OpenAI-compatible server, on the user's own key. The pick writes the cloud switch and the role
/// picks (`AppSettings.setAILocation`); a mix made in Zaawansowane selects no option. While the
/// cloud is on: "Dostawca", the server address (own server only), the provider's key (save,
/// test, remove), the model id and a plain note on where the text goes.
@MainActor
private struct AILocationPanel: View {
    let keyStore: KeyStore
    @Bindable var settings: AppSettings
    let routing: AIRoleRouting
    /// The key was saved or removed (`AppState.cloudKeyDidChange`).
    let onKeyChange: () -> Void

    @State private var key = ""
    @State private var isSaved = false
    @State private var status: (text: String, tone: InlineStatus.Tone)?
    @State private var isChecking = false

    private var location: AILocation? {
        routing.location(cloudEnabled: settings.cloudAIEnabled)
    }

    private var selection: Binding<AILocation?> {
        Binding(
            get: { location },
            set: { picked in
                if let picked {
                    settings.setAILocation(picked)
                }
            }
        )
    }

    var body: some View {
        GlassPanel {
            GlassSectionHeader("Gdzie działa Bielik", systemImage: "arrow.triangle.branch")
            GlassSegmentedPicker(
                selection: selection,
                segments: [
                    GlassSegment(AILocation?.some(.local), "Na tym Macu", systemImage: "laptopcomputer"),
                    GlassSegment(AILocation?.some(.featuresInCloud), "Funkcje AI w chmurze", systemImage: "cloud"),
                    GlassSegment(AILocation?.some(.allInCloud), "Wszystko w chmurze", systemImage: "cloud.fill"),
                ],
                fillsWidth: true
            )
            .accessibilityLabel(Text("Gdzie działa Bielik"))
            .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
            .padding(.bottom, 2)
            ToolCaption(text: description)
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
            if settings.cloudAIEnabled {
                cloudRows
            }
        }
        .onAppear(perform: loadKey)
        .onChange(of: settings.cloudAIProvider) {
            status = nil
            loadKey()
        }
    }

    private var provider: CloudAIProvider { settings.cloudAIProvider }

    /// The saved key of the current provider into the field.
    private func loadKey() {
        key = keyStore.get(provider.keyAccount) ?? ""
        isSaved = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the picked option does, in one or two sentences.
    private var description: Text {
        switch location {
        case .local?:
            Text("Korekta dyktowania i funkcje AI działają na Bielikach pobranych na ten Mac. Nic nie wychodzi z komputera, a AI działa też bez internetu.")
        case .featuresInCloud?:
            Text("Dyktowanie poprawia Bielik na tym Macu. Tryby AI, notatki ze spotkań i Zapytaj liczy Bielik 11B v3.0, najmocniejszy Bielik, w chmurze wybranego dostawcy, na Twój klucz.")
        case .allInCloud?:
            Text("Wszystko liczy Bielik 11B v3.0, najmocniejszy Bielik, w chmurze wybranego dostawcy, na Twój klucz. Każde dyktowanie poprawiane przez AI też idzie wtedy do chmury, a bez internetu AI nie działa.")
        case nil:
            Text("Własne ustawienie z zakładki Zaawansowane. Wybierz jedną z opcji, żeby je zastąpić.")
        }
    }

    @ViewBuilder
    private var cloudRows: some View {
        GlassRowSeparator()
        providerRow
        if provider == .custom {
            customURLRow
        }
        APIKeyField(
            title: keyTitle,
            placeholder: "Klucz API",
            key: $key,
            status: status,
            isChecking: isChecking,
            linkTitle: provider == .custom ? "Dostawcy Bielika" : "Jak założyć konto i klucz",
            linkURL: provider.setupURL,
            isSaved: isSaved,
            removeMessage: String(localized: "Bez klucza Bielik w chmurze nie zadziała, a funkcje ustawione na chmurę zostaną bez AI."),
            onSave: save,
            onVerify: verify,
            onRemove: remove
        )
        if !isSaved {
            ToolStatusLine(text: String(localized: "Bez zapisanego klucza funkcje ustawione na chmurę działają bez AI."), tone: .error)
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
        GlassRow(title: Text("Model"), subtitle: Text("Nazwa modelu u dostawcy"), systemImage: "brain") {
            TextField("Model", text: $settings.cloudAIModel, prompt: Text(verbatim: provider.defaultModel))
                .textFieldStyle(.glass)
                .frame(maxWidth: 260)
                .accessibilityLabel(Text("Model"))
        }
        ToolCaption(text: privacyNote)
            .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
    }

    private var providerRow: some View {
        GlassRow(title: Text("Dostawca"), subtitle: providerSubtitle, systemImage: "building.2") {
            GlassMenuValue(Self.providerTitle(provider)) {
                Picker("Dostawca", selection: Binding(get: { provider }, set: { settings.setCloudAIProvider($0) })) {
                    ForEach(CloudAIProvider.allCases, id: \.self) { option in
                        Text(verbatim: Self.providerTitle(option)).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .accessibilityLabel(Text("Dostawca"))
            .accessibilityValue(Text(verbatim: Self.providerTitle(provider)))
        }
    }

    @ViewBuilder
    private var customURLRow: some View {
        GlassRow(title: Text("Adres serwera"), subtitle: Text("Adres API zgodnego z OpenAI, np. https://ai.twojafirma.pl/v1"), systemImage: "link") {
            TextField("Adres serwera", text: $settings.cloudAICustomURL, prompt: Text(verbatim: "https://.../v1"))
                .textFieldStyle(.glass)
                .frame(maxWidth: 260)
                .accessibilityLabel(Text("Adres serwera"))
        }
        if settings.cloudAIConfiguration.baseURL == nil {
            ToolStatusLine(text: String(localized: "Wpisz pełny adres zaczynający się od https://."), tone: .error)
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
    }

    /// The provider as the "Dostawca" menu names it.
    static func providerTitle(_ provider: CloudAIProvider) -> String {
        switch provider {
        case .sherlock: String(localized: "CloudFerro Sherlock (Polska)")
        case .pcss: String(localized: "PCSS AI HUB (Poznań)")
        case .custom: String(localized: "Własny serwer zgodny z OpenAI")
        }
    }

    private var providerSubtitle: Text {
        switch provider {
        case .sherlock: Text("Polska chmura CloudFerro, płatność za użycie. Klucz tworzysz w konsoli Sherlock.")
        case .pcss: Text("Poznańskie Centrum Superkomputerowo-Sieciowe. Dla firm w abonamencie, dla naukowców i studentów bez opłat.")
        case .custom: Text("Dowolny serwer z API zgodnym z OpenAI, np. Bielik na serwerze Twojej firmy.")
        }
    }

    private var keyTitle: LocalizedStringKey {
        switch provider {
        case .sherlock: "Klucz CloudFerro Sherlock"
        case .pcss: "Klucz PCSS AI HUB"
        case .custom: "Klucz API serwera"
        }
    }

    private var privacyNote: Text {
        switch provider {
        case .sherlock:
            Text("Tekst idzie z Twojego Maca prosto do CloudFerro w Polsce, bez żadnego pośrednika. CloudFerro podaje, że nie przechowuje zapytań ani odpowiedzi. Klucz zostaje w pęku kluczy macOS.")
        case .pcss:
            Text("Tekst idzie z Twojego Maca prosto do PCSS w Poznaniu, bez żadnego pośrednika. Klucz zostaje w pęku kluczy macOS.")
        case .custom:
            Text("Tekst idzie z Twojego Maca prosto pod ten adres. Sprawdź, gdzie ten serwer przetwarza dane i czy ich nie przechowuje. Klucz zostaje w pęku kluczy macOS.")
        }
    }

    private func save() {
        do {
            try keyStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: provider.keyAccount)
            isSaved = true
            onKeyChange()
            status = (String(localized: "Klucz zapisany w pęku kluczy."), .success)
        } catch {
            status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
        }
    }

    private func remove() {
        do {
            try keyStore.delete(account: provider.keyAccount)
            key = ""
            isSaved = false
            onKeyChange()
            status = (String(localized: "Klucz usunięty."), .success)
        } catch {
            status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
        }
    }

    /// "Testuj połączenie": the typed key and model, saved or not, cloud on or off, at the
    /// provider's address.
    private func verify() {
        guard let baseURL = settings.cloudAIConfiguration.baseURL else {
            status = (String(localized: "Wpisz pełny adres zaczynający się od https://."), .error)
            return
        }
        isChecking = true
        let candidate = key
        let model = settings.cloudAIModel
        let provider = provider
        Task {
            switch await CloudAIRouteProvider.testConnection(
                key: candidate,
                model: model,
                provider: provider,
                client: ChatCompletionsClient(baseURL: baseURL)
            ) {
            case .success(let ms):
                status = (String(localized: "OK, Bielik w chmurze odpowiada (\(ms) ms)."), .success)
            case .failure(let error):
                status = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
            }
            isChecking = false
        }
    }
}

// MARK: - Local model

@MainActor
private struct LocalModelSection: View {
    let store: LocalModelStore
    /// The meeting voice detector that downloads with the model ("Wykrywanie mowy do spotkań").
    let detector: SpeechDetectorStatus

    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassRow(title: Text("Model lokalny"), subtitle: subtitle, systemImage: "cpu") {
                trailing
            }
            if case .downloading(let progress) = store.status {
                ToolProgressTrack(value: progress)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                    .padding(.trailing, GlassTokens.Padding.rowHorizontal)
                    .padding(.bottom, 6)
            }
            if case .failed(let message) = store.status {
                ToolStatusLine(text: message, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
            if let deleteError {
                ToolStatusLine(text: deleteError, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
            SpeechDetectorStatusLine(status: detector)
                .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
        }
        .alert("Usunąć model lokalny?", isPresented: $confirmDelete) {
            Button("Usuń", role: .destructive) {
                Task {
                    do {
                        try await store.delete()
                        deleteError = nil
                    } catch {
                        deleteError = String(localized: "Nie udało się usunąć modelu: \(error.localizedDescription)")
                    }
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Dyktowanie bez internetu i transkrypt spotkań na żywo przestaną działać, dopóki nie pobierzesz modelu ponownie (ok. 1,6 GB).")
        }
        .onAppear {
            store.refresh()
        }
    }

    private var subtitle: Text? {
        switch store.status {
        case .missing:
            return Text("Model nie jest pobrany (ok. 1,6 GB, działa bez internetu).")
        case .downloading(let progress):
            return Text("Pobieram model... \(Int((progress * 100).rounded()))%")
        case .optimizing:
            let text = Text("Optymalizuję model dla Twojego Maca (jednorazowo, do kilku minut)")
            guard let since = store.optimizingSince else { return text }
            // Counts up every second, so a long compile visibly moves on.
            return text + Text(verbatim: " · ") + Text(since, style: .timer).monospacedDigit()
        case .ready:
            return Text(verbatim: "Whisper large-v3 turbo")
        case .failed:
            return nil
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch store.status {
        case .missing:
            Button {
                Task { await store.download() }
            } label: {
                Label("Pobierz", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glass(.accent, size: .small, shape: .capsule))
        case .downloading(let progress):
            GlassBadge(title: Text(verbatim: "\(Int((progress * 100).rounded()))%"), systemImage: "arrow.down", tone: .accent)
        case .optimizing:
            // One indicator: the compile has no progress to report, the elapsed time is in the subtitle.
            ProgressView().controlSize(.small)
        case .ready:
            HStack(spacing: 10) {
                GlassBadge("Gotowy", systemImage: "checkmark", tone: .success)
                Button {
                    confirmDelete = true
                } label: {
                    Label {
                        Text("Usuń")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(GlassColor.destructive)
                    }
                }
                // Neutral glass with a red icon: a working model must not be the loudest thing
                // on the page, and the alert above still confirms the deletion.
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        case .failed:
            Button("Spróbuj ponownie") {
                Task { await store.download() }
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
    }
}

/// The Parakeet model of earlier versions, still on disk: offered for removal, never used.
@MainActor
private struct LegacyParakeetRow: View {
    let store: LocalModelStore

    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassRow(
                title: Text("Poprzedni model lokalny"),
                subtitle: Text("Brulion go już nie używa. Zajmuje ok. 460 MB."),
                systemImage: "archivebox"
            ) {
                Button {
                    confirmDelete = true
                } label: {
                    Label {
                        Text("Usuń")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(GlassColor.destructive)
                    }
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
            if let deleteError {
                ToolStatusLine(text: deleteError, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
        .alert("Usunąć poprzedni model?", isPresented: $confirmDelete) {
            Button("Usuń", role: .destructive) {
                do {
                    try store.deleteLegacyParakeet()
                    deleteError = nil
                } catch {
                    deleteError = String(localized: "Nie udało się usunąć modelu: \(error.localizedDescription)")
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Folder modelu jest współdzielony z poprzednią aplikacją do dyktowania. Po usunięciu ona również straci model i będzie musiała pobrać go ponownie.")
        }
    }
}

// MARK: - API key field

/// "Klucz ..." label, the glass secure field with Zapisz / Testuj połączenie and, while a key is
/// saved, "Usuń klucz" (asks first, `removeMessage` says what happens without it), then the status
/// line and the link to the provider's documentation.
@MainActor
private struct APIKeyField: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var key: String
    let status: (text: String, tone: InlineStatus.Tone)?
    let isChecking: Bool
    let linkTitle: LocalizedStringKey
    let linkURL: URL
    /// A key is saved in the Keychain (not only typed in the field).
    let isSaved: Bool
    let removeMessage: String
    let onSave: () -> Void
    let onVerify: () -> Void
    let onRemove: () -> Void

    @State private var confirmRemove = false

    private var isEmpty: Bool {
        key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "key")
                    .font(.system(size: GlassTokens.Size.rowIcon))
                    .foregroundStyle(GlassColor.icon)
                    .frame(width: GlassTokens.Size.rowIconColumn)
                    .accessibilityHidden(true)
                Text(title)
                    .font(GlassFont.rowTitle)
                    .foregroundStyle(GlassColor.textPrimary)
                Spacer()
                Link(destination: linkURL) {
                    HStack(spacing: 4) {
                        Text(linkTitle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                }
                .pointerStyleLinkIfAvailable()
            }
            .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
            .padding(.top, 6)
            HStack(spacing: 8) {
                GlassSecureField(placeholder, text: $key)
                Button("Zapisz", action: onSave)
                    .disabled(isEmpty)
                Button {
                    onVerify()
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Testuj połączenie")
                    }
                }
                .disabled(isEmpty || isChecking)
                if isSaved {
                    Button {
                        confirmRemove = true
                    } label: {
                        Label {
                            Text("Usuń klucz")
                        } icon: {
                            Image(systemName: "trash")
                                .foregroundStyle(GlassColor.destructive)
                        }
                    }
                    .disabled(isChecking)
                }
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            if let status, !isChecking {
                ToolStatusLine(text: status.text, tone: status.tone)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
        }
        .padding(.bottom, 4)
        .alert("Usunąć klucz?", isPresented: $confirmRemove) {
            Button("Usuń klucz", role: .destructive, action: onRemove)
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text(verbatim: removeMessage)
        }
    }
}

private extension View {
    /// Pointing-hand cursor on links (macOS 15+); plain on 14.
    @ViewBuilder
    func pointerStyleLinkIfAvailable() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

// MARK: - Language

@MainActor
private struct LanguagePicker: View {
    @Binding var language: String

    struct Option: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// "Automatycznie" first, then the 25 offered languages named in the UI language.
    static let options: [Option] = {
        let locale = AppLocale.current
        let named = TranscriptionLanguages.codes.map { code -> Option in
            let raw = locale.localizedString(forLanguageCode: code) ?? code
            return Option(code: code, name: raw.prefix(1).uppercased() + raw.dropFirst())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [Option(code: TranscriptionLanguages.auto, name: String(localized: "Automatycznie"))] + named
    }()

    private var currentName: String {
        Self.options.first { $0.code == language }?.name ?? language
    }

    var body: some View {
        GlassRow("Język transkrypcji", systemImage: "globe") {
            GlassMenuValue(currentName) {
                Picker("Język transkrypcji", selection: $language) {
                    ForEach(Self.options) { option in
                        Text(verbatim: option.name).tag(option.code)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .accessibilityLabel(Text("Język transkrypcji"))
            .accessibilityValue(Text(verbatim: currentName))
        }
    }
}

// MARK: - Test

/// "Testuj": one tiny call on the route the correction model uses now (local or cloud).
@MainActor
private struct TestButtonRow: View {
    let enhancer: Enhancer

    @State private var isTesting = false
    @State private var result: (text: String, tone: InlineStatus.Tone)?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                run()
            } label: {
                Label("Testuj", systemImage: "play.fill")
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .disabled(isTesting)
            if isTesting {
                ProgressView().controlSize(.small)
            } else if let result {
                ToolStatusLine(text: result.text, tone: result.tone)
            }
            Spacer()
        }
        .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
    }

    private func run() {
        isTesting = true
        let enhancer = enhancer
        Task {
            switch await enhancer.test(role: .correction) {
            case .success(let answer):
                result = (String(localized: "OK, \(answer.model), \(answer.ms) ms"), .success)
            case .failure(let error):
                result = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, .error)
            }
            isTesting = false
        }
    }
}
