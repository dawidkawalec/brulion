import SwiftUI

/// One Bielik model in Modele: name, what it is used for now, size on disk and memory it needs
/// (`LocalAITuning`), then its state with the action: "Pobierz" / "Wznów", the progress with
/// "Anuluj", "Weryfikuję", "Zainstalowany" with "Usuń", or the error with "Spróbuj ponownie".
@MainActor
struct LocalModelRow: View {
    let spec: LocalModelSpec
    let state: LocalAIModelStore.State
    /// Bytes of an unfinished download kept for resuming.
    let partialBytes: Int64
    /// "Korekta dyktowania", "Funkcje AI", "Korekta i funkcje AI" or "Teraz nieużywany".
    let usage: String
    /// The Mac may run short of memory with this model (experimental tier).
    let memoryWarning: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    /// Lines under the row start where its title does (row padding, icon badge, gap).
    private var detailInset: CGFloat { GlassTokens.Padding.rowHorizontal + GlassTokens.Size.rowBadge + 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlassRow(title: Text(verbatim: spec.displayName), subtitle: subtitle, systemImage: "cpu", iconBadge: true) {
                trailing
                    .padding(.leading, 8)
            }
            details
                .padding(.leading, detailInset)
                .padding(.trailing, GlassTokens.Padding.rowHorizontal)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: Text {
        let size = LocalAIFormat.gigabytes(spec.bytes)
        let memory = LocalAIFormat.gigabytes(spec.approximateRAMBytes)
        return Text("\(usage) · \(size) na dysku · ok. \(memory) RAM")
    }

    @ViewBuilder
    private var details: some View {
        switch state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ToolProgressTrack(value: progress.fraction)
                Text(verbatim: LocalAIText.progress(progress))
                    .font(GlassFont.caption)
                    .foregroundStyle(GlassColor.textSecondary)
                    .monospacedDigit()
            }
            .padding(.bottom, 4)
        case .verifying:
            ToolStatusLine(text: String(localized: "Sprawdzam, czy plik jest kompletny (suma SHA-256)..."))
        case .failed(let message):
            ToolStatusLine(text: message, tone: .error)
        case .notInstalled where partialBytes > 0:
            ToolStatusLine(text: String(localized: "Pobrano \(LocalAIFormat.gigabytes(partialBytes)), pobieranie możesz wznowić."))
        case .notInstalled, .installed:
            EmptyView()
        }
        if memoryWarning {
            ToolStatusLine(text: String(localized: "Na tym Macu ten model może nie zmieścić się w pamięci obok innych aplikacji."), tone: .error)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .notInstalled:
            Button(action: onDownload) {
                if partialBytes > 0 {
                    Label("Wznów", systemImage: "arrow.down.circle")
                } else {
                    Label("Pobierz", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        case .downloading(let progress):
            HStack(spacing: 10) {
                GlassBadge(title: Text(verbatim: "\(Int((progress.fraction * 100).rounded(.down)))%"), systemImage: "arrow.down", tone: .accent)
                    .monospacedDigit()
                Button(action: onCancel) {
                    Label("Anuluj", systemImage: "xmark")
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                GlassBadge("Weryfikuję", tone: .accent)
            }
        case .installed:
            HStack(spacing: 10) {
                GlassBadge("Zainstalowany", systemImage: "checkmark", tone: .success)
                Button(action: onDelete) {
                    Label {
                        Text("Usuń")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(GlassColor.destructive)
                    }
                }
                .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            }
        case .failed:
            Button(action: onDownload) {
                Label("Spróbuj ponownie", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
        }
    }
}
