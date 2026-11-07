import SwiftUI

/// "Pobierz Bielika" (PRD 7.1), after the speech model: the requirements in two lines (this
/// Mac's memory and free disk, then what that means), the recommended models with their sizes
/// and download state, "Pobierz" (the downloads go on in the background) and "Pomiń" (the app
/// works without AI and pastes the raw transcript), and one sentence on where the models come
/// from and what stays on the Mac.
@MainActor
struct BielikStep: View {
    let model: OnboardingModel

    @State private var freeBytes: Int64?

    private var localAI: LocalAIServices { model.appState.localAI }
    private var store: LocalAIModelStore { localAI.store }

    private var requirements: LocalAIRequirements {
        localAI.hardware.requirements(cloudFeaturesAvailable: model.appState.isCloudAIReady)
    }

    private var plan: BielikDownloadPlan {
        BielikDownloadPlan(models: requirements.models, states: store.states, partialBytes: store.partialBytes, freeBytes: freeBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(
                symbol: OnboardingStep.bielik.symbol,
                title: String(localized: "Pobierz Bielika"),
                subtitle: String(localized: "Polski model językowy, który na tym Macu poprawia dyktowanie i obsługuje funkcje AI.")
            )

            GlassRowSeparator()
                .padding(.top, 14)
                .padding(.bottom, 10)

            requirementsLines

            VStack(alignment: .leading, spacing: 2) {
                ForEach(requirements.models) { spec in
                    modelRow(spec)
                }
            }
            .padding(.top, 8)

            actions
                .padding(.top, 8)

            Text(verbatim: LocalAIText.source)
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            store.refresh()
            freeBytes = DiskSpace.availableBytes()
        }
    }

    // MARK: Requirements

    private var requirementsLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: LocalAIText.machine(localAI.hardware, freeBytes: freeBytes))
                    .font(GlassFont.rowTitle.weight(.semibold))
                    .foregroundStyle(GlassColor.textPrimary)
                    .monospacedDigit()
                GlassBadge(
                    title: Text(verbatim: requirements.title()),
                    tone: requirements.tier == .standard ? .success : .warning
                )
            }
            Text(verbatim: requirements.summary())
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
    }

    // MARK: Models

    private func modelRow(_ spec: LocalModelSpec) -> some View {
        let state = plan.state(of: spec)
        return HStack(alignment: .center, spacing: 12) {
            GlassIconBadge(systemImage: "cpu", size: GlassTokens.Size.rowBadge)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: LocalAIText.shortName(spec))
                        .font(GlassFont.rowTitle.weight(.semibold))
                        .foregroundStyle(GlassColor.textPrimary)
                    GlassBadge(title: Text(verbatim: LocalAIFormat.gigabytes(spec.bytes)))
                    Text(verbatim: LocalAIText.usage(of: spec, routing: model.appState.aiRoleRouting, cloudReady: model.appState.isCloudAIReady))
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textSecondary)
                }
                stateLine(state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .downloading = state {
                Button {
                    store.cancel(spec.id)
                } label: {
                    Label("Anuluj", systemImage: "xmark")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        }
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stateLine(_ state: LocalAIModelStore.State) -> some View {
        switch state {
        case .notInstalled:
            Text("Nie pobrano")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textTertiary)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                OnboardingProgressTrack(fraction: progress.fraction, height: 5)
                    .frame(maxWidth: 320)
                Text(verbatim: LocalAIText.progress(progress))
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .monospacedDigit()
            }
        case .verifying:
            Text("Sprawdzam pobrany plik...")
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.textSecondary)
        case .installed:
            GlassBadge("Pobrany", systemImage: "checkmark", tone: .success)
        case .failed(let message):
            Text(verbatim: message)
                .font(GlassFont.caption)
                .foregroundStyle(GlassColor.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    /// "Pobierz" and "Pomiń" while something is left to start; the state of the downloads
    /// otherwise (the footer's "Dalej" goes on, the downloads keep running).
    @ViewBuilder
    private var actions: some View {
        let plan = self.plan
        HStack(spacing: 12) {
            if !plan.pending.isEmpty {
                Button {
                    model.downloadBielik(plan: plan)
                    freeBytes = DiskSpace.availableBytes()
                } label: {
                    Label("Pobierz (\(LocalAIFormat.gigabytes(plan.remainingBytes)))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                .disabled(!plan.canStart)
                Button("Pomiń") {
                    model.advance()
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                Group {
                    if plan.hasEnoughSpace {
                        Text("Szpak działa też bez AI: wklei wtedy surową transkrypcję.")
                            .foregroundStyle(GlassColor.textSecondary)
                    } else {
                        Text("Za mało miejsca na dysku. Szpak działa też bez AI.")
                            .foregroundStyle(GlassColor.warning)
                    }
                }
                .font(GlassFont.caption)
                .fixedSize(horizontal: false, vertical: true)
            } else if plan.allInstalled {
                Label("Bielik jest gotowy do pracy.", systemImage: "checkmark.circle.fill")
                    .font(GlassFont.body)
                    .foregroundStyle(GlassColor.success)
            } else {
                Label("Pobieranie trwa w tle, możesz przejść dalej.", systemImage: "arrow.down.circle")
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
    }
}
