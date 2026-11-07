import Foundation
import Testing
@testable import Captylo

struct LocalAIHardwareProfileTests {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private let polish = Locale(identifier: "pl_PL")

    private func profile(_ gigabytes: UInt64) -> HardwareProfile {
        HardwareProfile(physicalMemoryBytes: gigabytes * gib)
    }

    @Test func tiersFollowSixteenGigabytes() {
        #expect(profile(8).tier == .experimental)
        #expect(HardwareProfile(physicalMemoryBytes: 16 * gib - 1).tier == .experimental)
        #expect(profile(16).tier == .standard)
        #expect(profile(18).tier == .standard)
        #expect(profile(36).tier == .standard)
    }

    @Test func standardPlanRunsBothModelsLocally() {
        let plan = profile(16).plan()
        #expect(plan.correction == .local(LocalModelCatalog.bielik15B))
        #expect(plan.features == .local(LocalModelCatalog.bielikMinitron7B))
        #expect(plan.localModels == [LocalModelCatalog.bielik15B, LocalModelCatalog.bielikMinitron7B])
        #expect(profile(36).plan(cloudFeaturesAvailable: true) == plan, "16 GB+ stays local even with a cloud key")
    }

    @Test func experimentalPlanSharesTheSmallModel() {
        let plan = profile(8).plan()
        #expect(plan.correction == .local(LocalModelCatalog.bielik15B))
        #expect(plan.features == .local(LocalModelCatalog.bielik15B))
        #expect(plan.localModels == [LocalModelCatalog.bielik15B])
        #expect(plan.roleModels == [.correction: LocalModelCatalog.bielik15B, .features: LocalModelCatalog.bielik15B])
    }

    @Test func experimentalPlanSendsFeaturesToTheCloudWhenAvailable() {
        let plan = profile(8).plan(cloudFeaturesAvailable: true)
        #expect(plan.features == .cloud)
        #expect(plan.roleModels == [.correction: LocalModelCatalog.bielik15B])
        #expect(plan.localModels == [LocalModelCatalog.bielik15B])
    }

    @Test func bigModelsOnEightGigabytesComeWithAWarning() {
        let small = profile(8)
        #expect(!small.needsMemoryWarning(LocalModelCatalog.bielik15B))
        #expect(small.needsMemoryWarning(LocalModelCatalog.bielikMinitron7B))
        #expect(small.needsMemoryWarning(LocalModelCatalog.bielik45B))
        for spec in LocalModelCatalog.all {
            #expect(!profile(16).needsMemoryWarning(spec))
        }
    }

    @Test func memoryBudgetFitsOneModelOnEightAndTwoOnSixteen() {
        let small = profile(8).memoryBudgetBytes
        let pair = LocalModelCatalog.bielik15B.approximateRAMBytes + LocalModelCatalog.bielikMinitron7B.approximateRAMBytes
        #expect(LocalModelCatalog.bielik15B.approximateRAMBytes <= small)
        #expect(pair > small)
        #expect(pair <= profile(16).memoryBudgetBytes)
    }

    @Test func requirementsCountTheDownloadsAndTheMargin() {
        let standard = profile(16).requirements()
        #expect(standard.downloadBytes == LocalModelCatalog.bielik15B.bytes + LocalModelCatalog.bielikMinitron7B.bytes)
        #expect(standard.diskBytes == standard.downloadBytes + LocalModelDownloader.diskMargin)
        #expect(standard.minimumMemoryBytes == HardwareProfile.standardMinimumMemory)
        #expect(standard.summary(locale: polish).contains("7,2 GB"))
        #expect(!standard.title().isEmpty)

        let experimental = profile(8).requirements()
        #expect(experimental.downloadBytes == LocalModelCatalog.bielik15B.bytes)
        #expect(experimental.minimumMemoryBytes == nil)
        #expect(experimental.summary(locale: polish).contains("2,7 GB"))
        #expect(experimental.summary(locale: polish) != profile(8).requirements(cloudFeaturesAvailable: true).summary(locale: polish))
    }

    @Test func gigabytesFollowTheLocale() {
        #expect(LocalAIFormat.gigabytes(1_699_568_288, locale: polish) == "1,7 GB")
        #expect(LocalAIFormat.gigabytes(1_699_568_288, locale: Locale(identifier: "en_US")) == "1.7 GB")
    }
}
