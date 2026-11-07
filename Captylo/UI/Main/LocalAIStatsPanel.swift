import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Statystyki lokalnej AI" on Modele > Zaawansowane (PRD 8, no telemetry): the counters of
/// `LocalUsageStats` as rows, "Eksportuj JSON" (a file the user picks, counts only) and
/// "Wyzeruj" (asks first). Nothing here leaves the Mac by itself.
@MainActor
struct LocalAIStatsPanel: View {
    let usage: LocalUsageStats

    @State private var counters = LocalUsageCounters()
    @State private var confirmReset = false
    @State private var status: (text: String, tone: InlineStatus.Tone)?

    var body: some View {
        GlassPanel(spacing: 4) {
            GlassSectionHeader("Statystyki lokalnej AI", systemImage: "chart.bar")
                .padding(.bottom, 4)
            ToolCaption("Liczone tylko na tym Macu i nigdzie nie wysyłane. Eksport zapisuje same liczby, bez żadnego tekstu.")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.bottom, 6)
            row("Dyktowania", value: counters.dictations, systemImage: "mic")
            row("Korekty przyjęte", value: counters.correctionsAccepted, systemImage: "checkmark.circle")
            row("Korekty odrzucone przez strażnika", value: counters.correctionsRejected, systemImage: "shield.lefthalf.filled")
            GlassRow(title: Text("Czas korekty"), subtitle: nil, systemImage: "timer") {
                GlassRowValue(text: timing)
            }
            row("Przekroczone limity czasu", value: counters.timeouts, systemImage: "hourglass")
            row("Użycia trybów AI", value: counters.modeUses.values.reduce(0, +), systemImage: "sparkles")
            row("Spotkania z notatkami AI", value: counters.meetingsProcessed, systemImage: "person.2")
            row("Awarie serwera modelu", value: counters.serverFailures, systemImage: "exclamationmark.triangle")
            GlassRowSeparator()
                .padding(.vertical, 6)
            HStack(spacing: 8) {
                Button(action: export) {
                    Label("Eksportuj JSON", systemImage: "square.and.arrow.up")
                }
                Button {
                    confirmReset = true
                } label: {
                    Label("Wyzeruj", systemImage: "arrow.counterclockwise")
                }
                if let since = counters.since {
                    Text("Liczone od \(since.formatted(.dateTime.day().month().year().locale(AppLocale.current)))")
                        .font(GlassFont.caption)
                        .foregroundStyle(GlassColor.textTertiary)
                        .padding(.leading, 4)
                }
                Spacer()
            }
            .buttonStyle(.glass(.neutral, size: .small, shape: .capsule))
            .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
            if let status {
                ToolStatusLine(text: status.text, tone: status.tone)
                    .padding(.leading, GlassTokens.Size.rowIconColumn + 16)
                    .padding(.top, 4)
            }
        }
        .task { await reload() }
        .alert("Wyzerować statystyki?", isPresented: $confirmReset) {
            Button("Wyzeruj", role: .destructive) {
                Task {
                    await usage.reset()
                    await reload()
                    status = (String(localized: "Statystyki wyzerowane."), .success)
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Liczniki zaczną od zera. Jeśli chcesz je zachować, najpierw je wyeksportuj.")
        }
    }

    private func row(_ title: LocalizedStringKey, value: Int, systemImage: String) -> some View {
        GlassRow(title, systemImage: systemImage) {
            GlassRowValue(text: Text(value, format: .number.locale(AppLocale.current)).monospacedDigit())
        }
    }

    /// "średnio 980 ms, p95 1750 ms", or a dash before the first correction.
    private var timing: Text {
        guard let average = counters.averageCorrectionMilliseconds, let p95 = counters.p95CorrectionMilliseconds else {
            return Text(verbatim: "-")
        }
        return Text("średnio \(average) ms, p95 \(p95) ms").monospacedDigit()
    }

    private func reload() async {
        counters = await usage.counters
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "szpak-lokalna-ai.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await usage.export(to: url)
                status = (String(localized: "Zapisano \(url.lastPathComponent)."), .success)
            } catch {
                status = (String(localized: "Nie udało się zapisać pliku: \(error.localizedDescription)"), .error)
            }
        }
    }
}
