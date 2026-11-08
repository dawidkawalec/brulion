#!/usr/bin/env swift
// Draws the Szpak mark from one vector geometry and writes every asset that shows it, so the
// brand is reproducible and nothing is drawn by hand twice:
//
//   - the app icon set   Captylo/Resources/Assets.xcassets/AppIcon.appiconset (10 PNGs)
//   - BrandSymbol        the rhubarb mark of the welcome orb and the sidebar (SVG, vector)
//   - MenuBarIcon(+Recording)  template PNGs for the status item, 18 pt at 1x and 2x
//   - docs/brand/        mark SVGs, the icon as PNG and SVG, favicons, og.png (web, repo, press)
//
//   swift scripts/make-szpak-brand.swift                  # rewrite everything above
//   swift scripts/make-szpak-brand.swift --preview <dir>  # preview PNGs only, the repo is untouched
//
// The mark is a starling (Polish "szpak") perched on a twig, singing with an open beak: the bird
// that mimics voices, for an app you talk to. It is built from straight edges and a few arcs in
// the flat, angular manner of the bielik.ai site, in Bielik's rhubarb (#F66953) on its olive
// brown (#424237 -> #2F2F26). It is our own drawing: never the Bielik eagle or any SpeakLeash
// mark (AGENTS.md, docs/PRD.md section 4). Geometry is in a 1024-unit square, y pointing down
// (SVG convention); holes (the eye, the wing line) wind against the body so one nonzero path
// carries the whole mark.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colours

enum Palette {
    /// Bielik rhubarb, the mark.
    static let rhubarb: UInt32 = 0xF66953
    /// Lit top and shaded bottom of the mark on the icon.
    static let rhubarbLit: UInt32 = 0xFF8167
    static let rhubarbShade: UInt32 = 0xEC553E
    /// Bielik brown and brown-deep, the icon tile (top -> bottom), with a darker foot.
    static let tileTop: UInt32 = 0x4B4B3F
    static let tileMid: UInt32 = 0x38382E
    static let tileBottom: UInt32 = 0x24241D
    /// Bielik ink (dark mark on light backgrounds) and paper (light mark on dark ones).
    static let ink: UInt32 = 0x25251E
    static let paper: UInt32 = 0xFFF9F5
}

// MARK: - Geometry

struct P {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    static func + (a: P, b: P) -> P { P(a.x + b.x, a.y + b.y) }
    static func - (a: P, b: P) -> P { P(a.x - b.x, a.y - b.y) }
    static func * (a: P, k: Double) -> P { P(a.x * k, a.y * k) }
    var length: Double { (x * x + y * y).squareRoot() }
    var unit: P { self * (1 / length) }
}

enum Seg {
    case move(P)
    case line(P)
    case cubic(P, P, P)
    case close
}

typealias Subpath = [Seg]

/// Bezier circle (four quarter arcs).
func circle(_ c: P, _ r: Double) -> Subpath {
    let k = 0.5522847498 * r
    return [
        .move(P(c.x + r, c.y)),
        .cubic(P(c.x + r, c.y + k), P(c.x + k, c.y + r), P(c.x, c.y + r)),
        .cubic(P(c.x - k, c.y + r), P(c.x - r, c.y + k), P(c.x - r, c.y)),
        .cubic(P(c.x - r, c.y - k), P(c.x - k, c.y - r), P(c.x, c.y - r)),
        .cubic(P(c.x + k, c.y - r), P(c.x + r, c.y - k), P(c.x + r, c.y)),
        .close,
    ]
}

/// A capsule of width `w` from `a` to `b` (round ends): legs and the twig.
func capsule(_ a: P, _ b: P, width w: Double) -> Subpath {
    let r = w / 2, k = 0.5522847498 * r
    let d = (b - a).unit, n = P(-d.y, d.x)
    return [
        .move(a + n * r),
        .line(b + n * r),
        .cubic(b + n * r + d * k, b + d * r + n * k, b + d * r),
        .cubic(b + d * r - n * k, b - n * r + d * k, b - n * r),
        .line(a - n * r),
        .cubic(a - n * r - d * k, a - d * r - n * k, a - d * r),
        .cubic(a - d * r + n * k, a + n * r - d * k, a + n * r),
        .close,
    ]
}

/// Sample points along a subpath (end points plus 12 per cubic), for areas and bounds.
func samples(_ path: Subpath) -> [P] {
    var points: [P] = []
    var current = P(0, 0)
    for seg in path {
        switch seg {
        case .move(let p), .line(let p):
            points.append(p); current = p
        case .cubic(let c1, let c2, let p):
            for i in 1...12 {
                let t = Double(i) / 12, u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, e = t * t * t
                points.append(P(a * current.x + b * c1.x + c * c2.x + e * p.x,
                                a * current.y + b * c1.y + c * c2.y + e * p.y))
            }
            current = p
        case .close: break
        }
    }
    return points
}

/// Shoelace area of the sampled outline (sign = winding).
func signedArea(_ path: Subpath) -> Double {
    let pts = samples(path)
    var sum = 0.0
    for i in pts.indices {
        let a = pts[i], b = pts[(i + 1) % pts.count]
        sum += a.x * b.y - b.x * a.y
    }
    return sum / 2
}

/// The same outline traversed backwards.
func reversed(_ path: Subpath) -> Subpath {
    var ends: [P] = []
    var current = P(0, 0)
    for seg in path {
        switch seg {
        case .move(let p), .line(let p), .cubic(_, _, let p): ends.append(p); current = p
        case .close: break
        }
    }
    _ = current
    var out: Subpath = [.move(ends[ends.count - 1])]
    var index = ends.count - 1
    for seg in path.reversed() {
        switch seg {
        case .move, .close: continue
        case .line:
            index -= 1; out.append(.line(ends[index]))
        case .cubic(let c1, let c2, _):
            index -= 1; out.append(.cubic(c2, c1, ends[index]))
        }
    }
    out.append(.close)
    return out
}

func winding(_ path: Subpath, positive: Bool) -> Subpath {
    (signedArea(path) > 0) == positive ? path : reversed(path)
}

/// The starling, facing right, head raised, beak open.
enum Starling {
    // Beak: upper tip, gape (mouth corner), lower tip.
    static let upperTip = P(918, 168)
    static let gape = P(718, 322)
    static let lowerTip = P(902, 302)

    static let body: Subpath = [
        .move(upperTip),
        .line(P(705, 262)),                                       // top of the upper bill
        .cubic(P(655, 196), P(540, 214), P(492, 338)),            // crown to the nape
        .cubic(P(440, 420), P(370, 540), P(300, 628)),            // back to the tail
        .line(P(128, 792)),                                       // upper edge of the tail
        .line(P(196, 856)),                                       // squared tail tip
        .line(P(352, 742)),                                       // under the tail
        .cubic(P(450, 800), P(690, 740), P(742, 560)),            // belly to the breast
        .cubic(P(775, 500), P(772, 430), P(748, 392)),            // breast to the chin
        .line(lowerTip),                                          // lower bill
        .line(gape),
        .close,                                                   // upper bill back to its tip
    ]

    static let eye = circle(P(636, 296), 24)
    /// Thin crescent between the folded wing and the flank, tapering at both ends.
    static let wingLine: Subpath = [
        .move(P(560, 418)),
        .cubic(P(520, 560), P(390, 660), P(246, 724)),
        .cubic(P(408, 679), P(538, 579), P(560, 418)),
        .close,
    ]

    static let legs: [Subpath] = [
        capsule(P(515, 735), P(500, 872), width: 22),
        capsule(P(585, 715), P(572, 872), width: 22),
    ]
    static let twig = capsule(P(330, 884), P(850, 862), width: 34)

    /// The full mark: body with its eye and wing line, legs and twig.
    static func mark(eyeRadius: Double = 24, wing: Bool = true) -> [Subpath] {
        var parts = [winding(body, positive: true)]
        parts += legs.map { winding($0, positive: true) }
        parts.append(winding(twig, positive: true))
        parts.append(winding(circle(P(636, 296), eyeRadius), positive: false))
        if wing { parts.append(winding(wingLine, positive: false)) }
        return parts
    }

    /// Bounds of everything that is ink (holes never reach the outline).
    static var bounds: CGRect {
        let pts = ([body, twig] + legs).flatMap(samples)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

// MARK: - Output helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func cg(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, CGFloat(alpha),
    ])!
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-szpak-brand: \(message)\n".utf8))
    exit(1)
}

/// Mark space -> a target rect (y down), keeping the aspect ratio, centred.
func fit(_ rect: CGRect) -> CGAffineTransform {
    let b = Starling.bounds
    let scale = min(rect.width / b.width, rect.height / b.height)
    let dx = rect.midX - b.midX * scale, dy = rect.midY - b.midY * scale
    return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy)
}

func cgPath(_ parts: [Subpath], _ t: CGAffineTransform) -> CGPath {
    let path = CGMutablePath()
    func pt(_ p: P) -> CGPoint { CGPoint(x: p.x, y: p.y).applying(t) }
    for part in parts {
        for seg in part {
            switch seg {
            case .move(let p): path.move(to: pt(p))
            case .line(let p): path.addLine(to: pt(p))
            case .cubic(let c1, let c2, let p): path.addCurve(to: pt(p), control1: pt(c1), control2: pt(c2))
            case .close: path.closeSubpath()
            }
        }
    }
    return path
}

func svgPath(_ parts: [Subpath]) -> String {
    func f(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
    func pt(_ p: P) -> String { "\(f(p.x)) \(f(p.y))" }
    var d = ""
    for part in parts {
        for seg in part {
            switch seg {
            case .move(let p): d += "M\(pt(p))"
            case .line(let p): d += "L\(pt(p))"
            case .cubic(let c1, let c2, let p): d += "C\(pt(c1)) \(pt(c2)) \(pt(p))"
            case .close: d += "Z"
            }
        }
    }
    return d
}

func hexString(_ hex: UInt32) -> String { String(format: "#%06X", hex) }

/// A y-down RGBA canvas of `width` x `height` pixels.
func canvas(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot encode \(url.path)") }
}

func write(_ text: String, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { fail("cannot write \(url.path)") }
}

// MARK: - The icon

/// The macOS icon grid: a 824-unit rounded square inset 100 units in a 1024 canvas, with a soft
/// drop shadow in the margin (the same grid the Captylo icon used).
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

/// Where the mark sits on the tile, in 1024 units: a little above centre so the twig has air.
let markBox = CGRect(x: 238, y: 250, width: 548, height: 520)

func drawIcon(_ ctx: CGContext, size: Int) {
    let s = CGFloat(size) / 1024
    let tile = CGPath(roundedRect: tileRect.applying(.init(scaleX: s, y: s)),
                      cornerWidth: tileRadius * s, cornerHeight: tileRadius * s, transform: nil)
    let small = size <= 32

    // Drop shadow under the tile (the margin of the grid), none at the tiny sizes.
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: cg(0x000000, 0.38))
        ctx.addPath(tile)
        ctx.setFillColor(cg(Palette.tileBottom))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Tile: olive brown, lighter at the top.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let tileGradient = CGGradient(colorsSpace: sRGB,
                                  colors: [cg(Palette.tileTop), cg(Palette.tileMid), cg(Palette.tileBottom)] as CFArray,
                                  locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(tileGradient, start: CGPoint(x: 0, y: 100 * s), end: CGPoint(x: 0, y: 924 * s), options: [])
    // Ember: a warm rhubarb glow low behind the bird.
    let glow = CGGradient(colorsSpace: sRGB, colors: [cg(Palette.rhubarb, 0.30), cg(Palette.rhubarb, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 640 * s, y: 760 * s), startRadius: 0,
                           endCenter: CGPoint(x: 640 * s, y: 760 * s), endRadius: 560 * s, options: [])
    // Soft sheen over the top third.
    let sheen = CGGradient(colorsSpace: sRGB, colors: [cg(0xFFFFFF, 0.07), cg(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 100 * s), end: CGPoint(x: 0, y: 420 * s), options: [])
    ctx.restoreGState()

    // Hairline rim, brighter at the top.
    if !small {
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.setLineWidth(3 * s)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = CGGradient(colorsSpace: sRGB, colors: [cg(0xFFFFFF, 0.16), cg(0xFFFFFF, 0.03)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: 100 * s), end: CGPoint(x: 0, y: 924 * s), options: [])
        ctx.restoreGState()
    }

    // The bird: bigger and without the fine wing line at the tiny sizes.
    let box = small ? CGRect(x: 190, y: 210, width: 644, height: 604) : markBox
    let t = fit(box.applying(.init(scaleX: s, y: s)))
    let bird = cgPath(Starling.mark(eyeRadius: small ? 34 : 24, wing: !small), t)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 16 * s, color: cg(0x000000, 0.30))
        ctx.addPath(bird)
        ctx.setFillColor(cg(Palette.rhubarb))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(bird)
    ctx.clip()
    let birdGradient = CGGradient(colorsSpace: sRGB, colors: [cg(Palette.rhubarbLit), cg(Palette.rhubarbShade)] as CFArray,
                                  locations: [0, 1])!
    let bb = bird.boundingBoxOfPath
    ctx.drawLinearGradient(birdGradient, start: CGPoint(x: 0, y: bb.minY), end: CGPoint(x: 0, y: bb.maxY), options: [])
    ctx.restoreGState()
}

func iconImage(_ size: Int) -> CGImage { canvas(size, size) { drawIcon($0, size: size) } }

// MARK: - The menu bar glyph

/// Template glyph (black, the system tints it): the mark without the wing line, a bigger eye.
/// The recording variant adds a dot in the free corner above the back; both use one transform so
/// the bird does not move when recording starts.
func menuBarImage(points: Int, scale: Int, recording: Bool) -> CGImage {
    let px = points * scale
    return canvas(px, px) { ctx in
        let inset = CGFloat(scale) * 0.5
        let t = fit(CGRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset))
        var parts = Starling.mark(eyeRadius: 40, wing: false)
        if recording { parts.append(winding(circle(P(250, 282), 92), positive: true)) }
        ctx.addPath(cgPath(parts, t))
        ctx.setFillColor(cg(0x000000))
        ctx.fillPath()
    }
}

// MARK: - SVG

/// The mark alone in a square viewBox around its bounds.
func markSVG(fill: UInt32, title: String) -> String {
    let b = Starling.bounds
    let side = max(b.width, b.height) + 40
    let x = b.midX - side / 2, y = b.midY - side / 2
    func f(_ v: CGFloat) -> String { String(Int(v.rounded())) }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(f(x)) \(f(y)) \(f(side)) \(f(side))" width="512" height="512">
      <title>\(title)</title>
      <path d="\(svgPath(Starling.mark()))" fill="\(hexString(fill))"/>
    </svg>

    """
}

/// The icon as a flat SVG that fills its canvas (favicons, the web): tile, ember, the mark.
func iconSVG() -> String {
    let t = fit(CGRect(x: 150, y: 160, width: 724, height: 690))
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="512" height="512">
      <title>Szpak</title>
      <defs>
        <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="\(hexString(Palette.tileTop))"/>
          <stop offset="0.55" stop-color="\(hexString(Palette.tileMid))"/>
          <stop offset="1" stop-color="\(hexString(Palette.tileBottom))"/>
        </linearGradient>
        <radialGradient id="ember" cx="0.62" cy="0.76" r="0.6">
          <stop offset="0" stop-color="\(hexString(Palette.rhubarb))" stop-opacity="0.3"/>
          <stop offset="1" stop-color="\(hexString(Palette.rhubarb))" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="bird" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="\(hexString(Palette.rhubarbLit))"/>
          <stop offset="1" stop-color="\(hexString(Palette.rhubarbShade))"/>
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" rx="230" fill="url(#tile)"/>
      <rect width="1024" height="1024" rx="230" fill="url(#ember)"/>
      <path transform="matrix(\(t.a) 0 0 \(t.d) \(t.tx) \(t.ty))" d="\(svgPath(Starling.mark(eyeRadius: 30)))" fill="url(#bird)"/>
    </svg>

    """
}

/// A favicon PNG: the flat icon (full bleed tile) at `size` pixels.
func faviconImage(_ size: Int) -> CGImage {
    canvas(size, size) { ctx in
        let s = CGFloat(size) / 1024
        let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                          cornerWidth: 230 * s, cornerHeight: 230 * s, transform: nil)
        ctx.addPath(tile)
        ctx.clip()
        let g = CGGradient(colorsSpace: sRGB, colors: [cg(Palette.tileTop), cg(Palette.tileMid), cg(Palette.tileBottom)] as CFArray,
                           locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: CGFloat(size)), options: [])
        let glow = CGGradient(colorsSpace: sRGB, colors: [cg(Palette.rhubarb, 0.3), cg(Palette.rhubarb, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 635 * s, y: 778 * s), startRadius: 0,
                               endCenter: CGPoint(x: 635 * s, y: 778 * s), endRadius: 614 * s, options: [])
        let small = size <= 48
        let box = small ? CGRect(x: 90, y: 110, width: 844, height: 804) : CGRect(x: 150, y: 160, width: 724, height: 690)
        ctx.addPath(cgPath(Starling.mark(eyeRadius: small ? 40 : 30, wing: !small), fit(box.applying(.init(scaleX: s, y: s)))))
        ctx.setFillColor(cg(Palette.rhubarb))
        ctx.fillPath()
    }
}

// MARK: - Social preview

/// Draws one line of text with its baseline at `origin` on the y-down canvas.
func drawText(_ ctx: CGContext, _ text: String, font: CTFont, color: CGColor, at origin: CGPoint, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// 1200 x 630 link preview (GitHub social preview, the web): the brown with its ember, the
/// lockup and the welcome screen's line, in the app's own faces.
func ogImage(fonts: URL) -> CGImage {
    for name in ["Geologica-Bold.ttf", "Inter-Regular.ttf"] {
        CTFontManagerRegisterFontsForURL(fonts.appending(path: name) as CFURL, .process, nil)
    }
    let display = { (size: CGFloat) in CTFontCreateWithName("Geologica-Bold" as CFString, size, nil) }
    let body = CTFontCreateWithName("Inter-Regular" as CFString, 27, nil)
    return canvas(1200, 630) { ctx in
        let base = CGGradient(colorsSpace: sRGB, colors: [cg(0x34342B), cg(0x1D1D17)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 700, y: 630), options: [.drawsAfterEndLocation])
        let ember = CGGradient(colorsSpace: sRGB, colors: [cg(0xC46D58, 0.75), cg(0xC46D58, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(ember, startCenter: CGPoint(x: 1150, y: 640), startRadius: 0,
                               endCenter: CGPoint(x: 1150, y: 640), endRadius: 720, options: [])
        let warm = CGGradient(colorsSpace: sRGB, colors: [cg(Palette.rhubarb, 0.18), cg(Palette.rhubarb, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(warm, startCenter: CGPoint(x: 300, y: 700), startRadius: 0,
                               endCenter: CGPoint(x: 300, y: 700), endRadius: 520, options: [])

        // Lockup: the bird, then "szpak".
        ctx.addPath(cgPath(Starling.mark(eyeRadius: 30), fit(CGRect(x: 84, y: 92, width: 74, height: 70))))
        ctx.setFillColor(cg(Palette.rhubarb))
        ctx.fillPath()
        drawText(ctx, "szpak", font: display(58), color: cg(Palette.paper), at: CGPoint(x: 176, y: 146), tracking: -1.4)

        let paper = cg(Palette.paper), soft = cg(Palette.paper, 0.72)
        drawText(ctx, "Mów, a tekst pojawia się", font: display(66), color: paper, at: CGPoint(x: 84, y: 300), tracking: -1.8)
        drawText(ctx, "tam, gdzie piszesz.", font: display(66), color: paper, at: CGPoint(x: 84, y: 380), tracking: -1.8)
        drawText(ctx, "Dyktowanie i notatki ze spotkań na Macu.", font: body, color: soft, at: CGPoint(x: 86, y: 466))
        drawText(ctx, "Działa na Bieliku, na Twoim komputerze.", font: body, color: soft, at: CGPoint(x: 86, y: 506))
    }
}

// MARK: - Run

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fontsDir = root.appending(path: "Captylo/Resources/Fonts")
var previewDir: URL?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--preview":
        guard let dir = args.next() else { fail("--preview needs a directory") }
        previewDir = URL(fileURLWithPath: dir, isDirectory: true)
    default: fail("unknown argument \(arg)")
    }
}

if let dir = previewDir {
    writePNG(iconImage(1024), dir.appending(path: "icon-1024.png"))
    // Small sizes side by side, each scaled up 8x without smoothing, to judge the hinting.
    let smalls = [16, 32, 64]
    let sheet = canvas(8 * (16 + 32 + 64) + 40, 8 * 64) { ctx in
        ctx.setFillColor(cg(0xE8E6E1)); ctx.fill(CGRect(x: 0, y: 0, width: 8 * 112 + 40, height: 512))
        ctx.interpolationQuality = .none
        var x: CGFloat = 0
        for size in smalls {
            let img = iconImage(size)
            ctx.saveGState()
            ctx.translateBy(x: x, y: CGFloat(8 * size)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 8 * size, height: 8 * size))
            ctx.restoreGState()
            x += CGFloat(8 * size) + 20
        }
    }
    writePNG(sheet, dir.appending(path: "icon-small-8x.png"))
    let bar = canvas(36 * 2 * 6 + 60, 36 * 6 + 40) { ctx in
        ctx.setFillColor(cg(0xECECEC)); ctx.fill(CGRect(x: 0, y: 0, width: 36 * 12 + 60, height: 256))
        ctx.interpolationQuality = .none
        for (i, rec) in [false, true].enumerated() {
            let img = menuBarImage(points: 18, scale: 2, recording: rec)
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(20 + i * (216 + 20)), y: 20 + 216); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 216, height: 216))
            ctx.restoreGState()
        }
    }
    writePNG(bar, dir.appending(path: "menubar-6x.png"))
    write(markSVG(fill: Palette.rhubarb, title: "Szpak"), dir.appending(path: "mark.svg"))
    write(iconSVG(), dir.appending(path: "icon.svg"))
    writePNG(faviconImage(32), dir.appending(path: "favicon-32.png"))
    writePNG(ogImage(fonts: fontsDir), dir.appending(path: "og.png"))
    print("preview written to \(dir.path)")
    exit(0)
}

// App icon set.
let iconSet = root.appending(path: "Captylo/Resources/Assets.xcassets/AppIcon.appiconset")
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(iconImage(points * scale), iconSet.appending(path: name))
    }
}

// Symbol of the welcome orb and the sidebar lockup.
write(markSVG(fill: Palette.rhubarb, title: "Szpak"),
      root.appending(path: "Captylo/Resources/Assets.xcassets/BrandSymbol.imageset/szpak-mark.svg"))

// Status item.
let assets = root.appending(path: "Captylo/Resources/Assets.xcassets")
for scale in [1, 2] {
    let suffix = scale == 1 ? "" : "@2x"
    writePNG(menuBarImage(points: 18, scale: scale, recording: false), assets.appending(path: "MenuBarIcon.imageset/menubar\(suffix).png"))
    writePNG(menuBarImage(points: 18, scale: scale, recording: true),
             assets.appending(path: "MenuBarIconRecording.imageset/menubar-recording\(suffix).png"))
}

// Brand kit for the web and the repo.
let brand = root.appending(path: "docs/brand")
write(markSVG(fill: Palette.rhubarb, title: "Szpak"), brand.appending(path: "szpak-mark.svg"))
write(markSVG(fill: Palette.paper, title: "Szpak"), brand.appending(path: "szpak-mark-light.svg"))
write(markSVG(fill: Palette.ink, title: "Szpak"), brand.appending(path: "szpak-mark-dark.svg"))
write(iconSVG(), brand.appending(path: "favicon.svg"))
writePNG(iconImage(1024), brand.appending(path: "szpak-icon-1024.png"))
writePNG(faviconImage(32), brand.appending(path: "favicon-32.png"))
writePNG(faviconImage(180), brand.appending(path: "apple-touch-icon.png"))
writePNG(ogImage(fonts: fontsDir), brand.appending(path: "og.png"))
print("brand assets written")
