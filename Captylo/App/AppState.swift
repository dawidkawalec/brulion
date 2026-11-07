import AppKit
import Foundation
import Observation
import os
import SwiftData

/// Composition root. Builds every service once and injects it; no singletons except `Log`.
/// `init` only constructs (safe for the headless debug commands); `startServices()` wires the
/// launch-time behaviour of a normal GUI run (tap, prewarm, retention, observers).
@MainActor
@Observable
final class AppState {
    let settings: AppSettings

    /// Files handed over by Finder "Otwórz za pomocą" before the main view existed (gotcha 63).
    var pendingOpenURLs: [URL] = []

    /// Parsed at launch from `CommandLine.arguments`; nil for a normal GUI launch.
    var debugCommand: DebugCommand?

    /// `--design-preview` run on fake services: never installs the hotkey tap or starts services.
    let isDesignPreview: Bool

    /// Shown once when the SwiftData store could not be opened (gotcha 80).
    private(set) var storeIsFallback: Bool

    // MARK: Services (order follows the dictation flow)

    @ObservationIgnored let stats: StatsTicker

    // Audio
    @ObservationIgnored let levelMeter: LevelMeter
    @ObservationIgnored let audioCapture: AudioCapture
    @ObservationIgnored let audioDevices: AudioDevices
    @ObservationIgnored let systemMute: SystemMute
    @ObservationIgnored let sounds: Sounds

    // Transcription
    @ObservationIgnored let localEngine: WhisperEngine
    @ObservationIgnored let modelStore: LocalModelStore
    @ObservationIgnored let livePreview: LivePreview
    @ObservationIgnored let keyStore: KeyStore
    @ObservationIgnored let transcriptionRouter: TranscriptionRouter

    // AI
    /// Bielik on this Mac: the downloads, the model servers, the usage counter, the memory tier.
    @ObservationIgnored let localAI: LocalAIServices
    /// Where every AI request goes (dictation, notes, history, meetings): see "AI routes" in `init`.
    @ObservationIgnored let aiRoutes: any AIRouteProviding
    @ObservationIgnored let enhancer: Enhancer
    /// Off the hot path ("Przetwórz przez AI", "Testuj tryb"): the file session, a 15 s
    /// deadline and the file token cap, with the same model as dictation.
    @ObservationIgnored let utilityEnhancer: Enhancer

    // Text and data
    @ObservationIgnored let dictionary: DictionaryStore
    /// Self-learning memory and rules (Słownik "Nauczone", Ustawienia "Ucz się z moich poprawek").
    @ObservationIgnored let learning: SelfLearning
    /// "Popraw" on selected text (⌃⌥⌘P and the Services menu).
    @ObservationIgnored let manualCorrection: ManualCorrection
    @ObservationIgnored let modelContainer: ModelContainer
    @ObservationIgnored let database: Database
    /// Full-text meeting search (FTS5), kept in step by `database`. Checked against the store and
    /// rebuilt when needed by `startServices()`; until it is ready search uses the store.
    @ObservationIgnored let meetingSearchIndex: MeetingSearchIndex

    // Meetings
    /// Itself `@Observable`: views read its phase, live transcript and issues directly.
    @ObservationIgnored let meetingRecorder: MeetingRecorder
    /// AI notes after a meeting.
    @ObservationIgnored let meetingNotes: MeetingNotesProcessor
    /// "Wygeneruj ponownie" in the "Notatki AI" tab: `meetingNotes.regenerate` with the picked
    /// template. Itself `@Observable` (which meetings are being written, finished runs).
    @ObservationIgnored let meetingNotesRuns: MeetingNotesRuns
    /// "Zapytaj" about one meeting and "Zapytaj wszystkie spotkania": `MeetingAsker` and
    /// `LibraryAsker` on `aiRoutes`. Itself `@Observable` (the question being answered per
    /// meeting, finished questions, the library session).
    @ObservationIgnored let meetingAskRuns: MeetingAskRuns
    /// The transcript actions in the details (AI fix, restore). Itself `@Observable`.
    @ObservationIgnored let meetingTranscriptRuns: MeetingTranscriptRuns
    /// "Zachowuj nagrania spotkań": the last post-processor, and a sweep at launch.
    @ObservationIgnored let meetingRetention: MeetingRetention
    /// The meeting voice detector: fetched with the speech model and at launch, shown under the
    /// model status in Modele and onboarding. Itself `@Observable`.
    @ObservationIgnored let speechDetectorStatus: SpeechDetectorStatus
    /// "Wykrywaj spotkania": asks to record when a call starts and to stop when it ends.
    /// Polls only after `startServices()` (never in the design preview or the test host).
    @ObservationIgnored let meetingDetector: MeetingDetector
    /// "Kalendarz": the event a recording belongs to (title, participants) and the upcoming
    /// ones. Itself `@Observable`. Refreshes only after `startServices()`; the design preview
    /// and the test host get a fixed list instead of EventKit (`AppStateOverrides.calendarEvents`).
    @ObservationIgnored let meetingCalendar: MeetingCalendar
    /// "Przypominaj przed spotkaniem": a toast with "Nagraj" shortly before a calendar event
    /// with a call link. Checks only after `startServices()`.
    @ObservationIgnored let calendarReminder: CalendarReminder

    // Output and UI
    @ObservationIgnored let textOutput: TextOutput
    @ObservationIgnored let recorderModel: RecorderModel
    @ObservationIgnored let widget: RecorderPanelController
    @ObservationIgnored let toasts: ToastCenter

    // Shell
    @ObservationIgnored let accessibility: AccessibilityWatcher
    @ObservationIgnored let permissions: Permissions
    @ObservationIgnored let launchAtLogin: LaunchAtLogin
    @ObservationIgnored let windowPresenter: WindowPresenter
    @ObservationIgnored let oldAppDetector: OldAppDetector

    // Dictation and hotkeys
    @ObservationIgnored let dictationController: DictationController
    @ObservationIgnored let hotkeyTap: HotkeyTap
    @ObservationIgnored let hotkeyController: HotkeyController
    @ObservationIgnored let historyActions: HistoryActions
    /// Notatki: AI modes, restore, delete, retry a transcription.
    @ObservationIgnored let noteActions: NoteActions
    /// Bumped after every note change made outside the editor (a voice note, an append, AI).
    @ObservationIgnored let notesTicker = StatsTicker()

    /// "Transkrypcja pliku" queue. Owned here so it survives the main window closing and can
    /// take Finder "Otwórz za pomocą" files before any view exists; the drop zone feeds it too.
    @ObservationIgnored let fileQueue: FileTranscriptionQueue
    /// "Importuj nagranie" in Notatki: recordings and messenger voice messages become voice notes.
    @ObservationIgnored let noteImportQueue: FileTranscriptionQueue


    /// Seam-typed views of the services for code that only needs the protocol.
    var coordinator: any RecorderCoordinator { dictationController }
    var levelSource: any LevelSource { levelMeter }

    /// "Testuj tryb" on the Modele screen.
    var modeTester: ModeTester {
        let dictionary = self.dictionary
        return ModeTester(enhancer: utilityEnhancer, vocabulary: { dictionary.data.vocabulary })
    }

    /// Bumped after every saved dictation; the dashboard reloads with `.task(id:)`.
    var statsVersion: Int { stats.version }
    /// Notatki reloads its list when this changes.
    var notesVersion: Int { notesTicker.version }

    /// A dictation or a meeting records, is starting or is still being processed: no relaunch
    /// ("Język aplikacji") until it is done.
    var isRecordingAnything: Bool {
        dictationController.phase != .idle || meetingRecorder.phase != .idle || meetingRecorder.isStarting
    }

    @ObservationIgnored private let hotkeyForwarder: HotkeyForwarder
    /// The AI routes run off the main actor, so the cloud route reads this snapshot of
    /// `settings.cloudAIEnabled` and `settings.cloudAIModel`.
    @ObservationIgnored private let cloudAISnapshot: OSAllocatedUnfairLock<CloudAIRouteProvider.Configuration>
    /// And this one of where each role runs (`settings.aiRoleRouting`).
    @ObservationIgnored private let aiRoutingSnapshot: OSAllocatedUnfairLock<AIRoleRouting>
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// ⌃⌥⌘M, registered while "Skrót ⌃⌥⌘M" is on (`applyMeetingShortcut`).
    @ObservationIgnored private var meetingShortcut: GlobalShortcut?
    /// ⌃⌥⌘P "Popraw", registered while its switch is on (`applyCorrectionShortcut`).
    @ObservationIgnored private var correctionShortcut: GlobalShortcut?
    /// ⌃⌥⌘N, a voice note, registered while its switch is on (`applyNoteShortcut`).
    @ObservationIgnored private var noteShortcut: GlobalShortcut?
    /// Services menu "Popraw w Szpaku"; set in `startServices`.
    @ObservationIgnored private var correctionService: CorrectionServiceProvider?
    @ObservationIgnored private var servicesStarted = false

    init(settings: AppSettings = AppSettings(), overrides: AppStateOverrides = .live) {
        self.settings = settings
        isDesignPreview = overrides.isDesignPreview
        let stats = StatsTicker()
        self.stats = stats

        // Audio
        let level = LevelMeter()
        levelMeter = level
        audioCapture = AudioCapture(level: level)
        audioDevices = AudioDevices(settings: settings)
        systemMute = SystemMute(settings: settings, defaults: overrides.systemMuteDefaults ?? .standard)
        sounds = Sounds(settings: settings)

        // Transcription
        let engine = WhisperEngine()
        localEngine = engine
        modelStore = LocalModelStore(engine: engine, pinnedStatus: overrides.pinnedModelStatus)
        livePreview = LivePreview(engine: engine)
        let keyStore = overrides.keyStore ?? KeyStore()
        self.keyStore = keyStore

        // Transcription is local only (Whisper on this Mac).
        transcriptionRouter = TranscriptionRouter(
            local: engine,
            localInstalled: { WhisperEngine.isDownloaded },
            localReady: { engine.state == .ready }
        )

        // MARK: AI routes (the one place)
        // Every AI request asks `aiRoutes` for its role (`AIRole`): dictation, files, notes,
        // history, the style profile and the meeting AI. `AIRoleRouteProvider` reads where the
        // role runs (Modele > Zaawansowane, else the Mac's default plan by its memory) and asks
        // the local model server (llama-server on 127.0.0.1, `LocalAIRouteProvider`) or "Bielik
        // w chmurze" (CloudFerro Sherlock on the user's key, off by default). No route = no AI:
        // the raw text is pasted. The design preview and the test host never start a server.
        let hardware = HardwareProfile.current
        let routing = settings.aiRoleRouting(hardware: hardware)
        let localAI = LocalAIServices(
            root: overrides.localAIRoot ?? AppPaths.dataDirectory,
            startsServers: overrides.startsLocalAI,
            pinnedStates: overrides.pinnedLocalAIStates,
            routing: routing,
            idleTimeout: settings.localAIIdleTimeout,
            hardware: hardware
        )
        self.localAI = localAI
        let routingSnapshot = OSAllocatedUnfairLock(initialState: routing)
        aiRoutingSnapshot = routingSnapshot
        let cloudSnapshot = OSAllocatedUnfairLock(initialState: settings.cloudAIConfiguration)
        cloudAISnapshot = cloudSnapshot
        let cloudRoutes = CloudAIRouteProvider(keyStore: keyStore, configuration: { cloudSnapshot.withLock { $0 } })
        let routes: any AIRouteProviding = AIRoleRouteProvider(
            local: LocalAIRouteProvider(endpoints: localAI.service),
            cloud: cloudRoutes,
            routing: { routingSnapshot.withLock { $0 } }
        )
        aiRoutes = routes

        // AI on the dictation path and off it ("Przetwórz przez AI", "Testuj tryb", the style
        // profile: the file session, 15 s, the file token cap). Both stretch the limit with the
        // input (PRD 5, `LocalDeadline`); only the dictation path counts its corrections.
        let usageStats = localAI.usage
        enhancer = Enhancer(
            routes: routes,
            adaptsDeadline: true,
            usage: { event in Task { await usageStats.record(event) } }
        )
        utilityEnhancer = Enhancer(
            routes: routes,
            session: HTTP.fileLLMSession,
            deadline: FileTranscriptionQueue.enhancementDeadline,
            tokenCap: FileTranscriptionQueue.enhancementTokenCap,
            adaptsDeadline: true
        )

        // Text and data
        dictionary = DictionaryStore(fileURL: overrides.dictionaryURL ?? AppPaths.dictionaryJSON, paragraphs: settings.paragraphs)
        let (container, isFallback) = overrides.modelContainer.map { ($0, false) } ?? Store.makeContainer()
        modelContainer = container
        storeIsFallback = isFallback
        // The real index file only next to the real store: an overridden or fallback store gets
        // an in-memory index (a fallback store would otherwise wipe the real index).
        let searchIndexURL = overrides.searchIndexURL
            ?? ((overrides.modelContainer == nil && !isFallback) ? AppPaths.searchIndex : nil)
        let searchIndex = MeetingSearchIndex(url: searchIndexURL)
        meetingSearchIndex = searchIndex
        let database = Database(modelContainer: container, searchIndex: searchIndex)
        self.database = database

        // Meetings: nothing records until the user starts a meeting (the design preview and the
        // test host never do), and never without the speech model on disk. The VAD loads once,
        // on the first meeting, and serves both tracks. After a meeting stops, in the background:
        // speaker labels (macOS 15+; the diarizer loads on first use), the AI fixes of the
        // transcript (setting, the correction model) and the AI notes (the features model), both
        // on `aiRoutes`, so the notes see "Mówca N" and the fixed text. Without an AI route the
        // notes keep the reason ("AI jest niedostępne...") for the "Notatki AI" tab.
        let meetingVAD = SpeechDetectorCache { try await FluidSpeechDetector.load() }
        let detectorStatus = SpeechDetectorStatus(load: { try await meetingVAD.prewarm() }, pinned: overrides.pinnedSpeechDetectorStatus)
        speechDetectorStatus = detectorStatus
        // The voice detector comes with the speech model: fetched right after its download.
        modelStore.onDownloaded = {
            Task { await detectorStatus.prewarm() }
        }
        let dictionaryStore = dictionary
        let meetingVocabulary: @Sendable () async -> [String] = { @MainActor in dictionaryStore.data.vocabulary }
        let speakerLabels = SpeakerLabelProcessor(
            database: database,
            diarizer: FluidSpeakerDiarizer(),
            isAllowed: { true },
            trackURL: { id, track in AppPaths.meetingTrackURL(id, track: track) }
        )
        let meetingCorrection = MeetingCorrectionProcessor(
            database: database,
            corrector: MeetingTranscriptCorrector(routes: routes),
            isEnabled: { @MainActor in settings.meetingsAICorrection },
            vocabulary: meetingVocabulary
        )
        let meetingSummarizer = MeetingSummarizer(routes: routes)
        // A long meeting is written in parts on a local model: its progress reaches the
        // "Notatki AI" tab through the runs, which are built after the processor.
        let notesProgress = MeetingNotesRuns.Sink()
        let meetingNotes = MeetingNotesProcessor(
            database: database,
            summarizer: meetingSummarizer,
            isAllowed: { true },
            onProcessed: { Task { await usageStats.record(.meetingProcessed) } },
            onProgress: notesProgress.reporter()
        )
        self.meetingNotes = meetingNotes
        let notesRuns = MeetingNotesRuns { id, templateID in
            await meetingNotes.regenerate(meetingID: id, templateID: templateID)
        }
        notesProgress.runs = notesRuns
        meetingNotesRuns = notesRuns
        let meetingAsker = MeetingAsker(database: database, routes: routes)
        let libraryAsker = LibraryAsker(database: database, index: searchIndex, routes: routes)
        // The design preview never reaches the network: its questions are seeded.
        let asksOffline = overrides.isDesignPreview
        meetingAskRuns = MeetingAskRuns(
            ask: { id, question in
                guard !asksOffline else { return }
                _ = await meetingAsker.ask(meetingID: id, question: question)
            },
            askLibrary: { question in
                guard !asksOffline else { return nil }
                return await libraryAsker.ask(question: question)
            }
        )
        // Notes written from an older transcript would sit next to the new one (also in the
        // export), so a transcript that changed rewrites them with the same template. Meetings
        // without notes stay without: that is the user's "Napisz notatki".
        let refreshNotes: @Sendable (UUID) async -> Void = { id in
            guard let meeting = try? await database.meeting(id: id), meeting.summary != nil else { return }
            await meetingNotes.regenerate(meetingID: id, templateID: meeting.summaryTemplateID)
        }
        meetingTranscriptRuns = MeetingTranscriptRuns { id, kind in
            switch kind {
            case .aiFix:
                if await meetingCorrection.run(meetingID: id) {
                    await refreshNotes(id)
                }
            case .restore:
                do {
                    try await database.restoreOriginalTranscript(meetingID: id)
                    await refreshNotes(id)
                } catch {
                    Log.data.error("Meeting transcript could not be restored: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // Last: the speaker labels read the track files, the AI notes do not need them.
        let meetingRetention = MeetingRetention(
            database: database,
            policy: { await MainActor.run { settings.meetingAudioRetention } },
            folder: { AppPaths.meetingFolder($0) }
        )
        self.meetingRetention = meetingRetention
        // The calendar: never EventKit for the design preview or the test host.
        let calendarSource: any CalendarEventSource
        if let events = overrides.calendarEvents {
            calendarSource = FixedCalendarSource(events: events)
        } else {
            calendarSource = EventKitSource()
        }
        let meetingCalendar = MeetingCalendar(source: calendarSource, isOn: { settings.meetingsCalendar })
        self.meetingCalendar = meetingCalendar
        let mute = systemMute
        meetingRecorder = MeetingRecorder(environment: MeetingEnvironment(
            makeMic: { MeetingMicCapture(voiceProcessing: settings.meetingsVoiceProcessing) },
            makeSystem: { SystemAudioTap() },
            makeTranscriber: { id, language, save in
                MeetingTranscriber(meetingID: id, language: language, engine: engine,
                                   detectorFactory: { _ in try await meetingVAD.detector() }, save: save)
            },
            database: database,
            trackURL: { id, track in AppPaths.meetingTrackURL(id, track: track) },
            expectingSystemAudio: { CoreAudioProcesses.anyOtherProcessPlaying() },
            language: { settings.transcriptionLanguage },
            setMuteSuppressed: { mute.isSuppressed = $0 },
            postProcessors: [speakerLabels, meetingCorrection, meetingNotes, meetingRetention],
            // After a quit mid-processing: only the AI steps still missing on the row, then
            // retention. Never the diarizer (a crash there would repeat at every launch).
            resumeProcessors: [
                MeetingResumeStep(database: database, isDone: { $0.transcriptAIModel != nil }, processor: meetingCorrection),
                MeetingResumeStep(database: database, isDone: { $0.summary != nil }, processor: meetingNotes),
                meetingRetention,
            ],
            outputUsesBuiltInSpeakers: { CoreAudioProcesses.defaultOutputIsBuiltInSpeakers() },
            speechModelReady: { WhisperEngine.isDownloaded },
            currentEvent: { meetingCalendar.currentEvent() }
        ))

        // Output and UI
        textOutput = TextOutput()
        recorderModel = RecorderModel(level: level)
        let widget = RecorderPanelController(model: recorderModel)
        self.widget = widget
        toasts = ToastCenter(sounds: sounds, anchor: { [weak widget] in widget?.widgetFrame })

        // Self-learning: `learning.json` always sits next to the dictionary, so the test host and
        // the design preview (temp dictionary) never touch the user's memory.
        let learningURL = overrides.dictionaryURL.map { $0.deletingLastPathComponent().appending(path: "learning.json") }
            ?? AppPaths.learningJSON
        // Style distillation goes through the utility enhancer (file session, 15 s, no UsageStat),
        // never the dictation hot path, and only while AI is on.
        let styleEnhancer = utilityEnhancer
        let learning = SelfLearning(
            settings: settings,
            dictionary: dictionary,
            store: LearningStore(fileURL: learningURL),
            toasts: toasts,
            distill: { system, input in
                guard settings.aiEnabled else { return nil }
                // The style profile runs in the background on the stronger model (PRD 7.3).
                let job = EnhancementJob(systemPrompt: system, kind: .rewrite, role: .features, deadline: .seconds(15))
                if case .enhanced(let text, _, _) = await styleEnhancer.enhance(input, job: job) {
                    return text
                }
                return nil
            }
        )
        self.learning = learning
        let correction = ManualCorrection(
            learning: learning,
            output: textOutput,
            toasts: toasts,
            outputSettings: { settings.outputSettings }
        )
        manualCorrection = correction

        // Shell
        let accessibility = AccessibilityWatcher(pinnedTrust: overrides.pinnedAccessibilityTrust)
        self.accessibility = accessibility
        permissions = Permissions(accessibility: accessibility)
        launchAtLogin = LaunchAtLogin()
        let presenter = WindowPresenter(settings: settings)
        windowPresenter = presenter
        oldAppDetector = OldAppDetector()
        meetingDetector = MeetingDetector(
            recorder: meetingRecorder,
            toasts: toasts,
            isEnabled: { settings.meetingsAutoDetect },
            openMeetings: { presenter.openMain(section: .spotkania) },
            currentEvent: { meetingCalendar.currentEvent() }
        )
        let detector = meetingDetector
        calendarReminder = CalendarReminder(
            recorder: meetingRecorder,
            toasts: toasts,
            events: { meetingCalendar.isEnabled ? meetingCalendar.upcoming : [] },
            isEnabled: { settings.meetingsCalendarReminder },
            minutesBefore: { settings.meetingsCalendarReminderMinutes },
            lastDetectorOffer: { detector.lastOfferAt },
            openMeetings: { presenter.openMain(section: .spotkania) }
        )

        // Hotkeys: the tap comes first, the controller resolves through the forwarder.
        let forwarder = HotkeyForwarder()
        hotkeyForwarder = forwarder
        let tap = HotkeyTap { event in
            MainActor.assumeIsolated {
                forwarder.handle(event)
            }
        }
        hotkeyTap = tap
        tap.setHotkey(settings.hotkey)

        // Notes (before the dictation: a voice note take names its note through them)
        let notesTicker = notesTicker
        let actions = NoteActions(
            database: database,
            router: transcriptionRouter,
            enhancer: utilityEnhancer,
            vocabulary: { dictionaryStore.data.vocabulary },
            processor: { dictionaryStore.processor },
            engine: { settings.sttEngine },
            language: { settings.transcriptionLanguage },
            titleAI: { settings.aiEnabled },
            didChange: { notesTicker.bump() }
        )
        noteActions = actions

        // Dictation
        dictationController = DictationController(env: DictationEnvironment(
            settings: settings,
            devices: audioDevices,
            capture: audioCapture,
            sounds: sounds,
            systemMute: systemMute,
            router: transcriptionRouter,
            livePreview: livePreview,
            enhancer: enhancer,
            dictionary: dictionary,
            learning: learning,
            pasteWatcher: EditWatcher(
                learning: learning,
                isEnabled: { settings.learningEnabled },
                userExcluded: { settings.learningExcludedApps }
            ),
            output: textOutput,
            widget: widget,
            toasts: toasts,
            recorderModel: recorderModel,
            database: database,
            persistsHistory: !isFallback,
            isLocalModelInstalled: { WhisperEngine.isDownloaded },
            isLocalModelReady: { engine.state == .ready },
            setEscapeArmed: { tap.setEscapeArmed($0) },
            didSave: {
                stats.bump()
                let days = settings.audioRetentionDays
                Task { await Retention.run(days: days, database: database) }
            },
            didDeliver: { localAI.record(.dictation) },
            // Never over the onboarding: its Wypróbuj step shows the missing model itself, and
            // the main window must not jump in front of it (the error toast still appears).
            openModels: {
                guard !OnboardingPresenter.isShowing else { return }
                presenter.openMain(section: .modele)
            },
            openAccessibilitySettings: { accessibility.openSystemSettings() },
            openMicrophoneSettings: { MicrophonePermission.openSystemSettings() },
            openNote: { presenter.openNote(id: $0) },
            noteSaved: { id in
                notesTicker.bump()
                Task { await actions.ensureTitle(noteID: id) }
            }
        ))
        hotkeyController = HotkeyController(tap: tap, coordinator: dictationController, toasts: toasts)
        forwarder.controller = hotkeyController
        // "Popraw" waits while a take runs, and a take that starts closes its panel.
        let dictation = dictationController
        correction.isDictating = { [weak dictation] in (dictation?.phase ?? .idle) != .idle }
        forwarder.willHandle = { [weak correction] in correction?.cancel() }
        // Expanded widget: microphone and language menus, output switches, "Pauza".
        recorderModel.controls = RecorderAppControls(
            settings: settings,
            devices: audioDevices,
            coordinator: dictationController,
            openModes: {
                guard !OnboardingPresenter.isShowing else { return }
                presenter.openMain(section: .modele)
            }
        )
        historyActions = HistoryActions(
            database: database,
            output: textOutput,
            router: transcriptionRouter,
            enhancer: utilityEnhancer,
            vocabulary: { dictionaryStore.data.vocabulary },
            didChange: { stats.bump() }
        )
        fileQueue = FileTranscriptionQueue(services: .make(
            settings: settings,
            router: transcriptionRouter,
            dictionary: dictionary,
            database: database,
            routes: routes,
            stats: stats,
            persistsHistory: !isFallback
        ))
        noteImportQueue = FileTranscriptionQueue(services: .makeForNotes(
            settings: settings,
            router: transcriptionRouter,
            vocabulary: { dictionaryStore.data.vocabulary },
            processor: { dictionaryStore.processor },
            database: database,
            didSave: { notesTicker.bump() },
            onCreated: { id in Task { await actions.ensureTitle(noteID: id) } }
        ))

        let controller = dictationController
        audioCapture.onDeviceDied = {
            Task { @MainActor in
                Log.audio.notice("Input device died, stopping the take")
                await controller.stop()
            }
        }
    }

    // MARK: Launch

    /// Everything a GUI launch does beyond construction. Idempotent.
    func startServices() {
        // The design preview runs next to a real Captylo: a second tap would double every take.
        guard !servicesStarted, !isDesignPreview else { return }
        servicesStarted = true

        // A crash or Force Quit during a take never ran `restore()`: undo that mute first.
        systemMute.recoverAfterAbnormalExit()

        do {
            try AppPaths.ensureDirectories()
        } catch {
            Log.data.error("Could not create the data directories: \(error.localizedDescription, privacy: .public)")
        }
        // Before the first store write of this run: every change carries this Mac's id (sync).
        DeviceIdentity.load(from: AppPaths.dataDirectory)

        // A crash or quit mid-meeting left its row "recording": it becomes "Przerwane" with the
        // segments it saved. A meeting started right after launch waits for this.
        meetingRecorder.recoverInterruptedMeetings()

        // Search index: opened, checked against the store and rebuilt when missing, old, corrupt
        // or out of step, on its own queue. Search uses the store until it is ready.
        let searchIndex = meetingSearchIndex
        let indexedDatabase = database
        Task.detached(priority: .utility) {
            await searchIndex.prepare(database: indexedDatabase)
        }

        // The cloud key: read once on the Keychain queue so the hot path hits the cache.
        keyStore.preload([KeyStore.Account.cloudFerroSherlock])

        // Hotkey tap: installed now when trusted, otherwise on the Accessibility flip (gotcha 38).
        // Revoking the grant kills the tap but leaves its port behind, so a re-grant always builds
        // a fresh one (otherwise `install()` sees the dead port and does nothing).
        let tap = hotkeyTap
        accessibility.onGranted = { [weak self] in
            tap.uninstall()
            tap.install()
            self?.permissions.refresh()
        }
        accessibility.onRevoked = { [weak self] in
            tap.uninstall()
            self?.permissions.refresh()
        }
        if accessibility.isTrusted {
            tap.install()
        }
        accessibility.start()

        // Audio unit prewarm at launch and on every route change (gotcha "prewarm").
        audioDevices.onRouteChange = { [weak self] in
            self?.prewarmCapture()
        }
        prewarmCapture()

        // Local model: background load at launch and after sleep. The meeting voice
        // detector follows it once the model is installed (its first load downloads it).
        let store = modelStore
        let detectorStatus = speechDetectorStatus
        Task {
            await store.prewarm()
            if store.isInstalled {
                await detectorStatus.prewarm()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.modelStore.prewarm() }
                self.prewarmCapture()
            }
        }

        // Retention (P1, 0 = off).
        let days = settings.audioRetentionDays
        let database = self.database
        let sweepOrphans = !storeIsFallback
        Task {
            await Retention.run(days: days, database: database)
            // The in-memory fallback store has no rows: sweeping against it would delete everything.
            if sweepOrphans {
                await Retention.sweepOrphans(database: database)
                await Retention.sweepNoteOrphans(database: database)
            }
        }
        // Meeting audio ("Zachowuj nagrania spotkań"): goes by the rows, so the in-memory
        // fallback store (no rows) removes nothing. Every finished meeting sweeps again.
        let meetingRetention = self.meetingRetention
        Task { await meetingRetention.sweep() }

        windowPresenter.start()
        oldAppDetector.start()
        applyMeetingShortcut()
        applyCorrectionShortcut()
        applyNoteShortcut()
        // Services menu "Popraw w Szpaku" (`NSServices` in Info.plist).
        let service = CorrectionServiceProvider(correction: manualCorrection)
        correctionService = service
        NSApp.servicesProvider = service
        NSUpdateDynamicServices()
        // Always polling: it reads "Wykrywaj spotkania" every time and idles while it is off,
        // so switching it on in Ustawienia works without a relaunch.
        meetingDetector.start()
        // Same for "Kalendarz": every refresh reads the switch and idles (no EventKit read) while off.
        meetingCalendar.start()
        // And the reminder: it reads both switches on every check.
        // Each prompt knows about the other: one meeting never gets two "Nagrać?" toasts.
        meetingDetector.recentReminder = { [weak self] in self?.calendarReminder.lastReminderAt }
        calendarReminder.start()
        observeSettings()

        if storeIsFallback {
            showStoreFallbackAlert()
        }

        // Files Finder handed over during launch, before the data directories existed.
        drainPendingOpenURLs()
    }

    /// Quit path (`applicationWillTerminate`): synchronous only. Unmutes the output we muted
    /// (nothing else would), drops a live take and restores the user's clipboard early. A meeting
    /// that still records gets its track files finalized; the next launch marks it interrupted.
    func stopServices() {
        meetingDetector.stop()
        calendarReminder.stop()
        meetingCalendar.stop()
        meetingRecorder.abortForTermination()
        systemMute.restore()
        dictationController.abortForTermination()
        textOutput.flushPendingRestore()
        hotkeyTap.uninstall()
        meetingShortcut?.unregister()
        correctionShortcut?.unregister()
        noteShortcut?.unregister()
        accessibility.stop()
        // The model servers end with the app (their pid files let the next launch catch any
        // that outlived a crash).
        localAI.terminateAllNow()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func bumpStats() {
        stats.bump()
    }

    /// ⌃⌥⌘M and "Nagraj spotkanie" in the menu bar: ends the meeting that records, otherwise
    /// opens Spotkania first (a meeting never records without its live bar on screen) and starts one.
    func toggleMeetingRecording() {
        let recorder = meetingRecorder
        if recorder.isRecording {
            Task { await recorder.stop() }
            return
        }
        guard recorder.phase == .idle, !recorder.isStarting else { return }
        windowPresenter.openMain(section: .spotkania)
        Task { await recorder.start() }
    }

    /// Registers or drops ⌃⌥⌘M to match the setting. Only after `startServices`: the design
    /// preview and the test host never take the combo from the running app.
    private func applyMeetingShortcut() {
        guard servicesStarted else { return }
        if settings.meetingsShortcut {
            if meetingShortcut == nil {
                meetingShortcut = GlobalShortcut(GlobalShortcut.meeting) { [weak self] in
                    self?.toggleMeetingRecording()
                }
            }
            meetingShortcut?.register()
        } else {
            meetingShortcut?.unregister()
        }
    }

    /// Registers or drops ⌃⌥⌘P to match the setting, like `applyMeetingShortcut`.
    private func applyCorrectionShortcut() {
        guard servicesStarted else { return }
        if settings.learningFixShortcut {
            if correctionShortcut == nil {
                correctionShortcut = GlobalShortcut(GlobalShortcut.correction) { [weak self] in
                    self?.manualCorrection.start()
                }
            }
            correctionShortcut?.register()
        } else {
            correctionShortcut?.unregister()
        }
    }

    /// ⌃⌥⌘N and "Nowa notatka głosowa" in the menu bar: starts a voice note while idle, stops the
    /// take that records (of any kind, as what it is), ignored while a take is transcribed.
    func toggleVoiceNote() {
        let controller = dictationController
        switch TakeDestination.forShortcutPress(phase: controller.phase) {
        case .start(let destination):
            Task { await controller.start(destination: destination) }
        case .stop:
            Task { await controller.stop() }
        case .busy:
            toasts.showInfo(String(localized: "Szpak jeszcze przepisuje poprzednie nagranie. Spróbuj za chwilę."))
        }
    }

    /// Registers or drops ⌃⌥⌘N to match the setting, like `applyMeetingShortcut`.
    private func applyNoteShortcut() {
        guard servicesStarted else { return }
        if settings.notesShortcut {
            if noteShortcut == nil {
                noteShortcut = GlobalShortcut(GlobalShortcut.note) { [weak self] in
                    self?.toggleVoiceNote()
                }
            }
            noteShortcut?.register()
        } else {
            noteShortcut?.unregister()
        }
    }

    /// Finder "Otwórz za pomocą" (gotcha 63). A cold start stashes the URLs until
    /// `startServices()` has created the data directories; later opens go straight to the queue.
    func openFiles(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
        guard servicesStarted else { return }
        drainPendingOpenURLs()
    }

    /// "Uruchom ponownie" after a new "Język aplikacji". Never while something records, and never
    /// from the design preview: a plain launch of that binary starts a second hotkey tap.
    func relaunchForLanguage() {
        guard !isDesignPreview, !isRecordingAnything else { return }
        Log.app.info("Relaunching for a new app language")
        AppRelauncher.relaunch()
    }

    private func drainPendingOpenURLs() {
        let urls = pendingOpenURLs
        guard !urls.isEmpty else { return }
        pendingOpenURLs.removeAll()
        fileQueue.add(urls: urls)
        windowPresenter.openMain(section: .plik)
    }

    // MARK: Helpers

    /// Builds the audio engine for the resolved device so the first take starts in a few ms.
    private func prewarmCapture() {
        guard MicrophonePermission.isAuthorized, dictationController.phase == .idle else { return }
        guard let device = audioDevices.resolve() else { return }
        let capture = audioCapture
        Task {
            do {
                try await capture.prepare(device: device)
            } catch {
                Log.audio.error("Audio prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Re-applies the settings that other services cache: hotkey, AI model, paragraphs, Dock policy.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.hotkey
            _ = settings.cloudAIEnabled
            _ = settings.cloudAIModel
            _ = settings.aiCorrectionModel
            _ = settings.aiFeaturesModel
            _ = settings.localAIIdleMinutes
            _ = settings.paragraphs
            _ = settings.menuBarOnly
            _ = settings.meetingsShortcut
            _ = settings.learningFixShortcut
            _ = settings.notesShortcut
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySettings()
                self.observeSettings()
            }
        }
    }

    private func applySettings() {
        let hotkey = settings.hotkey
        // While the recorder control captures a new combo the tap holds nil; it re-arms itself.
        if hotkeyTap.hotkey != nil, hotkeyTap.hotkey != hotkey {
            hotkeyTap.setHotkey(hotkey)
        }
        let cloud = settings.cloudAIConfiguration
        cloudAISnapshot.withLock { $0 = cloud }
        applyAIRouting()
        if dictionary.paragraphs != settings.paragraphs {
            dictionary.setParagraphs(settings.paragraphs)
        }
        windowPresenter.applyDockPolicy()
        applyMeetingShortcut()
        applyCorrectionShortcut()
        applyNoteShortcut()
    }

    /// The models per role and the idle time from the settings, live: the routes read the new
    /// snapshot on the next request and the local servers follow (`LocalAIService.setRoleModels`
    /// / `setOptions`).
    func applyAIRouting() {
        let routing = settings.aiRoleRouting(hardware: localAI.hardware)
        aiRoutingSnapshot.withLock { $0 = routing }
        localAI.apply(routing: routing, idleTimeout: settings.localAIIdleTimeout)
    }

    /// Where each role runs now, for Modele and the onboarding.
    var aiRoleRouting: AIRoleRouting {
        settings.aiRoleRouting(hardware: localAI.hardware)
    }

    /// Bumped when the cloud key was saved or removed, so the views that read `isCloudAIReady`
    /// update (the Keychain itself is not observable).
    private(set) var cloudKeyRevision = 0

    func cloudKeyDidChange() {
        cloudKeyRevision += 1
    }

    /// "Bielik w chmurze" is on and a key is saved (on 8 GB the AI features then go there).
    var isCloudAIReady: Bool {
        _ = cloudKeyRevision
        guard settings.cloudAIEnabled else { return false }
        let key = keyStore.get(KeyStore.Account.cloudFerroSherlock)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !(key ?? "").isEmpty
    }

    private func showStoreFallbackAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Ostrzeżenie o pamięci")
        alert.informativeText = String(localized: "Nie udało się otworzyć bazy historii. Ta sesja działa na bazie tymczasowej, nowe dyktowania nie zostaną zapisane.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
