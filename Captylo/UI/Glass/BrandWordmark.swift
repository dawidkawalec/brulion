import CoreText
import SwiftUI

/// The white "szpak" wordmark: the product name in lowercase Manrope ExtraBold (the display face
/// of Dusk Glass), set as text, so no image asset is needed. `height` is the box it takes in the
/// layout, the same box the old 867-unit image wordmark took: the type keeps that wordmark's
/// x-height (500 of 867 units) with Manrope's x-height of 0.54 em, so it sits at the same visual
/// size and weight in the sidebar and on the welcome screen, and its ink (the k's ascender to the
/// p's descender) is centred in the box like the old drawing.
@MainActor
struct BrandWordmark: View {
    var height: CGFloat

    /// The product name as the wordmark shows it.
    static let text = "szpak"
    /// Font size per point of `height`: (500 / 867) / 0.54.
    static let fontScale: CGFloat = 1.068
    /// Slightly tight tracking, as em, like a drawn wordmark.
    static let trackingEm: CGFloat = -0.02
    static let face = GlassFont.Face.manropeExtraBold

    /// Downward shift per point of font size that moves the ink centre of `text` onto the centre
    /// of the font's line box, which is what `Text` centres in its frame. Negative: Manrope's
    /// ascent reaches well above the k, so the ink sits low in the line box.
    static let inkOffsetPerPoint: CGFloat = {
        let size: CGFloat = 100
        let font = CTFontCreateWithName(face.rawValue as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        )
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let lineCentre = (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        guard ink.height > 0 else { return 0 }
        return (ink.midY - lineCentre) / size
    }()

    var body: some View {
        let size = height * Self.fontScale
        Text(verbatim: Self.text)
            .font(GlassFont.face(Self.face, size))
            .tracking(size * Self.trackingEm)
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .offset(y: size * Self.inkOffsetPerPoint)
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Szpak"))
    }
}
