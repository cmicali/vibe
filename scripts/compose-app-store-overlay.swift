// Composite a window-only Vibe capture onto a designed App Store background.
//
// Compiled once by its callers (`swift file.swift` recompiles every run):
//     swiftc -O -o compose scripts/compose-app-store-overlay.swift
//
//     compose <shot.png> <out.png> [--headline …] [--subhead …] [--lang …]
//         [--canvas WxH] [--width frac] [--glyphs a,b] [--wash-color RRGGBB]
//         [--headline-scale x] [--subhead-scale x] [--block-y frac] [--center-text]
//     compose --measure --headline … [--subhead …] [--lang …] [--canvas WxH]
//         [--headline-scale x]         # exit 1 if the caption cannot fit
//     compose --header <out.png> --canvas WxH
//     compose --row <art.png> <out.png> <left> <middle> <right> --canvas WxH
//
// A mock-up, unlike appstore-capture-app-screenshots.sh: it lays an
// already-captured window (the alpha-channel PNGs in Assets/) over a generated
// background. Honest only because those captures are effectively opaque, so
// the background is decoration around the window, never through it.
//
// The background is the app icon's vinyl-groove texture lit by a blurred wash
// of the track's artwork (cropped from the shot), then vignetted.
//
// Image math follows PIL's semantics where they differ from Core Image's
// defaults (enhance factors, content-mean contrast, gamma-space blurs); the
// constants below were tuned under them. Text goes through CoreText, whose
// fallback reaches the real CJK faces.

import AppKit
import CoreImage
import CoreText

// From the source's compile-time path: callers compile into a temp dir, so
// argv[0] says nothing about the repo.
let ROOT = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().path

// The default canvas; everything is placed by fraction, so any other works.
let CANVAS_W = 2880
let CANVAS_H = 1800

// How much of the canvas the window may take; width usually binds. The README
// captures are 1360-1550px wide, so this upscales ~1.5-1.8x, which the 2x
// source takes without visible softening.
let WINDOW_W_FRAC = 0.84
let WINDOW_H_FRAC = 0.72

// Vertical placement of the headline + window block within the free space.
let BLOCK_Y_FRAC = 0.5  // --block-y overrides

// --center-text pins the window this far from the bottom and centres the text
// above it. Centring the whole stack lets the window jump between shots whose
// headlines wrap differently.
let WINDOW_BOTTOM_FRAC = 0.063

let GROOVE = "\(ROOT)/Assets/record background.png"

// Tracking is a fraction of the point size. Negative tracking is a Latin
// display convention, so CJK stays at 0.
let HEADLINE_TRACKING = -0.014
let SUBHEAD_TRACKING = 0.0
let CJK_LANGS: Set<String> = ["ja", "ko", "zh-Hans", "zh-Hant"]

// SF Symbols row above the headline (--glyphs), sized as fractions of the
// canvas width and larger than the headline so it reads as artwork. Drawn
// through NSImage(systemSymbolName:), as the app's FX menu draws them.
let GLYPH_H_FRAC = 0.050
let GLYPH_GAP_FRAC = 0.030
let GLYPH_BLOCK_GAP_FRAC = 0.026
let GLYPH_ALPHA = 235.0 / 255.0
let GLYPH_WEIGHT = NSFont.Weight.regular
// Rasterizer resolution only; keep it above the drawn height.
let GLYPH_RENDER_PT = 220.0

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// --- pixel buffers ----------------------------------------------------------

// All CPU image math runs on plain RGBA8 buffers, top-left origin,
// premultiplied alpha (the CG native layout). Every image that feeds the
// arithmetic below is fully opaque, so premultiplied RGB equals straight RGB
// where it is ever read.
struct Buffer {
    var data: [UInt8]
    let w: Int
    let h: Int

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        data = [UInt8](repeating: 0, count: w * h * 4)
    }

    init(cgImage: CGImage, w: Int, h: Int) {
        self.init(w: w, h: h)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    var cgImage: CGImage {
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    subscript(x: Int, y: Int, c: Int) -> UInt8 {
        get { data[(y * w + x) * 4 + c] }
        set { data[(y * w + x) * 4 + c] = newValue }
    }
}

func loadCGImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { die("could not read \(path)") }
    return image
}

func savePNG(_ buffer: Buffer, to path: String) {
    guard
        let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { die("could not create \(path)") }
    CGImageDestinationAddImage(dest, buffer.cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { die("could not write \(path)") }
}

// One unmanaged CIContext for every blur: null working/output spaces keep the
// math in gamma space on the raw byte values, matching where PIL blurred.
let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

// Gaussian blur with edge extension (CIAffineClamp), cropped back to size —
// PIL's border behavior, and what keeps a blurred mask from darkening at its
// own image bounds.
func blurred(_ buffer: Buffer, sigma: Double) -> Buffer {
    let input = CIImage(cgImage: buffer.cgImage)
    let clamped = input.clampedToExtent()
    let blur = CIFilter(name: "CIGaussianBlur")!
    blur.setValue(clamped, forKey: kCIInputImageKey)
    blur.setValue(sigma, forKey: kCIInputRadiusKey)
    let out = blur.outputImage!.cropped(to: input.extent)
    guard let cg = ciContext.createCGImage(out, from: input.extent) else { die("blur failed") }
    return Buffer(cgImage: cg, w: buffer.w, h: buffer.h)
}

// --- the window -------------------------------------------------------------

// Crop a capture down to the window body, dropping the baked-in shadow.
// Returns the cropped buffer and the side of its square album-art tile (which
// is the header height, since the artwork fills the header).
func loadWindow(_ path: String) -> (Buffer, Int) {
    let cg = loadCGImage(path)
    let full = Buffer(cgImage: cg, w: cg.width, h: cg.height)

    var minX = full.w, minY = full.h, maxX = -1, maxY = -1
    for y in 0..<full.h {
        for x in 0..<full.w where full[x, y, 3] > 128 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    if maxX < 0 { die("\(path): no opaque pixels — is this a window capture?") }

    let w = maxX - minX + 1, h = maxY - minY + 1
    var win = Buffer(w: w, h: h)
    for y in 0..<h {
        let src = ((y + minY) * full.w + minX) * 4
        win.data.replaceSubrange(y * w * 4..<(y * w * 4 + w * 4), with: full.data[src..<src + w * 4])
    }

    // The crop's corner notches still hold shadow the window itself does not
    // cover, so re-cut them against a clean rounded rect. The radius is however
    // far the top row runs transparent before the corner curve ends.
    var notch = 0
    for x in 0..<w where win[x, 0, 3] < 200 { notch += 1 }
    let radius = max(notch / 2, 1)
    var mask = Buffer(w: w, h: h)
    mask.data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let path = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: w - 1, height: h - 1),
            cornerWidth: CGFloat(radius), cornerHeight: CGFloat(radius), transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
    }
    for i in stride(from: 3, to: win.data.count, by: 4) {
        win.data[i] = min(win.data[i], mask.data[i])
    }

    return (win, headerHeight(win))
}

// Height of the player header, i.e. the side of the square artwork tile.
// Found by walking down the left edge: inside the artwork the pixels are
// photographic and vary row to row; the playlist below starts a long run of
// near-identical dark rows. The playlist's first row is the biggest edge in
// the upper half.
func headerHeight(_ win: Buffer) -> Int {
    if win.h <= win.w / 3 { return win.h }  // no playlist — the header is the whole window
    let cols = min(12, win.w)
    var rowMean = [[Double]](repeating: [0, 0, 0], count: win.h)
    for y in 0..<win.h {
        for x in 0..<cols {
            for c in 0..<3 { rowMean[y][c] += Double(win[x, y, c]) }
        }
        for c in 0..<3 { rowMean[y][c] /= Double(cols) }
    }
    let lo = Int(Double(win.h) * 0.2), hi = Int(Double(win.h) * 0.75)
    var best = lo, bestDelta = -1.0
    for y in lo..<min(hi, win.h - 1) {
        let d = (0..<3).reduce(0.0) { $0 + abs(rowMean[y + 1][$1] - rowMean[y][$1]) }
        if d > bestDelta { bestDelta = d; best = y }
    }
    return best
}

func resized(_ buffer: Buffer, w: Int, h: Int) -> Buffer {
    Buffer(cgImage: buffer.cgImage, w: w, h: h)
}

func crop(_ buffer: Buffer, x: Int, y: Int, w: Int, h: Int) -> Buffer {
    var out = Buffer(w: w, h: h)
    for row in 0..<h {
        let src = ((row + y) * buffer.w + x) * 4
        out.data.replaceSubrange(row * w * 4..<(row * w * 4 + w * 4), with: buffer.data[src..<src + w * 4])
    }
    return out
}

// --- the background ---------------------------------------------------------

func aspectFill(_ buffer: Buffer, w: Int, h: Int) -> Buffer {
    let scale = max(Double(w) / Double(buffer.w), Double(h) / Double(buffer.h))
    let sw = max(w, Int(Double(buffer.w) * scale)), sh = max(h, Int(Double(buffer.h) * scale))
    let scaled = resized(buffer, w: sw, h: sh)
    return crop(scaled, x: (sw - w) / 2, y: (sh - h) / 2, w: w, h: h)
}

// PIL enhance semantics, kept exactly: Brightness multiplies toward black,
// Color interpolates (or extrapolates, factor > 1) against the Rec.601
// grayscale, Contrast against a solid gray of the image's own mean luma.
func luma601(_ r: Double, _ g: Double, _ b: Double) -> Double {
    (0.299 * r + 0.587 * g + 0.114 * b).rounded(.down)  // PIL's L conversion truncates
}

func clamp8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

func enhanceBrightness(_ buffer: inout Buffer, _ factor: Double) {
    for i in 0..<buffer.data.count where i % 4 != 3 {
        buffer.data[i] = clamp8(Double(buffer.data[i]) * factor)
    }
}

func enhanceColor(_ buffer: inout Buffer, _ factor: Double) {
    for i in stride(from: 0, to: buffer.data.count, by: 4) {
        let r = Double(buffer.data[i]), g = Double(buffer.data[i + 1]), b = Double(buffer.data[i + 2])
        let l = luma601(r, g, b)
        buffer.data[i] = clamp8(l + (r - l) * factor)
        buffer.data[i + 1] = clamp8(l + (g - l) * factor)
        buffer.data[i + 2] = clamp8(l + (b - l) * factor)
    }
}

func enhanceContrast(_ buffer: inout Buffer, _ factor: Double) {
    var total = 0.0
    for i in stride(from: 0, to: buffer.data.count, by: 4) {
        total += luma601(Double(buffer.data[i]), Double(buffer.data[i + 1]), Double(buffer.data[i + 2]))
    }
    let mean = (total / Double(buffer.w * buffer.h)).rounded()
    for i in 0..<buffer.data.count where i % 4 != 3 {
        buffer.data[i] = clamp8(mean + (Double(buffer.data[i]) - mean) * factor)
    }
}

// Blow the album art up into a soft, saturated colour field.
func artworkWash(_ art: Buffer, w: Int, h: Int) -> Buffer {
    // Downsample first: at this blur radius the detail is gone regardless, and
    // a 32px source makes the gradient smooth instead of blotchy.
    var wash = aspectFill(resized(art, w: 32, h: 32), w: w, h: h)
    wash = blurred(wash, sigma: Double(w) * 0.09)
    enhanceColor(&wash, 2.1)
    enhanceBrightness(&wash, 0.5)
    return wash
}

// Radial falloff, brightest a little above centre. Returned as one gray value
// per pixel (0-255).
func vignette(w: Int, h: Int, strength: Double = 0.7) -> [Double] {
    var mask = [Double](repeating: 0, count: w * h)
    let cx = Double(w) / 2, cy = Double(h) * 0.42
    for y in 0..<h {
        for x in 0..<w {
            let dx = (Double(x) - cx) / (Double(w) / 2)
            let dy = (Double(y) - cy) / (Double(h) / 2)
            let r = (dx * dx + dy * dy).squareRoot() / 1.25
            mask[y * w + x] = max(0, min(1, 1 - strength * pow(r, 1.7))) * 255
        }
    }
    return mask
}

// A flat field of one colour, for --wash-color. It skips enhanceColor, which
// exists to rescue washed-out ALBUM ART: a colour named on the command line is
// already the hue that was wanted, and pushing it 2.1x past its own luma only
// drives a channel to 0 or 255. Brightness still drops, because this sits
// behind the headline. The groove texture and the vignette are what keep it
// from reading as a flat rectangle, so this stays uniform on purpose.
func solidWash(_ hex: String, w: Int, h: Int) -> Buffer {
    var v = UInt32(hex, radix: 16) ?? 0
    if hex.count != 6 { die("--wash-color takes six hex digits, got '\(hex)'") }
    let b = UInt8(v & 0xFF); v >>= 8
    let g = UInt8(v & 0xFF); v >>= 8
    let r = UInt8(v & 0xFF)
    var buf = Buffer(w: w, h: h)
    for p in 0..<(w * h) {
        buf.data[p * 4] = r; buf.data[p * 4 + 1] = g; buf.data[p * 4 + 2] = b
        buf.data[p * 4 + 3] = 255
    }
    enhanceBrightness(&buf, 0.5)
    return buf
}

func buildBackground(art: Buffer, washColor: String?, w: Int, h: Int) -> Buffer {
    let grooveCG = loadCGImage(GROOVE)
    var groove = aspectFill(Buffer(cgImage: grooveCG, w: grooveCG.width, h: grooveCG.height), w: w, h: h)
    enhanceBrightness(&groove, 2.6)  // the texture is near-black
    let wash = washColor.map { solidWash($0, w: w, h: h) } ?? artworkWash(art, w: w, h: h)
    var bg = Buffer(w: w, h: h)
    let v = vignette(w: w, h: h)
    for p in 0..<(w * h) {
        let i = p * 4
        for c in 0..<3 {
            // blend(groove, wash, 0.78), then composite over black through the
            // vignette (which is a straight multiply).
            let mixed = Double(groove.data[i + c]) * 0.22 + Double(wash.data[i + c]) * 0.78
            bg.data[i + c] = clamp8((mixed * v[p] / 255).rounded(.down))
        }
        bg.data[i + 3] = 255
    }
    var out = bg
    enhanceContrast(&out, 1.06)
    return out
}

// --- text -------------------------------------------------------------------

// (kind, sizeFrac, leading, alpha). sizeFrac is of the canvas's GEOMETRIC
// MEAN, sqrt(w*h), not its width: 1290x2796 has nearly 2880x1800's area but
// 45% of its width, and width-based type read as a caption there.
let LINES: [(String, Double, Double, Double)] = [
    ("headline", 0.041742, 1.30, 255), ("subhead", 0.022768, 1.40, 195),
]
// Widest a line may run, as a fraction of the canvas width. Text past it wraps
// to two lines, then shrinks; below MIN_SHRINK of nominal it is too long to read
// at store size, so it fails and the translation must be shortened.
let MAX_TEXT_W_FRAC = 0.92
let MIN_SHRINK = 0.72
let SHRINK_STEP = 0.96

struct Line {
    let text: String
    let font: NSFont
    let tracking: Double
    let leading: Double
    let alpha: Double
}

func makeFont(_ kind: String, _ size: Double) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: kind == "headline" ? .semibold : .regular)
}

// The attributed run applies the tracking between glyphs, not after the last,
// so a centred line has no trailing slack.
func attributed(_ text: String, _ font: NSFont, _ tracking: Double, _ color: CGColor) -> NSAttributedString {
    let s = NSMutableAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color)!,
    ])
    if tracking != 0 && text.count > 1 {
        s.addAttribute(.kern, value: tracking, range: NSRange(location: 0, length: text.utf16.count - text.suffix(1).utf16.count))
    }
    return s
}

func lineWidth(_ text: String, _ font: NSFont, _ tracking: Double) -> Double {
    let line = CTLineCreateWithAttributedString(
        attributed(text, font, tracking, CGColor(gray: 1, alpha: 1)))
    return CTLineGetTypographicBounds(line, nil, nil, nil)
}

// Greedy wrap into at most two lines; nil if two don't fit. ja/zh have no
// spaces, so they may break at any character (kinsoku deliberately not
// implemented — two marketing lines don't warrant it).
func wrapTwo(_ text: String, _ font: NSFont, _ tracking: Double, _ maxW: Double, _ lang: String) -> [String]? {
    if lineWidth(text, font, tracking) <= maxW { return [text] }
    let charBreak = ["ja", "zh-Hans", "zh-Hant"].contains(lang)
    let units = charBreak ? text.map(String.init) : text.components(separatedBy: " ")
    let joiner = charBreak ? "" : " "
    for cut in stride(from: units.count - 1, to: 0, by: -1) {
        let first = units[..<cut].joined(separator: joiner).trimmingTrailingSpaces()
        if lineWidth(first, font, tracking) <= maxW {
            let second = units[cut...].joined(separator: joiner).trimmingLeadingSpaces()
            if lineWidth(second, font, tracking) <= maxW { return [first, second] }
            break
        }
    }
    return nil
}

extension String {
    func trimmingTrailingSpaces() -> String {
        String(reversed().drop(while: { $0 == " " }).reversed())
    }
    func trimmingLeadingSpaces() -> String {
        String(drop(while: { $0 == " " }))
    }
}

// renderTextLayer and textHeight both consume this, so the drawn stack and the
// centring cannot disagree. Dies (exit 1) when a string cannot fit: the
// --measure contract. Each scale multiplies only its own line (iOS captions
// are headline-only).
func layoutText(_ headline: String, _ subhead: String, _ w: Int, _ h: Int, _ lang: String,
                _ headlineScale: Double = 1.0, _ subheadScale: Double = 1.0) -> [Line] {
    let maxW = Double(w) * MAX_TEXT_W_FRAC
    // Sizes scale with area; the line cap stays a fraction of WIDTH.
    let typeBase = (Double(w) * Double(h)).squareRoot()
    let headlineTracking = CJK_LANGS.contains(lang) ? 0.0 : HEADLINE_TRACKING
    var out: [Line] = []
    for ((kind, sizeFrac, leading, alpha), (content, trackingFrac)) in zip(
        LINES, [(headline, headlineTracking), (subhead, SUBHEAD_TRACKING)])
    {
        if content.isEmpty { continue }
        let roleScale = kind == "headline" ? headlineScale : subheadScale
        let nominal = Double(Int(typeBase * sizeFrac * roleScale))
        var size = nominal
        var lines: [String]?
        while true {
            let font = makeFont(kind, size)
            let tracking = trackingFrac * size
            lines = wrapTwo(content, font, tracking, maxW, lang)
            if lines != nil { break }
            size = (size * SHRINK_STEP).rounded(.down)
            if size < nominal * MIN_SHRINK {
                die("\(lang): \(kind) too long even at \(Int(MIN_SHRINK * 100))% size: '\(content)'")
            }
        }
        let font = makeFont(kind, size)
        let tracking = trackingFrac * size
        for line in lines! {
            out.append(Line(text: line, font: font, tracking: tracking, leading: size * leading, alpha: alpha))
        }
    }
    return out
}

func textHeight(_ layout: [Line]) -> Double {
    layout.reduce(0) { $0 + $1.leading }
}

// Render the layout, centred, into a transparent canvas-size buffer with the
// given color role. Line y is the ascender top, as the block math expects.
func renderTextLayer(_ layout: [Line], top: Double, w: Int, h: Int, halo: Bool) -> Buffer {
    var layer = Buffer(w: w, h: h)
    layer.data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var y = top
        for line in layout {
            let color = halo
                ? CGColor(red: 0, green: 0, blue: 0, alpha: 150.0 / 255.0)
                : CGColor(red: 1, green: 1, blue: 1, alpha: line.alpha / 255.0)
            let ct = CTLineCreateWithAttributedString(
                attributed(line.text, line.font, line.tracking, color))
            let width = CTLineGetTypographicBounds(ct, nil, nil, nil)
            let baseline = y + Double(line.font.ascender)
            ctx.textPosition = CGPoint(x: (Double(w) - width) / 2, y: Double(h) - baseline)
            CTLineDraw(ct, ctx)
            y += line.leading
        }
    }
    return layer
}

// --- SF Symbol row ----------------------------------------------------------

// White-tinted rasterizations at their natural (optically sized) bounds.
func renderGlyphs(_ names: [String]) -> [Buffer] {
    names.map { name in
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let image = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: GLYPH_RENDER_PT, weight: GLYPH_WEIGHT))
        else { die("no such SF Symbol: \(name)") }
        let w = Int(ceil(image.size.width)), h = Int(ceil(image.size.height))
        var buffer = Buffer(w: w, h: h)
        buffer.data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let rect = NSRect(x: 0, y: 0, width: w, height: h)
            image.draw(in: rect)
            // Symbols are template images and draw black; tint the drawn
            // pixels white without touching the transparent surround.
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
        }
        return buffer
    }
}

// Scale the row uniformly. Uniform scaling matters: the symbols were
// rasterized at one point size, so their differing natural heights are SF
// Symbols' own optical sizing, and normalizing each to the same height would
// distort the set relative to how the app draws them.
func layoutGlyphs(_ images: [Buffer], _ w: Int) -> (scaled: [Buffer], total: Double, rowH: Int) {
    let target = Double(w) * GLYPH_H_FRAC
    let scale = target / Double(images.map(\.h).max()!)
    let scaled = images.map {
        resized($0, w: max(1, Int((Double($0.w) * scale).rounded())), h: max(1, Int((Double($0.h) * scale).rounded())))
    }
    let gap = Double(w) * GLYPH_GAP_FRAC
    let total = scaled.reduce(0.0) { $0 + Double($1.w) } + gap * Double(scaled.count - 1)
    return (scaled, total, scaled.map(\.h).max()!)
}

// --- compositing ------------------------------------------------------------

func composite(_ canvas: inout Buffer, _ layer: Buffer, x: Int, y: Int, alpha: Double = 1.0) {
    canvas.data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: canvas.w, height: canvas.h, bitsPerComponent: 8,
            bytesPerRow: canvas.w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setAlpha(alpha)
        ctx.draw(
            layer.cgImage,
            in: CGRect(x: x, y: canvas.h - y - layer.h, width: layer.w, height: layer.h))
    }
}

// Two-layer shadow: a wide ambient pool plus a tighter, offset key.
//
// Each layer is laid out at full canvas size and blurred there, rather than
// blurred at the window's own size and then offset into place. A Gaussian
// clips at its image bounds, so the small-canvas version cannot fall off past
// the window rect — it ends on a hard rectangular edge, which the offset then
// slides out from behind the rounded corners as a visible dark box.
func dropShadows(canvasW: Int, canvasH: Int, window: Buffer, x: Int, y: Int, scale: Double) -> [Buffer] {
    var layers: [Buffer] = []
    for (blur, dy, opacity) in [(70.0, 8.0, 0.42), (26.0, 26.0, 0.55)] {
        var mask = Buffer(w: canvasW, h: canvasH)
        let oy = y + Int(dy * scale)
        for wy in 0..<window.h {
            let cy = wy + oy
            if cy < 0 || cy >= canvasH { continue }
            for wx in 0..<window.w {
                let cx = wx + x
                if cx < 0 || cx >= canvasW { continue }
                let a = Double(window[wx, wy, 3]) * opacity
                mask[cx, cy, 3] = UInt8(a)
            }
        }
        var shadow = blurred(mask, sigma: blur * scale)
        // Black with the blurred alpha; RGB stays 0 (premultiplied black).
        for i in stride(from: 0, to: shadow.data.count, by: 4) {
            shadow.data[i] = 0; shadow.data[i + 1] = 0; shadow.data[i + 2] = 0
        }
        layers.append(shadow)
    }
    return layers
}

// --- run --------------------------------------------------------------------

func compose(
    shot: String, out: String, headline: String, subhead: String,
    canvasW: Int, canvasH: Int, widthFrac: Double, glyphs: [String], lang: String,
    washColor: String?, headlineScale: Double, subheadScale: Double, centerText: Bool, blockY: Double
) {
    let (rawWin, header) = loadWindow(shot)
    let art = crop(rawWin, x: 0, y: 0, w: header, h: header)

    let scale = min(
        Double(canvasW) * widthFrac / Double(rawWin.w),
        Double(canvasH) * WINDOW_H_FRAC / Double(rawWin.h))
    let win = resized(rawWin, w: Int(Double(rawWin.w) * scale), h: Int(Double(rawWin.h) * scale))

    var canvas = buildBackground(art: art, washColor: washColor, w: canvasW, h: canvasH)

    var glyphImages: [Buffer] = []
    var glyphH = 0.0, glyphGap = 0.0
    if !glyphs.isEmpty {
        glyphImages = renderGlyphs(glyphs)
        glyphH = Double(layoutGlyphs(glyphImages, canvasW).rowH)
        glyphGap = Double(canvasW) * GLYPH_BLOCK_GAP_FRAC
    }

    let layout = layoutText(headline, subhead, canvasW, canvasH, lang, headlineScale, subheadScale)
    let blockH = textHeight(layout)
    let gap = blockH > 0 ? Double(canvasW) * 0.032 : 0
    let stack = glyphH + glyphGap + blockH + gap + Double(win.h)
    var top = (Double(canvasH) - stack) * blockY
    var windowTop = top + glyphH + glyphGap + blockH + gap
    if centerText {
        windowTop = Double(canvasH) - Double(win.h) - Double(canvasH) * WINDOW_BOTTOM_FRAC
        top = (windowTop - (glyphH + glyphGap + blockH)) / 2
    }

    if !glyphImages.isEmpty {
        let (scaled, total, rowH) = layoutGlyphs(glyphImages, canvasW)
        var gx = (Double(canvasW) - total) / 2
        for image in scaled {
            // Centre each symbol on the row's midline rather than its top, so
            // the shorter ones (water.waves) sit level with the taller ones.
            let gy = top + (Double(rowH) - Double(image.h)) / 2
            composite(&canvas, image, x: Int(gx.rounded()), y: Int(gy.rounded()), alpha: GLYPH_ALPHA)
            gx += Double(image.w) + Double(canvasW) * GLYPH_GAP_FRAC
        }
        top += glyphH + glyphGap
    }

    if blockH > 0 {
        // Centred headline block, over a soft dark halo so it stays legible
        // wherever the artwork wash happens to be bright.
        let halo = renderTextLayer(layout, top: top, w: canvasW, h: canvasH, halo: true)
        composite(&canvas, blurred(halo, sigma: Double(canvasW) * 0.012), x: 0, y: 0)
        let text = renderTextLayer(layout, top: top, w: canvasW, h: canvasH, halo: false)
        composite(&canvas, text, x: 0, y: 0)
    }

    let x = (canvasW - win.w) / 2
    let y = Int(windowTop)
    for shadow in dropShadows(canvasW: canvasW, canvasH: canvasH, window: win, x: x, y: y, scale: scale) {
        composite(&canvas, shadow, x: 0, y: 0)
    }
    composite(&canvas, win, x: x, y: y)

    // Flatten: ASC wants opaque screenshots.
    for i in stride(from: 3, to: canvas.data.count, by: 4) { canvas.data[i] = 255 }
    savePNG(canvas, to: out)
    print("wrote \(out) (\(canvasW)x\(canvasH), window \(win.w)px wide, \(String(format: "%.2f", scale))x)")
}

// --- creative assets --------------------------------------------------------

// The iOS 27 product-page header and search-results art. Both are text-free,
// so one image serves every locale, and both are built only from the icon's
// own pieces or real captures.

// Apple's header template's art safe area, as fractions of 3840x1646: the
// only part every device and orientation is guaranteed to show.
let HEADER_SAFE = CGRect(x: 1097.0 / 3840, y: 493.0 / 1646, width: 1646.0 / 3840, height: 661.0 / 1646)

func drawn(w: Int, h: Int, _ body: (CGContext) -> Void) -> Buffer {
    var layer = Buffer(w: w, h: h)
    layer.data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        body(ctx)
    }
    return layer
}

func flattenAndSave(_ canvas: inout Buffer, _ out: String) {
    for i in stride(from: 3, to: canvas.data.count, by: 4) { canvas.data[i] = 255 }
    savePNG(canvas, to: out)
    print("wrote \(out) (\(canvas.w)x\(canvas.h))")
}

// The icon's waveform — rounded bars, played white up to the peak and grey
// after — run the full width under an envelope that puts the peak in the
// safe area. The jitter is seeded so a rebuild is byte-stable.
func composeHeader(out: String, w: Int, h: Int) {
    // Neutral charcoal, so only the groove shows; a wash color leaves the art
    // unread. The extra contrast lifts the grooves off the flat field.
    var canvas = buildBackground(art: Buffer(w: 1, h: 1), washColor: "252525", w: w, h: h)
    enhanceContrast(&canvas, 1.8)

    let pitch = Double(w) * 0.0161, barW = Double(w) * 0.0068
    let maxH = Double(h) * HEADER_SAFE.height * 0.91
    let half = Int(Double(w) / pitch / 2) - 1
    var seed: UInt64 = 7
    func jitter() -> Double {  // SplitMix64
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
    let played = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    let unplayed = CGColor(red: 139 / 255, green: 145 / 255, blue: 160 / 255, alpha: 1)  // the icon's grey
    var bars: [(CGRect, Bool, Double)] = []
    for i in -half...half {
        let t = Double(abs(i)) / Double(half)
        let envelope = exp(-pow(t / 0.42, 2)) * 0.9 + 0.1
        let bh = max(barW, maxH * envelope * (i == 0 ? 1 : 0.55 + 0.45 * jitter()))
        let x = Double(w) / 2 + Double(i) * pitch
        let edgeFade = min(1, (1 - t) / 0.25)
        bars.append((CGRect(x: x - barW / 2, y: (Double(h) - bh) / 2, width: barW, height: bh), i <= 0, edgeFade))
    }
    func barLayer(glow: Bool) -> Buffer {
        drawn(w: w, h: h) { ctx in
            for (rect, isPlayed, fade) in bars where !glow || isPlayed {
                let color = glow
                    ? CGColor(red: 170 / 255, green: 200 / 255, blue: 1, alpha: 0.55 * fade)
                    : (isPlayed ? played : unplayed).copy(alpha: fade)!
                ctx.setFillColor(color)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
                ctx.fillPath()
            }
        }
    }
    composite(&canvas, blurred(barLayer(glow: true), sigma: barW * 1.6), x: 0, y: 0)
    composite(&canvas, barLayer(glow: false), x: 0, y: 0)
    flattenAndSave(&canvas, out)
}

// Three full-screen iPhone captures side by side, the middle one larger: the
// search result's job is to show the app in use at a glance.
func composeRow(art: String, out: String, shots: [String], w: Int, h: Int) {
    if shots.count != 3 { die("--row takes three captures, left to right") }
    let artCG = loadCGImage(art)
    var canvas = buildBackground(
        art: Buffer(cgImage: artCG, w: artCG.width, h: artCG.height), washColor: nil, w: w, h: h)

    let phones: [Buffer] = shots.enumerated().map { i, path in
        let cg = loadCGImage(path)
        let ph = Double(h) * (i == 1 ? 0.80 : 0.736)
        let pw = Double(cg.width) * ph / Double(cg.height)
        let radius = pw * 0.128  // the iPhone screen's own corner
        let rect = CGRect(x: 0, y: 0, width: pw.rounded(), height: ph.rounded())
        return drawn(w: Int(rect.width), h: Int(rect.height)) { ctx in
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.interpolationQuality = .high
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(cg, in: rect)
            // A hairline, or the black playlist screen dissolves into the wash.
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
            ctx.setLineWidth(Double(w) * 0.0012)
            ctx.strokePath()
        }
    }
    let gap = Int(Double(w) * 0.035)
    var x = (w - phones.reduce(0) { $0 + $1.w } - 2 * gap) / 2
    for phone in phones {
        let y = (h - phone.h) / 2
        let scale = Double(w) / 2560
        for shadow in dropShadows(canvasW: w, canvasH: h, window: phone, x: x, y: y, scale: scale) {
            composite(&canvas, shadow, x: 0, y: 0)
        }
        composite(&canvas, phone, x: x, y: y)
        x += phone.w + gap
    }
    flattenAndSave(&canvas, out)
}

// --- CLI --------------------------------------------------------------------

var positional: [String] = []
var creative: String? = nil
var headline = "", subhead = "", lang = "en"
var washColor: String? = nil
var headlineScale = 1.0
var subheadScale = 1.0
var blockY = BLOCK_Y_FRAC
var centerText = false
var widthFrac = WINDOW_W_FRAC
var canvasSpec = "\(CANVAS_W)x\(CANVAS_H)"
var glyphSpec = ""
var measure = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    func value() -> String {
        if args.isEmpty { die("missing value for \(arg)") }
        return args.removeFirst()
    }
    switch arg {
    case "--headline": headline = value()
    case "--subhead": subhead = value()
    case "--lang": lang = value()
    case "--width": widthFrac = Double(value()) ?? WINDOW_W_FRAC
    case "--canvas": canvasSpec = value()
    case "--glyphs": glyphSpec = value()
    case "--wash-color": washColor = value().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    case "--headline-scale": headlineScale = Double(value()) ?? 1.0
    case "--subhead-scale": subheadScale = Double(value()) ?? 1.0
    case "--block-y": blockY = Double(value()) ?? BLOCK_Y_FRAC
    case "--center-text": centerText = true
    case "--measure": measure = true
    case "--header": creative = "header"
    case "--row": creative = "row"
    default:
        if arg.hasPrefix("--") { die("unknown option \(arg)") }
        positional.append(arg)
    }
}

let canvasParts = canvasSpec.split(separator: "x").compactMap { Int($0) }
guard canvasParts.count == 2 else { die("bad --canvas \(canvasSpec)") }

if let mode = creative {
    if mode == "header" {
        guard positional.count == 1 else { die("usage: compose-app-store-overlay --header <out.png> --canvas WxH") }
        composeHeader(out: positional[0], w: canvasParts[0], h: canvasParts[1])
    } else {
        guard positional.count >= 2 else { die("usage: compose-app-store-overlay --row <art.png> <out.png> <left> <middle> <right> --canvas WxH") }
        composeRow(art: positional[0], out: positional[1], shots: Array(positional.dropFirst(2)),
                   w: canvasParts[0], h: canvasParts[1])
    }
    exit(0)
}
if positional.count > 2 { die("unexpected argument \(positional[2])") }
let shot = positional.first, outPath = positional.dropFirst().first

if measure {
    _ = layoutText(headline, subhead, canvasParts[0], canvasParts[1], lang, headlineScale, subheadScale)
    exit(0)
}
guard let shotPath = shot, let output = outPath else {
    die("usage: compose-app-store-overlay <shot.png> <out.png> [--headline ...] (or --measure)")
}
let glyphNames = glyphSpec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
compose(
    shot: shotPath, out: output, headline: headline, subhead: subhead,
    canvasW: canvasParts[0], canvasH: canvasParts[1], widthFrac: widthFrac,
    glyphs: glyphNames, lang: lang, washColor: washColor, headlineScale: headlineScale, subheadScale: subheadScale,
    centerText: centerText, blockY: blockY)
