import Foundation
import Testing
@testable import Captylo

/// The local AI settings: the model per role, the idle time, and the shipped cleanup prompt that
/// a stored "Czyszczenie" from an earlier build still holds.
@MainActor
struct AppSettingsLocalAITests {
    private func makeSettings() -> (AppSettings, UserDefaults) {
        let suite = "pl.craftweb.szpak.tests.localai.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults), defaults)
    }

    @Test func modelChoicesDefaultToThePlanAndRoundTrip() {
        let (settings, defaults) = makeSettings()
        #expect(settings.aiCorrectionModel == nil)
        #expect(settings.aiFeaturesModel == nil)

        settings.setAIModelChoice(.local(LocalModelCatalog.bielikMinitron7B.id), for: .correction)
        settings.setAIModelChoice(.cloud, for: .features)
        #expect(defaults.string(forKey: "ai.model.correction") == "bielik-minitron-7b-v3-q4km")
        #expect(defaults.string(forKey: "ai.model.features") == "cloud")

        let reread = AppSettings(defaults: defaults)
        #expect(reread.aiModelChoice(for: .correction) == .local(LocalModelCatalog.bielikMinitron7B.id))
        #expect(reread.aiModelChoice(for: .features) == .cloud)

        // Back to "Zalecany": nothing stored.
        reread.setAIModelChoice(nil, for: .features)
        #expect(defaults.object(forKey: "ai.model.features") == nil)
        #expect(reread.aiFeaturesModel == nil)
    }

    @Test func pickingTheCloudForARoleTurnsTheCloudOn() {
        let (settings, _) = makeSettings()
        #expect(!settings.cloudAIEnabled)
        settings.setAIModelChoice(.local(LocalModelCatalog.bielik45B.id), for: .features)
        #expect(!settings.cloudAIEnabled)
        settings.setAIModelChoice(.cloud, for: .correction)
        #expect(settings.cloudAIEnabled)
    }

    @Test func aLocationWritesTheSwitchAndThePicks() {
        let (settings, defaults) = makeSettings()
        let mac16 = HardwareProfile(physicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        settings.aiCorrectionModel = .local(LocalModelCatalog.bielik45B.id)

        settings.setAILocation(.featuresInCloud)
        #expect(settings.cloudAIEnabled)
        #expect(settings.aiFeaturesModel == .cloud)
        // The role that stays on this Mac keeps its own pick.
        #expect(settings.aiCorrectionModel == .local(LocalModelCatalog.bielik45B.id))
        #expect(settings.aiRoleRouting(hardware: mac16).location(cloudEnabled: settings.cloudAIEnabled) == .featuresInCloud)

        settings.setAILocation(.allInCloud)
        #expect(settings.aiCorrectionModel == .cloud)
        #expect(settings.aiFeaturesModel == .cloud)
        #expect(settings.aiRoleRouting(hardware: mac16).location(cloudEnabled: settings.cloudAIEnabled) == .allInCloud)

        settings.setAILocation(.featuresInCloud)
        // Taken off the cloud: back to the plan, not to the old local pick.
        #expect(settings.aiCorrectionModel == nil)
        #expect(settings.aiFeaturesModel == .cloud)

        settings.setAILocation(.local)
        #expect(!settings.cloudAIEnabled)
        #expect(settings.aiCorrectionModel == nil)
        #expect(settings.aiFeaturesModel == nil)
        #expect(defaults.object(forKey: "ai.model.features") == nil)
        #expect(settings.aiRoleRouting(hardware: mac16).location(cloudEnabled: settings.cloudAIEnabled) == .local)
    }

    @Test func goingLocalKeepsLocalPicks() {
        let (settings, _) = makeSettings()
        settings.aiFeaturesModel = .local(LocalModelCatalog.bielik45B.id)
        settings.cloudAIEnabled = true
        settings.setAILocation(.local)
        #expect(!settings.cloudAIEnabled)
        #expect(settings.aiFeaturesModel == .local(LocalModelCatalog.bielik45B.id))
    }

    @Test func anUnknownStoredModelReadsAsTheDefault() {
        let (settings, defaults) = makeSettings()
        defaults.set("bielik-99b", forKey: "ai.model.correction")
        defaults.set("  ", forKey: "ai.model.features")
        #expect(settings.aiCorrectionModel == nil)
        #expect(settings.aiFeaturesModel == nil)
        #expect(AIModelChoice(stored: "cloud") == .cloud)
        #expect(AIModelChoice(stored: LocalModelCatalog.bielik45B.id)?.localModel == LocalModelCatalog.bielik45B)
    }

    @Test func theRoutingCarriesThePicks() {
        let (settings, _) = makeSettings()
        settings.aiFeaturesModel = .local(LocalModelCatalog.bielik45B.id)
        let routing = settings.aiRoleRouting(hardware: HardwareProfile(physicalMemoryBytes: 32 * 1024 * 1024 * 1024))
        #expect(routing.correction == nil)
        #expect(routing.localModel(for: .features) == LocalModelCatalog.bielik45B)
        #expect(routing.localModel(for: .correction) == LocalModelCatalog.bielik15B)
    }

    @Test func idleTimeDefaultsToTenMinutesAndZeroMeansNever() {
        let (settings, defaults) = makeSettings()
        #expect(settings.localAIIdleMinutes == 10)
        #expect(settings.localAIIdleTimeout == .seconds(600))
        settings.localAIIdleMinutes = 0
        #expect(settings.localAIIdleTimeout == nil)
        settings.localAIIdleMinutes = -5
        #expect(settings.localAIIdleMinutes == 0)
        settings.localAIIdleMinutes = 30
        #expect(AppSettings(defaults: defaults).localAIIdleTimeout == .seconds(1800))
        #expect(AppSettings.localAIIdleMinuteOptions.contains(AppSettings.defaultLocalAIIdleMinutes))
    }

    @Test func resetClearsTheLocalAISettings() {
        let (settings, _) = makeSettings()
        settings.aiCorrectionModel = .cloud
        settings.localAIIdleMinutes = 1
        settings.reset()
        #expect(settings.aiCorrectionModel == nil)
        #expect(settings.localAIIdleMinutes == 10)
    }

    @Test func modelOptionsPerRoleListTheRecommendedFirstAndTheCloudLast() {
        #expect(AIModelChoice.options(for: .correction).first == .local(LocalModelCatalog.bielik15B.id))
        #expect(AIModelChoice.options(for: .features).first == .local(LocalModelCatalog.bielikMinitron7B.id))
        for role in AIRole.allCases {
            let options = AIModelChoice.options(for: role)
            #expect(options.last == .cloud)
            #expect(Set(options).count == LocalModelCatalog.all.count + 1)
        }
    }

    // MARK: The shipped cleanup prompt

    @Test func aStoredCleanupWithTheOldEnglishPromptReadsAsTheNewOne() {
        let (settings, _) = makeSettings()
        var modes = BuiltInAIModes.all
        modes[0].prompt = CleanupPrompt.legacyTemplate
        settings.aiModes = modes
        #expect(settings.activeMode.prompt == CleanupPrompt.defaultTemplate)

        // A prompt the user edited stays theirs.
        modes[0].prompt = "Popraw tylko interpunkcję."
        settings.aiModes = modes
        #expect(settings.activeMode.prompt == "Popraw tylko interpunkcję.")
    }

    @Test func anOldAIPromptEqualToAShippedTemplateIsNotMigrated() {
        #expect(AppSettings.migratedPrompt(CleanupPrompt.legacyTemplate) == nil)
        #expect(AppSettings.migratedPrompt(CleanupPrompt.defaultTemplate) == nil)
        #expect(AppSettings.migratedPrompt("Mój własny prompt.") != nil)
    }
}
