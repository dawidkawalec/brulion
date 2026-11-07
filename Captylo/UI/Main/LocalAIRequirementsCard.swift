import SwiftUI

/// The requirements box above the Bielik models (Modele > Podstawowe): this Mac's memory and
/// free disk, what that means for the local AI (`LocalAIRequirements`: the tier's title and
/// summary), the rule for every Mac, the space the recommended set still needs, and what
/// happens without any model. Plain words, as the owner asked.
@MainActor
struct LocalAIRequirementsCard: View {
    let hardware: HardwareProfile
    let requirements: LocalAIRequirements
    /// Free space on the data volume, nil when macOS does not say.
    let freeBytes: Int64?
    /// Bytes the recommended models still need to download (0 when they are all in).
    let missingBytes: Int64
    let hasAnyModel: Bool

    private var lacksSpace: Bool {
        guard let freeBytes, missingBytes > 0 else { return false }
        return freeBytes < missingBytes + LocalModelDownloader.diskMargin
    }

    var body: some View {
        GlassCard(style: .raised, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.system(size: GlassTokens.Size.rowIcon))
                    .foregroundStyle(GlassColor.icon)
                    .accessibilityHidden(true)
                Text(verbatim: LocalAIText.machine(hardware, freeBytes: freeBytes))
                    .font(GlassFont.rowTitle.weight(.semibold))
                    .foregroundStyle(GlassColor.textPrimary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                GlassBadge(
                    title: Text(verbatim: requirements.title()),
                    systemImage: requirements.tier == .standard ? "checkmark" : "flask",
                    tone: requirements.tier == .standard ? .success : .warning
                )
            }
            Text(verbatim: requirements.summary())
                .font(GlassFont.body)
                .foregroundStyle(GlassColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: LocalAIText.requirementsRule)
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if missingBytes > 0 {
                Text("Zalecany zestaw dla tego Maca: \(LocalAIFormat.gigabytes(requirements.downloadBytes)) do pobrania, zostało \(LocalAIFormat.gigabytes(missingBytes)).")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if lacksSpace {
                ToolStatusLine(text: String(localized: "Za mało wolnego miejsca na zalecane modele. Zwolnij miejsce na dysku albo pobierz tylko mniejszy model."), tone: .error)
            }
            if !hasAnyModel {
                ToolStatusLine(text: LocalAIText.worksWithoutModel)
            }
        }
    }
}
