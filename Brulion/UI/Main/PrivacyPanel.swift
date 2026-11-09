import SwiftUI

/// "Prywatność" on Ustawienia > Podstawowe (PRD 7.6): exactly what Brulion connects to.
/// huggingface.co only while a model downloads, the "Bielik w chmurze" provider only for the
/// roles "Gdzie działa Bielik" sends there (the current state shown), and nothing else: no
/// telemetry, no update check, no account.
@MainActor
struct PrivacyPanel: View {
    /// The roles whose text goes to the cloud now (`AIRoleRouting.cloudRoles`, empty while the
    /// cloud is off or has no key).
    let cloudRoles: [AIRole]
    /// The cloud provider's name (`CloudAIProvider.displayName`): "CloudFerro Sherlock", "PCSS
    /// AI HUB" or the host of the user's own server.
    let cloudName: String

    var body: some View {
        GlassPanel(spacing: 4) {
            GlassSectionHeader("Prywatność", systemImage: "hand.raised")
                .padding(.horizontal, GlassTokens.Padding.rowHorizontal)
                .padding(.top, 2)
                .padding(.bottom, 4)
            ToolCaption("Brulion łączy się z internetem tylko w tych dwóch sytuacjach:")
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
                title: cloudRoles.isEmpty ? Text("Bielik w chmurze") : Text(verbatim: cloudName),
                subtitle: cloudSubtitle,
                systemImage: "cloud"
            ) {
                GlassBadge(cloudRoles.isEmpty ? "Wyłączony" : "Włączony", tone: cloudRoles.isEmpty ? .neutral : .warning)
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
        if cloudRoles.contains(.correction) {
            return cloudRoles.contains(.features)
                ? Text("Bielik w chmurze jest włączony dla wszystkiego: dyktowania do poprawienia, tryby AI, notatki i pytania o spotkania idą prosto do \(cloudName).")
                : Text("Bielik w chmurze jest włączony dla korekty: dyktowania do poprawienia idą prosto do \(cloudName).")
        }
        return cloudRoles.contains(.features)
            ? Text("Bielik w chmurze jest włączony dla funkcji AI: tryby AI, notatki i pytania o spotkania idą prosto do \(cloudName). Dyktowanie poprawia Bielik na tym Macu.")
            : Text("Tylko gdy wybierzesz Bielika w chmurze (Modele > Gdzie działa Bielik). Bez tego AI działa wyłącznie na tym Macu.")
    }
}
