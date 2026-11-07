import Foundation
import Testing
@testable import Captylo

struct LocalAICatalogTests {
    private func isHex(_ text: String, length: Int) -> Bool {
        text.count == length && text.allSatisfy { "0123456789abcdef".contains($0) }
    }

    @Test func everyModelIsCompleteAndPinned() {
        #expect(LocalModelCatalog.all.count == 3)
        for spec in LocalModelCatalog.all {
            #expect(isHex(spec.sha256, length: 64), "\(spec.id): sha256 is 64 lowercase hex")
            #expect(isHex(spec.revision, length: 40), "\(spec.id): revision is a full commit")
            #expect(spec.repository.hasPrefix("speakleash/"))
            #expect(spec.fileName.hasSuffix(".gguf"))
            #expect(spec.bytes > 1_000_000_000)
            #expect(spec.licence == "Apache-2.0")
            #expect(spec.displayName.hasPrefix("Bielik "))
            #expect(spec.contextLength >= 8192)
        }
    }

    @Test func idsAndFilesAreUnique() {
        let all = LocalModelCatalog.all
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.fileName)).count == all.count)
    }

    @Test func pinsTheF0Files() {
        #expect(LocalModelCatalog.bielik15B.bytes == 1_699_568_288)
        #expect(LocalModelCatalog.bielikMinitron7B.bytes == 4_501_556_256)
        #expect(LocalModelCatalog.bielik45B.bytes == 5_061_215_424)
        #expect(LocalModelCatalog.bielik15B.sha256 == "e206ebbd9ee00cc8f14af5a096ad3f193a59608c63905316e8dc680c96655a60")
    }

    @Test func downloadURLPointsAtThePinnedRevision() {
        let url = LocalModelCatalog.bielik15B.downloadURL()
        #expect(url.absoluteString == "https://huggingface.co/speakleash/Bielik-1.5B-v3.0-Instruct-GGUF/resolve/99d72cc757be4f8b958018f12d6898bad5c19c9e/Bielik-1.5B-v3.0-Instruct.Q8_0.gguf")
    }

    @Test func defaultRoles() {
        #expect(LocalModelCatalog.defaultModel(for: .correction) == LocalModelCatalog.bielik15B)
        #expect(LocalModelCatalog.defaultModel(for: .features) == LocalModelCatalog.bielikMinitron7B)
        #expect(LocalModelCatalog.bielik15B.defaultRole == .correction)
        #expect(LocalModelCatalog.bielikMinitron7B.defaultRole == .features)
        #expect(LocalModelCatalog.bielik45B.defaultRole == nil)
        #expect(LocalModelCatalog.model(id: "bielik-4.5b-v3-q8") == LocalModelCatalog.bielik45B)
        #expect(LocalModelCatalog.model(id: "nope") == nil)
    }

    @Test func downloadHostsAreHuggingFaceOnly() {
        #expect(LocalModelCatalog.isDownloadHost("huggingface.co"))
        #expect(LocalModelCatalog.isDownloadHost("cdn-lfs.huggingface.co"))
        #expect(LocalModelCatalog.isDownloadHost("cdn-lfs.hf.co"))
        #expect(LocalModelCatalog.isDownloadHost("cas-bridge.xethub.hf.co"))
        #expect(LocalModelCatalog.isDownloadHost("HuggingFace.co"))
        #expect(!LocalModelCatalog.isDownloadHost("evilhuggingface.co"))
        #expect(!LocalModelCatalog.isDownloadHost("huggingface.co.example.com"))
        #expect(!LocalModelCatalog.isDownloadHost("example.com"))
    }

    @Test func approximateRAMUsesTheF0Plan() {
        #expect(LocalModelCatalog.bielik15B.approximateRAMBytes == 2_300_000_000)
        #expect(LocalModelCatalog.bielikMinitron7B.approximateRAMBytes == 6_600_000_000)
        for spec in LocalModelCatalog.all {
            #expect(LocalAITuning.measuredPeakRAM[spec.id] != nil, "\(spec.id) has a planned memory")
            #expect(spec.approximateRAMBytes > spec.bytes)
        }
        let unmeasured = LocalAIFixtures.spec(id: "unmeasured", bytes: 1000)
        #expect(unmeasured.approximateRAMBytes == 1300)
    }
}
