import SwiftUI

/// "Bielik na tym Macu" on Modele > Podstawowe: the requirements box (this Mac's memory and free
/// disk and what they mean), then every catalog model as a row with its role, size, memory and
/// download state (`LocalModelRow`), "Pobierz zalecane" while the recommended set is not in, and
/// where the models come from. A delete asks first and stops the model's server before the file
/// goes (`LocalAIModelStore.willDelete`).
@MainActor
struct LocalModelsPanel: View {
    let localAI: LocalAIServices
    let routing: AIRoleRouting
    let cloudReady: Bool

    @State private var freeBytes: Int64?
    @State private var pendingDelete: LocalModelSpec?
    @State private var deleteError: String?

    private var store: LocalAIModelStore { localAI.store }

    private var requirements: LocalAIRequirements {
        localAI.hardware.requirements(cloudFeaturesAvailable: cloudReady)
    }

    private var plan: BielikDownloadPlan {
        BielikDownloadPlan(models: requirements.models, states: store.states, partialBytes: store.partialBytes, freeBytes: freeBytes)
    }

    var body: some View {
        GlassPanel {
            GlassSectionHeader("Bielik na tym Macu", systemImage: "cpu") {
                if plan.canStart {
                    Button {
                        for spec in plan.pending { store.download(spec.id) }
                    } label: {
                        Label("Pobierz zalecane", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
                }
            }
            LocalAIRequirementsCard(
                hardware: localAI.hardware,
                requirements: requirements,
                freeBytes: freeBytes,
                missingBytes: plan.remainingBytes,
                hasAnyModel: !store.installedModels.isEmpty
            )
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.models) { spec in
                    LocalModelRow(
                        spec: spec,
                        state: store.state(for: spec.id),
                        partialBytes: store.partialBytes[spec.id] ?? 0,
                        usage: LocalAIText.usage(of: spec, routing: routing, cloudReady: cloudReady),
                        memoryWarning: localAI.hardware.needsMemoryWarning(spec),
                        onDownload: {
                            store.download(spec.id)
                            refreshFreeSpace()
                        },
                        onCancel: { store.cancel(spec.id) },
                        onDelete: { pendingDelete = spec }
                    )
                }
            }
            if let deleteError {
                ToolStatusLine(text: deleteError, tone: .error)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            }
            ToolCaption(verbatim: LocalAIText.source)
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.bottom, 2)
        }
        .alert(
            Text("Usunąć \(pendingDelete.map(LocalAIText.shortName) ?? "")?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { spec in
            Button("Usuń", role: .destructive) { delete(spec) }
            Button("Anuluj", role: .cancel) {}
        } message: { spec in
            Text("Plik zajmuje \(LocalAIFormat.gigabytes(spec.bytes)). Funkcje, które go używają, będą działać bez AI, dopóki nie pobierzesz go ponownie.")
        }
        .onAppear {
            store.refresh()
            refreshFreeSpace()
        }
        .onChange(of: store.installedModels.count) { _, _ in
            refreshFreeSpace()
        }
    }

    private func refreshFreeSpace() {
        freeBytes = DiskSpace.availableBytes()
    }

    private func delete(_ spec: LocalModelSpec) {
        Task {
            do {
                try await store.delete(spec.id)
                deleteError = nil
            } catch {
                deleteError = String(localized: "Nie udało się usunąć modelu: \(error.localizedDescription)")
            }
            refreshFreeSpace()
        }
    }
}
