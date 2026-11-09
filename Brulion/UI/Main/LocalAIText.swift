import Foundation

/// Texts about the local AI shared by Modele and the onboarding: model names, the roles a model
/// serves, this Mac's memory and free disk. Polish source strings, English in the catalog.
enum LocalAIText {
    /// "Bielik 1.5B", "Bielik Minitron 7B", "Bielik 4.5B": the catalog name without the
    /// version and quantization (shown where space is short and next to its size).
    static func shortName(_ spec: LocalModelSpec) -> String {
        switch spec.id {
        case LocalModelCatalog.bielik15B.id: "Bielik 1.5B"
        case LocalModelCatalog.bielikMinitron7B.id: "Bielik Minitron 7B"
        case LocalModelCatalog.bielik45B.id: "Bielik 4.5B"
        default: spec.displayName
        }
    }

    /// A pick in the model menus: the model's short name, or the cloud.
    static func title(_ choice: AIModelChoice) -> String {
        switch choice {
        case .local:
            choice.localModel.map(shortName) ?? choice.stored
        case .cloud:
            String(localized: "Chmura (Bielik 11B)")
        }
    }

    /// The role's name as Modele shows it.
    static func roleName(_ role: AIRole) -> String {
        switch role {
        case .correction: String(localized: "Korekta dyktowania")
        case .features: String(localized: "Funkcje AI")
        }
    }

    /// What a model is used for now: one role, both, or nothing.
    static func usage(of spec: LocalModelSpec, routing: AIRoleRouting, cloudReady: Bool) -> String {
        let roles = AIRole.allCases.filter { routing.effectiveChoice(for: $0, cloudReady: cloudReady) == .local(spec.id) }
        switch roles.count {
        case 0: return String(localized: "Teraz nieużywany")
        case 1: return roleName(roles[0])
        default: return String(localized: "Korekta i funkcje AI")
        }
    }

    /// The Mac's memory in whole gigabytes as Apple names it ("36 GB").
    static func memory(_ hardware: HardwareProfile) -> String {
        let gigabytes = Int((Double(hardware.physicalMemoryBytes) / 1_073_741_824).rounded())
        return "\(gigabytes) GB"
    }

    /// "Twój Mac: 36 GB RAM, 120,3 GB wolnego miejsca" (the free space left out when unknown).
    static func machine(_ hardware: HardwareProfile, freeBytes: Int64?) -> String {
        let memory = memory(hardware)
        guard let freeBytes else {
            return String(localized: "Twój Mac: \(memory) RAM")
        }
        return String(localized: "Twój Mac: \(memory) RAM, \(LocalAIFormat.gigabytes(freeBytes)) wolnego miejsca")
    }

    /// The requirements for everyone, the same on every Mac.
    static var requirementsRule: String {
        String(localized: "Od 16 GB RAM korekta dyktowania i funkcje AI działają na tym Macu. Przy 8 GB korekta działa na Macu, a funkcje AI najlepiej w chmurze (Bielik w chmurze) albo słabiej na Bieliku 1.5B.")
    }

    /// Where the models come from and what stays on the Mac.
    static var source: String {
        String(localized: "Modele pochodzą z oficjalnych repozytoriów SpeakLeash na Hugging Face. Tekst nie opuszcza Maca, dopóki nie włączysz Bielika w chmurze.")
    }

    /// Without any model.
    static var worksWithoutModel: String {
        String(localized: "Bez pobranego modelu dyktowanie działa dalej i wkleja surową transkrypcję.")
    }

    /// The download line under a model: "42% · 1,9 z 4,5 GB · zostało ok. 2 min".
    static func progress(_ progress: LocalDownloadProgress) -> String {
        let percent = Int((progress.fraction * 100).rounded(.down))
        let received = LocalAIFormat.gigabytes(progress.receivedBytes)
        let total = LocalAIFormat.gigabytes(progress.totalBytes)
        guard let seconds = progress.secondsRemaining, seconds.isFinite else {
            return String(localized: "Pobieram... \(percent)% · \(received) z \(total)")
        }
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return String(localized: "Pobieram... \(percent)% · \(received) z \(total) · zostało ok. \(minutes) min")
    }
}
