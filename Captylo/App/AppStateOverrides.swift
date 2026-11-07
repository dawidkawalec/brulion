import Foundation
import SwiftData

/// Replacements for the services `AppState` would otherwise build against the real machine state.
/// `.live` (all nil) is a normal launch; the design preview (`--design-preview`) passes an
/// in-memory store, a throwaway defaults suite, a temp dictionary file and pinned statuses, so
/// nothing it does can reach the user's data directory, defaults domain or Keychain items.
struct AppStateOverrides {
    /// SwiftData container used instead of `Store.makeContainer()` (which creates the data directory).
    var modelContainer: ModelContainer?
    /// Meeting search index file instead of `AppPaths.searchIndex`. With an overridden (or
    /// fallback) store and no file here the index stays in memory, so the design preview and the
    /// test host never open the real index.
    var searchIndexURL: URL?
    /// `dictionary.json` location instead of `AppPaths.dictionaryJSON`.
    var dictionaryURL: URL?
    /// Key store instead of the login Keychain one.
    var keyStore: KeyStore?
    /// Defaults for the crash-recovery mute marker instead of `.standard`.
    var systemMuteDefaults: UserDefaults?
    /// Local model status shown regardless of the files on disk.
    var pinnedModelStatus: LocalModelStore.Status?
    /// Meeting voice detector status shown without loading it (the design preview never downloads).
    var pinnedSpeechDetectorStatus: SpeechDetectorStatus.State?
    /// Accessibility grant reported regardless of `AXIsProcessTrusted()`.
    var pinnedAccessibilityTrust: Bool?
    /// Calendar events served with full access instead of EventKit (`FixedCalendarSource`): the
    /// design preview and the test host never open the user's calendar.
    var calendarEvents: [CalendarEvent]?
    /// True for `--design-preview`: code that would touch the system (the hotkey tap) stays off.
    var isDesignPreview = false
    /// Folder for the local AI (models, pid files, usage counter) instead of the data folder.
    var localAIRoot: URL?
    /// False: no llama-server is ever started (the design preview and the test host).
    var startsLocalAI = true
    /// Bielik download states shown regardless of the files (the design preview).
    var pinnedLocalAIStates: [String: LocalAIModelStore.State]?

    static var live: AppStateOverrides { AppStateOverrides() }

    /// Defaults suite of the unit-test host, wiped at every launch.
    static let testHostSuiteName = AppIdentity.bundleID + ".test-host"

    /// True when the app is the unit-test host (`make test`).
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The unit-test host must never open the real store: a schema change would migrate the
    /// user's history under a running Captylo. It gets an in-memory store, a temp dictionary
    /// and a throwaway defaults suite instead.
    @MainActor
    static func testHost() -> (settings: AppSettings, overrides: AppStateOverrides) {
        isolated(suiteName: testHostSuiteName, folderPrefix: "captylo-test-host")
    }

    /// An in-memory store (and so an in-memory index), a temp dictionary and a wiped defaults suite.
    @MainActor
    private static func isolated(suiteName: String, folderPrefix: String) -> (settings: AppSettings, overrides: AppStateOverrides) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let container: ModelContainer
        do {
            container = try Store.makeInMemoryContainer()
        } catch {
            fatalError("In-memory store failed: \(error)")
        }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "\(folderPrefix)-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        var overrides = AppStateOverrides(
            modelContainer: container,
            dictionaryURL: folder.appending(path: "dictionary.json"),
            systemMuteDefaults: defaults,
            calendarEvents: []
        )
        // Never the real models or pid files, and never a llama-server process.
        overrides.localAIRoot = folder
        overrides.startsLocalAI = false
        return (AppSettings(defaults: defaults), overrides)
    }
}
