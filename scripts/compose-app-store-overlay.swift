// Composite a window-only Vibe capture onto a designed App Store background.
//
//     swiftc -O -o compose scripts/compose-app-store-overlay.swift && \
//         ./compose <shot.png> <out.png> [--headline ...]
//
// (Runnable as `swift compose-app-store-overlay.swift` too, but the callers
// compile it once first — appstore-validate-copy.sh measures ~116 captions and
// `swift` re-compiles per run.)
//
// Unlike appstore-capture-app-screenshots.sh, which photographs the window over
// a staged desktop so the Liquid Glass shows a real backdrop, this is a pure
// mock-up: it takes an already-captured window (the alpha-channel PNGs in
// Assets/, produced by generate-readme-screenshots.sh) and lays it over a
// generated background. That is only honest because those captures come out
// effectively opaque — the window's own material is dense enough that nothing
// behind it would show through anyway — so the background is decoration around
// the window, never through it.
//
// The background is built from the app's own identity rather than a wallpaper:
// the vinyl-groove texture from the app icon, lit by a heavily blurred wash of
// the playing track's own album artwork (cropped out of the shot itself), then
// vignetted. Each shot therefore carries the colour of the music it is showing.
//
// This replaced a Python/PIL implementation so the toolchain needs no pip
// installs. Image math follows PIL's semantics where they differ from Core
// Image's defaults (enhance factors, content-mean contrast, gamma-space
// blurs); text goes through CoreText, whose system-font fallback reaches the
// real CJK faces (PingFang et al.) that PIL could not open.

import AppKit
import CoreImage
import CoreText

// The repo root, from the source file's compile-time path — the binary itself
// is compiled into a temp dir by the calling scripts, so argv[0] is useless.
let ROOT = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().path

// 2880x1800 is the 16:10 size App Store Connect takes for macOS; 2560x1600 and
// 1440x900 are the others and work unchanged, since everything is placed by
// fraction of the canvas.
let CANVAS_W = 2880
let CANVAS_H = 1800

// How much of the canvas the window may take. Width usually binds; the height
// cap only comes into play for the tall playlist+pitch shot, and leaves room
// for the headline above. The README captures are 1360-1550px wide, so a width
// fraction this high means upscaling ~1.5-1.8x — checked at 1:1, and the
// 2x-retina source takes it without visible softening.
let WINDOW_W_FRAC = 0.84
let WINDOW_H_FRAC = 0.72

// Vertical placement of the headline + window block within the free space.
let BLOCK_Y_FRAC = 0.5

let GROOVE = "\(ROOT)/Assets/record background.png"

// SF Pro through NSFont.systemFont, which matches the type inside the window
// and falls back per script — CJK gets the genuine system faces. Tracking is a
// fraction of the point size; SF tightens at display sizes, but negative
// tracking is a Latin display convention, so CJK stays at 0.
let HEADLINE_TRACKING = -0.014
let SUBHEAD_TRACKING = 0.0
let CJK_LANGS: Set<String> = ["ja", "ko", "zh-Hans", "zh-Hant"]

// Optional row of SF Symbols above the headline (--glyphs). Height and gap are
// fractions of the canvas width; the height is deliberately larger than the
// headline's point size, so the row reads as artwork rather than as a caption.
// Rendered with the same NSImage(systemSymbolName:) the app itself uses (see
// MainMenuBuilder), so the shots show the identical artwork to the FX menu.
let GLYPH_H_FRAC = 0.050
let GLYPH_GAP_FRAC = 0.030
let GLYPH_BLOCK_GAP_FRAC = 0.026
let GLYPH_ALPHA = 235.0 / 255.0
let GLYPH_WEIGHT = NSFont.Weight.regular
// Point size handed to the rasterizer. Symbols are vector, so this only sets
// resolution — keep it comfortably above the drawn height.
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

func buildBackground(art: Buffer, w: Int, h: Int) -> Buffer {
    let grooveCG = loadCGImage(GROOVE)
    var groove = aspectFill(Buffer(cgImage: grooveCG, w: grooveCG.width, h: grooveCG.height), w: w, h: h)
    enhanceBrightness(&groove, 2.6)  // the texture is near-black
    let wash = artworkWash(art, w: w, h: h)
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

// Point size and leading of each line, as fractions of the canvas width.
// (kind, sizeFrac, leading, alpha)
let LINES: [(String, Double, Double, Double)] = [
    ("headline", 0.0330, 1.30, 255), ("subhead", 0.0180, 1.40, 195),
]
// Widest a text line may run, as a fraction of the canvas. When a translation
// exceeds it the point size shrinks (headline) or the line wraps then shrinks
// (subhead, max two lines); below MIN_SHRINK of nominal the copy is too long
// to read at store size, so fail and shorten the translation instead.
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

// Resolve both strings into rendered lines. drawText and textHeight both
// consume this, so the drawn stack and the vertical centering can never
// disagree. Dies (exit 1) when a string cannot fit — the --measure contract.
func layoutText(_ headline: String, _ subhead: String, _ w: Int, _ lang: String) -> [Line] {
    let maxW = Double(w) * MAX_TEXT_W_FRAC
    let headlineTracking = CJK_LANGS.contains(lang) ? 0.0 : HEADLINE_TRACKING
    var out: [Line] = []
    for ((kind, sizeFrac, leading, alpha), (content, trackingFrac)) in zip(
        LINES, [(headline, headlineTracking), (subhead, SUBHEAD_TRACKING)])
    {
        if content.isEmpty { continue }
        let nominal = Double(Int(Double(w) * sizeFrac))
        var size = nominal
        var lines: [String]?
        while true {
            let font = makeFont(kind, size)
            let tracking = trackingFrac * size
            if kind == "headline" {
                lines = lineWidth(content, font, tracking) <= maxW ? [content] : nil
            } else {
                lines = wrapTwo(content, font, tracking, maxW, lang)
            }
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
    canvasW: Int, canvasH: Int, widthFrac: Double, glyphs: [String], lang: String
) {
    let (rawWin, header) = loadWindow(shot)
    let art = crop(rawWin, x: 0, y: 0, w: header, h: header)

    // Width binds for the short shots, height for the tall playlist+pitch one.
    let scale = min(
        Double(canvasW) * widthFrac / Double(rawWin.w),
        Double(canvasH) * WINDOW_H_FRAC / Double(rawWin.h))
    let win = resized(rawWin, w: Int(Double(rawWin.w) * scale), h: Int(Double(rawWin.h) * scale))

    var canvas = buildBackground(art: art, w: canvasW, h: canvasH)

    var glyphImages: [Buffer] = []
    var glyphH = 0.0, glyphGap = 0.0
    if !glyphs.isEmpty {
        glyphImages = renderGlyphs(glyphs)
        glyphH = Double(layoutGlyphs(glyphImages, canvasW).rowH)
        glyphGap = Double(canvasW) * GLYPH_BLOCK_GAP_FRAC
    }

    let layout = layoutText(headline, subhead, canvasW, lang)
    let blockH = textHeight(layout)
    let gap = blockH > 0 ? Double(canvasW) * 0.032 : 0
    let stack = glyphH + glyphGap + blockH + gap + Double(win.h)
    var top = (Double(canvasH) - stack) * BLOCK_Y_FRAC

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
    let y = Int(top + blockH + gap)
    for shadow in dropShadows(canvasW: canvasW, canvasH: canvasH, window: win, x: x, y: y, scale: scale) {
        composite(&canvas, shadow, x: 0, y: 0)
    }
    composite(&canvas, win, x: x, y: y)

    // Flatten: ASC wants opaque screenshots.
    for i in stride(from: 3, to: canvas.data.count, by: 4) { canvas.data[i] = 255 }
    savePNG(canvas, to: out)
    print("wrote \(out) (\(canvasW)x\(canvasH), window \(win.w)px wide, \(String(format: "%.2f", scale))x)")
}

// --- CLI --------------------------------------------------------------------

var shot: String?, outPath: String?
var headline = "", subhead = "", lang = "en"
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
    case "--measure": measure = true
    default:
        if arg.hasPrefix("--") { die("unknown option \(arg)") }
        if shot == nil { shot = arg } else if outPath == nil { outPath = arg } else { die("unexpected argument \(arg)") }
    }
}

let canvasParts = canvasSpec.split(separator: "x").compactMap { Int($0) }
guard canvasParts.count == 2 else { die("bad --canvas \(canvasSpec)") }

if measure {
    _ = layoutText(headline, subhead, canvasParts[0], lang)
    exit(0)
}
guard let shotPath = shot, let output = outPath else {
    die("usage: compose-app-store-overlay <shot.png> <out.png> [--headline ...] (or --measure)")
}
let glyphNames = glyphSpec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
compose(
    shot: shotPath, out: output, headline: headline, subhead: subhead,
    canvasW: canvasParts[0], canvasH: canvasParts[1], widthFrac: widthFrac,
    glyphs: glyphNames, lang: lang)
