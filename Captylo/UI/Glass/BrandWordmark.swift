import SwiftUI

/// The white "szpak" wordmark: the product name in lowercase Manrope ExtraBold (the display face
/// of Dusk Glass), set as text, so no image asset is needed. `height` is the box it takes in the
/// layout, the same box the old 867-unit image wordmark took: the type keeps that wordmark's
/// x-height (500 of 867 units) with Manrope's x-height of 0.54 em, so it sits at the same visual
/// size and weight in the sidebar and on the welcome screen.
@MainActor
struct BrandWordmark: View {
    var height: CGFloat

    /// The product name as the wordmark shows it.
    static let text = "szpak"
    /// Font size per point of `height`: (500 / 867) / 0.54.
    static let fontScale: CGFloat = 1.068
    /// Slightly tight tracking, as em, like a drawn wordmark.
    static let trackingEm: CGFloat = -0.02

    var body: some View {
        let size = height * Self.fontScale
        Text(verbatim: Self.text)
            .font(GlassFont.face(.manropeExtraBold, size))
            .tracking(size * Self.trackingEm)
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Szpak"))
    }
}
