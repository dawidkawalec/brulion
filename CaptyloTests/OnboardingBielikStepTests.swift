import Foundation
import Testing
@testable import Captylo

/// "Pobierz Bielika": what is left to download, the disk check, and what "Pobierz" does.
@MainActor
struct OnboardingBielikStepTests {
    private static let small = LocalModelCatalog.bielik15B
    private static let features = LocalModelCatalog.bielikMinitron7B
    private static let recommended = [small, features]

    @Test func nothingDownloadedLeavesTheWholeSetPending() {
        let plan = BielikDownloadPlan(models: Self.recommended, states: [:], freeBytes: 100_000_000_000)
        #expect(plan.pending == Self.recommended)
        #expect(plan.remainingBytes == Self.small.bytes + Self.features.bytes)
        #expect(plan.hasEnoughSpace)
        #expect(plan.canStart)
        #expect(!plan.isDownloading)
        #expect(!plan.allInstalled)
    }

    @Test func runningAndFinishedDownloadsAreNotPending() {
        let progress = LocalDownloadProgress(receivedBytes: 1_000_000_000, totalBytes: Self.features.bytes, bytesPerSecond: 0)
        let plan = BielikDownloadPlan(
            models: Self.recommended,
            states: [Self.small.id: .installed, Self.features.id: .downloading(progress)],
            freeBytes: 10_000_000_000
        )
        #expect(plan.pending.isEmpty)
        #expect(plan.isDownloading)
        #expect(!plan.canStart)
        #expect(plan.remainingBytes == Self.features.bytes - 1_000_000_000)
    }

    @Test func aFailedDownloadCanStartAgainAndResumesItsPartialFile() {
        let plan = BielikDownloadPlan(
            models: Self.recommended,
            states: [Self.small.id: .installed, Self.features.id: .failed("Błąd sieci")],
            partialBytes: [Self.features.id: 500_000_000],
            freeBytes: 10_000_000_000
        )
        #expect(plan.pending == [Self.features])
        #expect(plan.remainingBytes == Self.features.bytes - 500_000_000)
        #expect(plan.canStart)
    }

    @Test func aFullDiskStopsTheStart() {
        // 4.5 GB to go plus the 1 GB margin does not fit into 5 GB.
        let plan = BielikDownloadPlan(models: [Self.features], states: [:], freeBytes: 5_000_000_000)
        #expect(!plan.hasEnoughSpace)
        #expect(!plan.canStart)
        // Unknown free space: the downloader checks again itself.
        #expect(BielikDownloadPlan(models: [Self.features], states: [:], freeBytes: nil).canStart)
    }

    @Test func everythingInstalledIsDone() {
        let plan = BielikDownloadPlan(
            models: Self.recommended,
            states: [Self.small.id: .installed, Self.features.id: .installed],
            freeBytes: 0
        )
        #expect(plan.allInstalled)
        #expect(plan.remainingBytes == 0)
        #expect(!plan.canStart)
        #expect(plan.hasEnoughSpace)
    }

    @Test func downloadStartsThePendingModelsAndTurnsTheAIOn() {
        let appState = DesignPreviewData.makeAppState()
        appState.settings.aiEnabled = false
        let model = OnboardingModel(appState: appState)
        var started: [String] = []
        let plan = BielikDownloadPlan(models: Self.recommended, states: [Self.small.id: .installed], freeBytes: 100_000_000_000)

        model.downloadBielik(plan: plan) { started.append($0) }

        #expect(started == [Self.features.id])
        #expect(appState.settings.aiEnabled)
    }

    @Test func downloadWithNothingToStartChangesNothing() {
        let appState = DesignPreviewData.makeAppState()
        appState.settings.aiEnabled = false
        let model = OnboardingModel(appState: appState)
        var started: [String] = []
        let full = BielikDownloadPlan(models: [Self.features], states: [:], freeBytes: 1_000_000)

        model.downloadBielik(plan: full) { started.append($0) }

        #expect(started.isEmpty)
        #expect(!appState.settings.aiEnabled)
    }

    @Test func theStepFollowsTheSpeechModelAndThePreviewNeverStartsAServer() {
        #expect(OnboardingStep.model.next == .bielik)
        let appState = DesignPreviewData.makeAppState()
        #expect(appState.localAI.service == nil)
        #expect(appState.localAI.store.isPinned)
        #expect(appState.localAI.store.modelsDirectory.path(percentEncoded: false).hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false)))
    }

    @Test func theRecommendedSetFollowsTheTier() {
        let big = HardwareProfile(physicalMemoryBytes: 16 * 1024 * 1024 * 1024).requirements()
        #expect(big.models == Self.recommended)
        let small = HardwareProfile(physicalMemoryBytes: 8 * 1024 * 1024 * 1024)
        #expect(small.requirements(cloudFeaturesAvailable: false).models == [Self.small])
        #expect(small.requirements(cloudFeaturesAvailable: true).models == [Self.small])
    }
}
