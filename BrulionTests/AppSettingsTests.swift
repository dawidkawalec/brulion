import Foundation
import Testing
@testable import Brulion

@MainActor
struct AppSettingsTests {
    private static let suiteName = "pl.craftweb.brulion.tests.settings"

    private func makeSettings() throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return AppSettings(defaults: defaults)
    }

    @Test func defaultsMatchTheBrief() throws {
        let settings = try makeSettings()
        // Not Captylo's Right Option: both apps run side by side.
        #expect(settings.hotkey == .rightCommand)
        #expect(settings.language == "pl")
        #expect(settings.transcriptionLanguage == "pl")
        #expect(settings.sttEngine == .local)
        #expect(settings.livePreview)
        #expect(!settings.aiEnabled)
        #expect(!settings.cloudAIEnabled)
        #expect(settings.aiPrompt.isEmpty)
        #expect(settings.aiPromptTemplate == CleanupPrompt.defaultTemplate)
        #expect(settings.micSelection == .systemDefault)
        #expect(settings.sounds)
        #expect(settings.muteWhileRecording)
        #expect(settings.restoreClipboard)
        #expect(settings.trailingSpace)
        #expect(settings.paragraphs)
        #expect(settings.saveHistory)
        #expect(!settings.menuBarOnly)
        #expect(settings.audioRetentionDays == 0)
        #expect(settings.onboardingStep == "welcome")
        #expect(!settings.onboardingDone)
        #expect(settings.dashboardRange == 14)
        #expect(settings.dashboardMode == .daily)
        #expect(settings.dashboardMetric == .words)
        #expect(settings.outputSettings == OutputSettings())
    }

    @Test func jsonBackedValuesRoundTrip() throws {
        let settings = try makeSettings()
        let custom = Hotkey(kind: .key, keyCode: KeyCode.space, flags: [.control, .option])
        settings.hotkey = custom
        settings.micSelection = .device(uid: "AppleUSBAudioEngine:1", modelUID: "USB Audio")
        settings.language = "auto"
        settings.dashboardMode = .cumulative
        settings.dashboardMetric = .minutes
        settings.cloudAIModel = "Bielik-11B-v3.0-Instruct-test"

        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: Self.suiteName)))
        #expect(reloaded.hotkey == custom)
        #expect(reloaded.micSelection == .device(uid: "AppleUSBAudioEngine:1", modelUID: "USB Audio"))
        #expect(reloaded.sttEngine == .local)
        #expect(reloaded.transcriptionLanguage == nil)
        #expect(reloaded.dashboardMode == .cumulative)
        #expect(reloaded.dashboardMetric == .minutes)
        #expect(reloaded.cloudAIModel == "Bielik-11B-v3.0-Instruct-test")
    }

    @Test func resetRestoresDefaults() throws {
        let settings = try makeSettings()
        settings.aiEnabled = true
        settings.aiPrompt = "Custom"
        settings.dashboardRange = 30
        settings.onboardingDone = true
        settings.hotkey = .fn

        settings.reset()

        #expect(!settings.aiEnabled)
        #expect(settings.aiPrompt.isEmpty)
        #expect(settings.dashboardRange == 14)
        #expect(!settings.onboardingDone)
        #expect(settings.hotkey == .rightCommand)
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        for key in AppSettings.keys {
            #expect(defaults.object(forKey: key.rawValue) == nil, "\(key.rawValue) should be removed")
        }
    }

    @Test func keysAreUniqueAndStable() {
        let raw = AppSettings.keys.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
        #expect(raw.contains("hotkey"))
        #expect(raw.contains("ai.enabled"))
        #expect(raw.contains("mic.selection"))
        #expect(raw.contains("onboarding.step"))
        #expect(raw.contains("dashboard.metric"))
        #expect(raw.contains("ai.modes"))
        #expect(raw.contains("ai.activeModeID"))
        #expect(raw.contains("ui.windowBackground"))
        #expect(raw.contains("ui.backgroundDim"))
        #expect(raw.contains("ui.panelSmoke"))
        #expect(raw.contains("learning.enabled"))
        #expect(raw.contains("learning.notifications"))
        #expect(raw.contains("learning.excludedApps"))
        #expect(raw.contains("learning.fixShortcut"))
        #expect(raw.contains("meetings.autoDetect"))
        #expect(raw.contains("meetings.consentReminder"))
        #expect(raw.contains("meetings.audioRetention"))
        #expect(raw.contains("meetings.shortcut"))
        #expect(raw.contains("meetings.aiCorrection"))
        #expect(raw.contains("meetings.calendar"))
        #expect(raw.contains("meetings.calendarReminder"))
        #expect(raw.contains("meetings.calendarReminderMinutes"))
        #expect(raw.contains("meetings.voiceProcessing"))
        #expect(raw.contains("meetings.mcp"))
        #expect(raw.contains("meetings.calendarPromptDismissed"))
        #expect(raw.contains("ai.cloud.enabled"))
        #expect(raw.contains("ai.cloud.model"))
        #expect(raw.contains("ai.model.correction"))
        #expect(raw.contains("ai.model.features"))
        #expect(raw.contains("ai.local.idleMinutes"))
        #expect(raw.contains("notes.shortcut"))
        #expect(raw.contains("ai.cloud.provider"))
        #expect(raw.contains("ai.cloud.url"))
        // Nothing of the account, Pro, the support card or the old cloud settings is left.
        for gone in ["account.cache", "account.refreshedAt", "dev.pro", "supportCard.hiddenUntil",
                     "meetings.proBannerHiddenUntil", "meetings.cloudTranscript", "ai.captylo",
                     "stt.captylo", "ai.model", "openRouter.modelsCache"] {
            #expect(!raw.contains(gone), "\(gone)")
        }
        #expect(AppSettings.keys.count == 48)
    }

    @Test func meetingMCPDefaultsOff() throws {
        let settings = try makeSettings()
        #expect(!settings.meetingsMCP)
        settings.meetingsMCP = true
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: Self.suiteName)))
        #expect(reloaded.meetingsMCP)
        settings.reset()
        #expect(!settings.meetingsMCP)
    }

    @Test func meetingVoiceProcessingDefaultsOff() throws {
        let settings = try makeSettings()
        #expect(!settings.meetingsVoiceProcessing)
        settings.meetingsVoiceProcessing = true
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: Self.suiteName)))
        #expect(reloaded.meetingsVoiceProcessing)
        settings.reset()
        #expect(!settings.meetingsVoiceProcessing)
    }

    @Test func meetingCalendarDefaultsOffWithAOneMinuteReminder() throws {
        let settings = try makeSettings()
        #expect(!settings.meetingsCalendar)
        #expect(settings.meetingsCalendarReminder)
        #expect(settings.meetingsCalendarReminderMinutes == 1)
        #expect(AppSettings.calendarReminderMinuteOptions == [0, 1, 2, 5])

        settings.meetingsCalendar = true
        settings.meetingsCalendarReminder = false
        settings.meetingsCalendarReminderMinutes = 5
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: Self.suiteName)))
        #expect(reloaded.meetingsCalendar)
        #expect(!reloaded.meetingsCalendarReminder)
        #expect(reloaded.meetingsCalendarReminderMinutes == 5)

        // Only 0, 1, 2 and 5 are offered: anything else falls back to the default.
        settings.meetingsCalendarReminderMinutes = 0
        #expect(settings.meetingsCalendarReminderMinutes == 0)
        settings.meetingsCalendarReminderMinutes = 7
        #expect(settings.meetingsCalendarReminderMinutes == 1)
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        defaults.set(-3, forKey: "meetings.calendarReminderMinutes")
        #expect(settings.meetingsCalendarReminderMinutes == 1)

        settings.reset()
        #expect(!settings.meetingsCalendar)
        #expect(settings.meetingsCalendarReminderMinutes == 1)
    }

    /// "Bielik w chmurze" is off until the user turns it on (PRD 7.5).
    @Test func cloudAIIsOffByDefaultAndResets() throws {
        let settings = try makeSettings()
        #expect(!settings.cloudAIEnabled)
        #expect(settings.cloudAIModel == CloudAIRouteProvider.defaultModel)
        settings.cloudAIEnabled = true
        #expect(settings.cloudAIEnabled)
        settings.reset()
        #expect(!settings.cloudAIEnabled)
    }

    @Test func voiceNoteShortcutIsOnByDefaultAndResets() throws {
        let settings = try makeSettings()
        #expect(settings.notesShortcut)
        settings.notesShortcut = false
        #expect(!settings.notesShortcut)
        settings.reset()
        #expect(settings.notesShortcut)
        #expect(GlobalShortcut.note.display == "⌃⌥⇧N")
    }

    @Test func meetingTranscriptSettingsDefaultOff() throws {
        let settings = try makeSettings()
        #expect(settings.meetingsShortcut)
        #expect(!settings.meetingsAICorrection)
    }

    @Test func windowToneDefaultsClampsAndResets() throws {
        let settings = try makeSettings()
        #expect(settings.windowTone == .standard)
        #expect(settings.backgroundDim == 10)
        #expect(settings.panelSmoke == 20)

        settings.backgroundDim = 25
        settings.panelSmoke = 35
        let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: Self.suiteName)))
        #expect(reloaded.windowTone == WindowTone(backgroundDim: 25, panelSmoke: 35))

        settings.backgroundDim = 99
        settings.panelSmoke = -5
        #expect(settings.backgroundDim == WindowTone.backgroundDimRange.upperBound)
        #expect(settings.panelSmoke == WindowTone.panelSmokeRange.lowerBound)

        settings.reset()
        #expect(settings.windowTone == .standard)
    }

    @Test func windowToneShiftsScrimsFromTheDefault() {
        #expect(WindowTone.standard.scrimOffset == 0)
        #expect(WindowTone.standard.scrim(0.34) == 0.34)
        let darker = WindowTone(backgroundDim: 30, panelSmoke: 20)
        #expect(abs(darker.scrim(0.10) - 0.30) < 0.0001)
        #expect(WindowTone(backgroundDim: 0, panelSmoke: 0).scrim(0.05) == 0)
        #expect(WindowTone(backgroundDim: 40, panelSmoke: 50).scrim(0.8) == 0.9)
        #expect(WindowTone(backgroundDim: 10, panelSmoke: 50).smokeOpacity == 0.5)
    }

    @Test func windowBackgroundDefaultsToBrulionAndPersists() throws {
        let settings = try makeSettings()
        #expect(settings.windowBackground == .brulion)
        #expect(WindowBackgroundStyle.defaultStyle == .brulion)

        // Reading the default stores nothing: whoever never picked a style follows the default.
        let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
        #expect(defaults.object(forKey: "ui.windowBackground") == nil)

        for style in WindowBackgroundStyle.allCases {
            settings.windowBackground = style
            let reloaded = AppSettings(defaults: try #require(UserDefaults(suiteName: Self.suiteName)))
            #expect(reloaded.windowBackground == style)
        }

        #expect(defaults.string(forKey: "ui.windowBackground") == WindowBackgroundStyle.allCases.last?.rawValue)
        defaults.set("neon", forKey: "ui.windowBackground")
        #expect(settings.windowBackground == .brulion)

        // An explicit earlier choice survives the new default.
        defaults.set("aurora", forKey: "ui.windowBackground")
        #expect(AppSettings(defaults: defaults).windowBackground == .aurora)

        // The removed see-through style falls back to the default.
        defaults.set("glass", forKey: "ui.windowBackground")
        #expect(AppSettings(defaults: defaults).windowBackground == .brulion)

        settings.windowBackground = .brulionLight
        settings.reset()
        #expect(settings.windowBackground == .brulion)
        #expect(defaults.object(forKey: "ui.windowBackground") == nil)
    }

    @Test func windowBackgroundRawValuesAreStable() {
        #expect(WindowBackgroundStyle.allCases.map(\.rawValue) == ["aurora", "dusk", "brulion", "brulionLight"])
        #expect(Set(WindowBackgroundStyle.pickerOrder) == Set(WindowBackgroundStyle.allCases))
    }
}
