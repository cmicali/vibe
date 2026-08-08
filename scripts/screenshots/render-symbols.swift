// Rasterize SF Symbols to transparent white PNGs, one per symbol.
//
//   swift render-symbols.swift <out-dir> <point-size> <weight> <symbol> [symbol ...]
//
// The App Store overlay compositor is Python, and PIL cannot reach SF Symbols —
// they are not glyphs in any font on the header search path, they come from the
// system symbol library. Rendering them here, through the same
// NSImage(systemSymbolName:) the app itself uses (see MainMenuBuilder), is what
// keeps the marketing shots showing the identical artwork to the FX menu rather
// than a lookalike.
//
// Symbols are vector, so the point size is a rasterization choice, not a
// quality ceiling: render at whatever the canvas needs.
//
// Output is <out-dir>/<symbol-name>.png, white on transparent, trimmed to the
// symbol's natural bounds. Weight is one of ultraLight, thin, light, regular,
// medium, semibold, bold, heavy, black.

import AppKit

let args = CommandLine.arguments
guard args.count >= 5, let pointSize = Double(args[2]) else {
    FileHandle.standardError.write(
        "usage: render-symbols.swift <out-dir> <point-size> <weight> <symbol> [symbol ...]\n"
            .data(using: .utf8)!)
    exit(64)
}

let outDir = args[1]
let weightName = args[3]
let symbols = Array(args[4...])

let weights: [String: NSFont.Weight] = [
    "ultraLight": .ultraLight, "thin": .thin, "light": .light,
    "regular": .regular, "medium": .medium, "semibold": .semibold,
    "bold": .bold, "heavy": .heavy, "black": .black,
]
guard let weight = weights[weightName] else {
    FileHandle.standardError.write("unknown weight: \(weightName)\n".data(using: .utf8)!)
    exit(64)
}

for name in symbols {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        FileHandle.standardError.write("no such SF Symbol: \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let image = base.withSymbolConfiguration(config) else {
        FileHandle.standardError.write("could not configure: \(name)\n".data(using: .utf8)!)
        exit(1)
    }

    let size = image.size
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)), pixelsHigh: Int(ceil(size.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else {
        FileHandle.standardError.write("could not allocate bitmap for: \(name)\n".data(using: .utf8)!)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(origin: .zero, size: size)
    image.draw(in: rect)
    // Symbols are template images and draw black; tint the drawn pixels white
    // without touching the transparent surround.
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not encode: \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = "\(outDir)/\(name).png"
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write("could not write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    print("\(path) \(Int(size.width))x\(Int(size.height))")
}
