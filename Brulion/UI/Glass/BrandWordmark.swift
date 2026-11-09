import CoreText
import SwiftUI

/// The "brulion" wordmark: the product name in lowercase Geologica Bold (the display face of
/// bielik.ai and of Dusk Glass), set as text in white, so no image asset is needed. With
/// `showsMark` the rhubarb "b" mark (`BrandSymbol`) stands before it, like the sygnet before a
/// name in Bielik's own logo (the sidebar lockup). `height` is the box the type takes in the
/// layout, the same box the old 867-unit image wordmark took: the type keeps that wordmark's
/// x-height (500 of 867 units) with Geologica's x-height of 0.51 em, so it sits at the same
/// visual size in the sidebar and on the welcome screen, and its ink (the b's and l's ascenders
/// down to the baseline) is centred in the box.
@MainActor
struct BrandWordmark: View {
    var height: CGFloat
    var showsMark: Bool = false

    /// The product name as the wordmark shows it.
    static let text = "brulion"
    /// Font size per point of `height`: (500 / 867) / 0.51.
    static let fontScale: CGFloat = 1.131
    /// Slightly tight tracking, as em, like a drawn wordmark.
    static let trackingEm: CGFloat = -0.025
    static let face = GlassFont.Face.geologicaBold
    /// The mark's box per point of `height` (the square box around the tall pencil "b", a little
    /// taller than the x-height of the type) and the gap before the name.
    static let markScale: CGFloat = 1.12
    static let markGap: CGFloat = 0.3

    /// Downward shift per point of font size that moves the ink centre of `text` onto the centre
    /// of the font's line box, which is what `Text` centres in its frame.
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
        HStack(spacing: height * Self.markGap) {
            if showsMark {
                Image("BrandSymbol")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: height * Self.markScale, height: height * Self.markScale)
            }
            name
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Brulion"))
    }

    private var name: some View {
        let size = height * Self.fontScale
        return Text(verbatim: Self.text)
            .font(GlassFont.face(Self.face, size))
            .tracking(size * Self.trackingEm)
            .foregroundStyle(GlassColor.textPrimary)
            .lineLimit(1)
            .fixedSize()
            .offset(y: size * Self.inkOffsetPerPoint)
            .frame(height: height)
    }
}
