#!/usr/bin/env swift
// Regenerates the Szpak app icon (Captylo/Resources/Assets.xcassets/AppIcon.appiconset) from the
// Captylo 1.0.17 icon, read from git, so the result is reproducible and the Captylo sources never
// need a copy in the tree. Per docs/PRD.md section 4 the Szpak icon is the Captylo icon with a
// clearly different background colour and no Bielik or SpeakLeash mark.
//
//   swift scripts/make-szpak-icon.swift                 # rewrite the AppIcon set
//   swift scripts/make-szpak-icon.swift --analyze       # colour stats of the Captylo source
//   swift scripts/make-szpak-icon.swift --out <dir>     # write the set somewhere else
//   swift scripts/make-szpak-icon.swift --hue-shift <deg> --spread <0-1> --lift <0-1> \
//       --saturation <x> --out <dir>                    # try other values (defaults below)
//
// Every PNG of the set is recoloured from the Captylo PNG of the same size (the small sizes are
// hand-hinted, so they are not downscaled from the big one). Per pixel, in HSB: the hue turns by
// `hueShift` around Captylo's deep teal (about 184 degrees), which becomes a warm amber (32),
// with the spread of hues around it narrowed by `spread`; pixels with colour in them
// (saturation above ~0.08) get brighter by `lift` towards white and their saturation is scaled
// by `saturation`, weighted by how coloured they are, so the white symbol, the light streak and
// the soft halo stay white. Alpha, size and the sRGB colour space are kept.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Settings

/// The commit of Captylo 1.0.17 this fork starts from (docs/PRD.md section 3).
let sourceRevision = "9371dd7"
let iconSetPath = "Captylo/Resources/Assets.xcassets/AppIcon.appiconset"
let files = [
    "icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
    "icon_128x128.png", "icon_128x128@2x.png", "icon_256x256.png", "icon_256x256@2x.png",
    "icon_512x512.png", "icon_512x512@2x.png",
]

struct Recolour {
    /// Captylo's teal, the centre of the source hues (`--analyze`: 170-199 degrees).
    static let sourceHue = 184.0
    /// Degrees added to the source hue: 184 - 152 = 32, a warm amber (yellower hues turn olive
    /// where the source is dark and grey).
    var hueShift = -152.0
    /// How much of the source's hue spread around `sourceHue` survives (1 keeps it all). The
    /// greener teal at the left would turn olive at full spread.
    var spread = 0.4
    /// How far coloured pixels move towards full brightness (0 keeps the value).
    var lift = 0.5
    /// Saturation factor for coloured pixels.
    var saturation = 1.4

    func hue(_ h: Double) -> Double {
        var offset = h - Self.sourceHue
        if offset > 180 { offset -= 360 }
        if offset < -180 { offset += 360 }
        return Self.sourceHue + hueShift + offset * spread
    }
}

// MARK: - Arguments

var recolour = Recolour()
var analyzeOnly = false
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var outDirectory = root.appending(path: iconSetPath)

var arguments = CommandLine.arguments.dropFirst().makeIterator()
func value(_ flag: String) -> String {
    guard let next = arguments.next() else { fail("\(flag) needs a value") }
    return next
}
func number(_ flag: String) -> Double {
    guard let parsed = Double(value(flag)) else { fail("\(flag) needs a number") }
    return parsed
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-szpak-icon: \(message)\n".utf8))
    exit(1)
}
while let argument = arguments.next() {
    switch argument {
    case "--analyze": analyzeOnly = true
    case "--out": outDirectory = URL(fileURLWithPath: value(argument), isDirectory: true)
    case "--hue-shift": recolour.hueShift = number(argument)
    case "--spread": recolour.spread = number(argument)
    case "--lift": recolour.lift = number(argument)
    case "--saturation": recolour.saturation = number(argument)
    default: fail("unknown argument \(argument)")
    }
}

// MARK: - Git source

func captyloPNG(_ name: String) -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "show", "\(sourceRevision):\(iconSetPath)/\(name)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { fail("git: \(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, !data.isEmpty else {
        fail("git show \(sourceRevision):\(iconSetPath)/\(name) failed (is the full history checked out?)")
    }
    return data
}

// MARK: - Pixels

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// RGBA8, premultiplied last, in sRGB.
struct Bitmap {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("not a PNG") }
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: sRGB, bitmapInfo: info)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func png() -> Data {
        var copy = bytes
        let image: CGImage = copy.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return context.makeImage()!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("could not encode a PNG") }
        return data as Data
    }
}

func hsb(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
    let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
    var h = 0.0
    if delta > 0 {
        if maxC == r { h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = 60 * ((b - r) / delta + 2) }
        else { h = 60 * ((r - g) / delta + 4) }
    }
    if h < 0 { h += 360 }
    return (h, maxC == 0 ? 0 : delta / maxC, maxC)
}

func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let c = v * s
    let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double) = switch hp {
    case ..<1: (c, x, 0)
    case ..<2: (x, c, 0)
    case ..<3: (0, c, x)
    case ..<4: (0, x, c)
    case ..<5: (x, 0, c)
    default: (c, 0, x)
    }
    let m = v - c
    return (r1 + m, g1 + m, b1 + m)
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func apply(_ recolour: Recolour, to bitmap: inout Bitmap) {
    for index in stride(from: 0, to: bitmap.bytes.count, by: 4) {
        let alpha = Double(bitmap.bytes[index + 3]) / 255
        guard alpha > 0 else { continue }
        let r = Double(bitmap.bytes[index]) / 255 / alpha
        let g = Double(bitmap.bytes[index + 1]) / 255 / alpha
        let b = Double(bitmap.bytes[index + 2]) / 255 / alpha
        let (h, s, v) = hsb(min(r, 1), min(g, 1), min(b, 1))
        let weight = smoothstep(0.08, 0.35, s)
        let newV = v + (1 - v) * recolour.lift * weight
        let newS = min(s * (1 + (recolour.saturation - 1) * weight), 1)
        let (nr, ng, nb) = rgb(recolour.hue(h), newS, newV)
        bitmap.bytes[index] = UInt8((nr * alpha * 255).rounded())
        bitmap.bytes[index + 1] = UInt8((ng * alpha * 255).rounded())
        bitmap.bytes[index + 2] = UInt8((nb * alpha * 255).rounded())
    }
}

// MARK: - Run

if analyzeOnly {
    let bitmap = Bitmap(png: captyloPNG("icon_512x512@2x.png"))
    var hues = [Int](repeating: 0, count: 36), values = [Int](repeating: 0, count: 10), coloured = 0, total = 0
    for index in stride(from: 0, to: bitmap.bytes.count, by: 4) where bitmap.bytes[index + 3] > 200 {
        let alpha = Double(bitmap.bytes[index + 3]) / 255
        let (h, s, v) = hsb(Double(bitmap.bytes[index]) / 255 / alpha, Double(bitmap.bytes[index + 1]) / 255 / alpha,
                            Double(bitmap.bytes[index + 2]) / 255 / alpha)
        total += 1
        guard s > 0.2 else { continue }
        coloured += 1
        hues[min(Int(h / 10), 35)] += 1
        values[min(Int(v * 10), 9)] += 1
    }
    print("opaque pixels \(total), coloured (s > 0.2) \(coloured)")
    print("hue (10 degree bins):", hues.enumerated().filter { $0.element > 0 }.map { "\($0.offset * 10): \($0.element)" })
    print("value (0.1 bins):", values)
    exit(0)
}

try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
for name in files {
    var bitmap = Bitmap(png: captyloPNG(name))
    apply(recolour, to: &bitmap)
    do {
        try bitmap.png().write(to: outDirectory.appending(path: name))
    } catch {
        fail("could not write \(name): \(error.localizedDescription)")
    }
    print("\(name) \(bitmap.width)x\(bitmap.height)")
}
print("hue shift \(recolour.hueShift), spread \(recolour.spread), lift \(recolour.lift), saturation \(recolour.saturation) -> \(outDirectory.path)")
