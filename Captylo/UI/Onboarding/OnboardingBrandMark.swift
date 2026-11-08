import SwiftUI

/// The mark of the app icon, drawn from the vector asset `BrandSymbol`: the rhubarb starling
/// singing on a twig (`scripts/make-szpak-brand.swift`, docs/design/dusk-glass.md principle 7).
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
