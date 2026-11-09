import SwiftUI

/// The mark of the app icon, drawn from the vector asset `BrandSymbol`: the rhubarb "b" with a
/// pencil stem and a speech-bubble bowl (`scripts/make-brulion-brand.swift`,
/// docs/design/dusk-glass.md principle 7).
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
