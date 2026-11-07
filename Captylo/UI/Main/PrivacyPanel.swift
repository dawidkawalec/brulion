import SwiftUI

/// "Prywatność" on Ustawienia > Podstawowe (PRD 7.6): exactly what Szpak connects to.
/// huggingface.co only while a model downloads, CloudFerro Sherlock only while "Bielik w
/// chmurze" is on (its current state shown), and nothing else: no telemetry, no update check,
/// no account.
@MainActor
struct PrivacyPanel: View {
    let cloudEnabled: Bool

    var body: some View {
        GlassPanel(spacing: 4) {
            GlassSectionHeader("Prywatność", systemImage: "hand.raised")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.top, 2)
                .padding(.bottom, 4)
            ToolCaption("Szpak łączy się z internetem tylko w tych dwóch sytuacjach:")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.bottom, 2)
            GlassRow(
                title: Text(verbatim: "huggingface.co"),
                subtitle: Text("Tylko podczas pobierania modeli: Whisper do rozpoznawania mowy i Bielik do AI. Bez konta i bez ciasteczek."),
                systemImage: "arrow.down.circle"
            ) {
                EmptyView()
            }
            GlassRow(
                title: Text(verbatim: "CloudFerro Sherlock"),
                subtitle: cloudSubtitle,
                systemImage: "cloud"
            ) {
                GlassBadge(cloudEnabled ? "Włączony" : "Wyłączony", tone: cloudEnabled ? .warning : .neutral)
            }
            GlassRow(
                title: Text("Nic więcej"),
                subtitle: Text("Bez telemetrii, bez sprawdzania aktualizacji, bez konta. Dyktowania, notatki, spotkania i statystyki zostają na tym Macu."),
                systemImage: "lock"
            ) {
                EmptyView()
            }
        }
    }

    private var cloudSubtitle: Text {
        cloudEnabled
            ? Text("Bielik w chmurze jest włączony: tekst do poprawienia i pytania o spotkania idą prosto do polskiej chmury CloudFerro.")
            : Text("Tylko gdy włączysz Bielika w chmurze (Modele > Zaawansowane). Bez tego AI działa wyłącznie na tym Macu.")
    }
}
