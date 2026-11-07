import SwiftUI

/// The white symbol of the app icon, drawn from the vector asset `BrandSymbol`. It is the mark
/// of Captylo's icon (Brand Direction 01: the heavy round C with the diagonal cut), kept because
/// the Szpak icon is a recoloured variant of that icon (docs/PRD.md section 4).
@MainActor
struct OnboardingBrandMark: View {
    var body: some View {
        Image("BrandSymbol")
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}
