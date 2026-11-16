// Composite a Vibe capture into an App Store frame.
//
// Compiled once by its callers (`swift file.swift` recompiles every run):
//     swiftc -O -o compose scripts/appstore/compose-app-store-overlay.swift
//
//     compose <shot.png> <out.png> [--headline …] [--subhead …] [--lang …]
//         [--canvas WxH] [--width frac] [--ground RRGGBB]
//         [--headline-scale x] [--subhead-scale x] [--block-y frac]
//     compose --measure --headline … [--subhead …] [--lang …] [--canvas WxH]
//                                      # exit 1 if the caption cannot fit
//     compose --header <out.png> --canvas WxH
//     compose --row <art.png> <out.png> <left> <middle> <right> --canvas WxH
//
// A mock-up, unlike appstore-capture-app-screenshots.sh: it lays an
// already-captured window (the alpha-channel PNGs in Assets/readme/) over a
// ground. Honest only because those captures are effectively opaque, so the
// ground is around the window, never through it.
//
// The frame is a flat field of the capture's own colour, the caption set
// flush left on the window's left edge, and the window as wide as the margin
// allows. The canvas's shape picks the layout (Frame): landscape holds a mac
// window, portrait a full-screen device capture. The creative assets keep the
// app icon's vinyl-groove background (buildBackground).
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
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path

// The default canvas; everything is placed by fraction, so any other works.
let CANVAS_W = 2880
let CANVAS_H = 1800

// A landscape canvas holds a mac window capture, this wide. The margin left
// over is the frame's one measure: the text starts on it and the window sits on
// it. The README captures are 1450-1650px wide, so this upscales ~1.6-1.8x,
// which the 2x source takes without visible softening.
let WINDOW_W_FRAC = 0.90  // --width overrides
// The text starts this many margins from the top. A short window's stack sits
// this far down the room it leaves, a little under the middle.
let LANDSCAPE_TOP_MARGINS = 1.5
let SHORT_STACK_Y = 0.56  // --block-y overrides

// A portrait canvas holds a full-screen device capture. The screen is pinned
// this far from the bottom, and the text starts this far from the top. Both
// are fractions of the canvas height.
let PORTRAIT_EDGE_FRAC = 0.045
let PORTRAIT_GAP_FRAC = 0.024

// Headline and subhead sizes, as multiples of LINES' nominal sizes. A phone
// shot is drawn small in the store, so its one line runs larger.
let LANDSCAPE_SCALES = (1.55, 1.2)
// A window this short, as a fraction of the canvas height, leaves the frame
// half empty. Its headline starts this much larger and fills it.
let SHORT_WINDOW_FRAC = 0.45
let DISPLAY_HEADLINE = 1.5
let PORTRAIT_SCALES = (1.6, 1.0)

// The screen's own corner, as a fraction of its width: 55pt of 430 on the
// iPhone, 18pt of 1024 on the iPad.
let PHONE_CORNER_FRAC = 0.128
let PAD_CORNER_FRAC = 0.0176

let GROOVE = "\(ROOT)/Assets/record background.png"

// Tracking is a fraction of the point size. Negative tracking is a Latin
// display convention, so CJK stays at 0.
let HEADLINE_TRACKING = -0.028
let SUBHEAD_TRACKING = 0.0
let CJK_LANGS: Set<String> = ["ja", "ko", "zh-Hans", "zh-Hant"]
// Written without spaces, so a line may break at any character.
let CHAR_BREAK_LANGS: Set<String> = ["ja", "zh-Hans", "zh-Hant"]

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
func loadWindow(_ path: String) -> Buffer {
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

    return win
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

// --- the ground -------------------------------------------------------------

// A frame's ground is one flat colour, and it is the capture's own. Each pixel
// votes for its hue with its chroma, so the artwork and the waveform outvote
// the window's greys. The winning hue's pixels are averaged. The tone is then
// held in one band, so a set of frames reads as one family whatever the art.
let GROUND_LIGHTNESS = 0.26...0.40
let GROUND_MAX_SATURATION = 0.62
// A capture with no colour to speak of gets this neutral instead.
let GROUND_NEUTRAL: RGB = (0.105, 0.105, 0.115)

typealias RGB = (r: Double, g: Double, b: Double)

func hueOf(_ c: RGB) -> Double {  // 0..<6
    let mx = max(c.r, c.g, c.b), d = mx - min(c.r, c.g, c.b)
    if d == 0 { return 0 }
    let h = mx == c.r ? (c.g - c.b) / d : mx == c.g ? 2 + (c.b - c.r) / d : 4 + (c.r - c.g) / d
    return h < 0 ? h + 6 : h
}

func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> RGB {
    let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
    let (r, g, b) = [(c, x, 0.0), (x, c, 0.0), (0.0, c, x), (0.0, x, c), (x, 0.0, c), (c, 0.0, x)][min(5, Int(h))]
    return (r + m, g + m, b + m)
}

func parseHex(_ hex: String) -> RGB {
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { die("--ground takes six hex digits, got '\(hex)'") }
    return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
}

func groundColor(_ win: Buffer) -> RGB {
    let bins = 24
    var votes = [Double](repeating: 0, count: bins)
    var sums = [RGB](repeating: (0, 0, 0), count: bins)
    for i in stride(from: 0, to: win.data.count, by: 4) where win.data[i + 3] == 255 {
        let c: RGB = (Double(win.data[i]) / 255, Double(win.data[i + 1]) / 255, Double(win.data[i + 2]) / 255)
        let chroma = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
        if chroma < 0.12 { continue }
        let bin = Int(hueOf(c) / 6 * Double(bins)) % bins
        votes[bin] += chroma
        sums[bin] = (sums[bin].r + c.r * chroma, sums[bin].g + c.g * chroma, sums[bin].b + c.b * chroma)
    }
    let best = votes.indices.max { votes[$0] < votes[$1] }!
    // Under 1% of the window at full chroma is an accent, not the capture's colour.
    if votes[best] < Double(win.w * win.h) * 0.01 { return GROUND_NEUTRAL }
    let c: RGB = (sums[best].r / votes[best], sums[best].g / votes[best], sums[best].b / votes[best])
    let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
    let l = (mx + mn) / 2
    let sat = mx == mn ? 0 : (mx - mn) / (1 - abs(2 * l - 1))
    return hslToRGB(
        hueOf(c), min(sat, GROUND_MAX_SATURATION),
        min(max(l, GROUND_LIGHTNESS.lowerBound), GROUND_LIGHTNESS.upperBound))
}

func luminance(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

// A capture with the screen's own rounded corner and a hairline, without which
// a black screen dissolves into a dark ground.
func deviceScreen(_ cg: CGImage, w: Double, h: Double, hairline: Double) -> Buffer {
    let radius = w * (h / w > 1.7 ? PHONE_CORNER_FRAC : PAD_CORNER_FRAC)
    let rect = CGRect(x: 0, y: 0, width: w.rounded(), height: h.rounded())
    return drawn(w: Int(rect.width), h: Int(rect.height)) { ctx in
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.interpolationQuality = .high
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(cg, in: rect)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(hairline)
        ctx.strokePath()
    }
}

// --- the creative assets' background ----------------------------------------

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

// A flat field of one named colour. It skips enhanceColor, which exists to
// rescue washed-out ALBUM ART: a named colour is already the hue that was
// wanted, and pushing it 2.1x past its own luma only drives a channel to 0 or
// 255. The groove texture and the vignette are what keep it from reading as a
// flat rectangle, so this stays uniform on purpose.
func solidWash(_ hex: String, w: Int, h: Int) -> Buffer {
    var v = UInt32(hex, radix: 16) ?? 0
    if hex.count != 6 { die("a wash colour takes six hex digits, got '\(hex)'") }
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
    ("headline", 0.041742, 1.08, 255), ("subhead", 0.022768, 1.36, 190),
]
// Space between the headline and the subhead, in headline sizes.
let SUBHEAD_GAP = 0.2
// Text wider than the frame's measure wraps to two lines, then shrinks; below
// MIN_SHRINK of nominal it is too long to read at store size, so it fails and
// the translation must be shortened.
let MIN_SHRINK = 0.72
let SHRINK_STEP = 0.96

// Where the text and the window go. compose and --measure both read it, so the
// fit check measures the frame that is drawn. The text and the window share
// one left edge and one width.
struct Frame {
    let portrait: Bool
    let left: Double
    let width: Double
    let headlineScale: Double
    let subheadScale: Double
    // Portrait only: the box the device screen fills, pinned whatever the text.
    let screenTop: Double
    let screenH: Double

    init(w: Int, h: Int, widthFrac: Double?, headlineScale: Double?, subheadScale: Double?) {
        portrait = h > w
        let defaults = portrait ? PORTRAIT_SCALES : LANDSCAPE_SCALES
        self.headlineScale = headlineScale ?? defaults.0
        self.subheadScale = subheadScale ?? defaults.1
        if portrait {
            // Room for a two-line headline is kept above the screen on every
            // shot, or the device jumps between a one-line shot and the next.
            let edge = Double(h) * PORTRAIT_EDGE_FRAC
            let line = nominalSize("headline", w, h, self.headlineScale) * LINES[0].2
            screenH = Double(h) - 2 * edge - 2 * line - Double(h) * PORTRAIT_GAP_FRAC
            screenTop = Double(h) - edge - screenH
            // A device capture has its canvas's shape.
            width = screenH * Double(w) / Double(h)
        } else {
            width = Double(w) * (widthFrac ?? WINDOW_W_FRAC)
            screenTop = 0
            screenH = 0
        }
        left = (Double(w) - width) / 2
    }
}

// Sizes scale with the canvas's area.
func nominalSize(_ kind: String, _ w: Int, _ h: Int, _ scale: Double) -> Double {
    let frac = LINES.first { $0.0 == kind }!.1
    return Double(Int((Double(w) * Double(h)).squareRoot() * frac * scale))
}

struct Line {
    let text: String
    let font: NSFont
    let tracking: Double
    let leading: Double
    let alpha: Double
    let gapAbove: Double
}

func makeFont(_ kind: String, _ size: Double) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: kind == "headline" ? .bold : .regular)
}

// The attributed run applies the tracking between glyphs, not after the last,
// so a line carries no trailing slack.
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

// Wrap into at most two lines; nil if two don't fit. Of the breaks that fit,
// the one with the shorter long line wins, so no last word is left alone. ja/zh
// have no spaces, so they may break at any character (kinsoku deliberately not
// implemented — two marketing lines don't warrant it).
func wrapTwo(_ text: String, _ font: NSFont, _ tracking: Double, _ maxW: Double, _ lang: String) -> [String]? {
    if lineWidth(text, font, tracking) <= maxW { return [text] }
    let charBreak = CHAR_BREAK_LANGS.contains(lang)
    let units = charBreak ? text.map(String.init) : text.components(separatedBy: " ")
    let joiner = charBreak ? "" : " "
    var best: [String]?, bestW = maxW
    for cut in 1..<max(units.count, 1) {
        let first = units[..<cut].joined(separator: joiner).trimmingTrailingSpaces()
        let second = units[cut...].joined(separator: joiner).trimmingLeadingSpaces()
        let longer = max(lineWidth(first, font, tracking), lineWidth(second, font, tracking))
        if longer <= bestW { best = [first, second]; bestW = longer }
    }
    return best
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
// placement cannot disagree. Dies (exit 1) when a string cannot fit: the
// --measure contract. An empty line is dropped (iOS captions are
// headline-only).
//
// display starts the headline larger. It still shrinks to the same floor, so
// --measure, which never passes it, answers for both.
func layoutText(
    _ headline: String, _ subhead: String, _ frame: Frame, _ w: Int, _ h: Int, _ lang: String,
    display: Double = 1.0
) -> [Line] {
    let headlineTracking = CJK_LANGS.contains(lang) ? 0.0 : HEADLINE_TRACKING
    var out: [Line] = []
    for ((kind, _, leading, alpha), (content, trackingFrac, scale)) in zip(
        LINES, [(headline, headlineTracking, frame.headlineScale), (subhead, SUBHEAD_TRACKING, frame.subheadScale)])
    {
        if content.isEmpty { continue }
        let nominal = nominalSize(kind, w, h, scale)
        let floor = nominal * MIN_SHRINK
        var size = kind == "headline" ? (nominal * display).rounded(.down) : nominal
        var lines: [String]?
        // A break at any character can split a word, so those languages
        // shrink to keep one line, and wrap only when no size allows it.
        if CHAR_BREAK_LANGS.contains(lang) {
            var one = size
            while one >= floor && lineWidth(content, makeFont(kind, one), trackingFrac * one) > frame.width {
                one = (one * SHRINK_STEP).rounded(.down)
            }
            if one >= floor { size = one } else { size = min(size, nominal) }
        }
        while true {
            lines = wrapTwo(content, makeFont(kind, size), trackingFrac * size, frame.width, lang)
            if lines != nil { break }
            size = (size * SHRINK_STEP).rounded(.down)
            if size < floor {
                die("\(lang): \(kind) too long even at \(Int(MIN_SHRINK * 100))% size: '\(content)'")
            }
        }
        let font = makeFont(kind, size)
        for (i, line) in lines!.enumerated() {
            out.append(Line(
                text: line, font: font, tracking: trackingFrac * size, leading: size * leading, alpha: alpha,
                gapAbove: i == 0 ? (out.last.map { Double($0.font.pointSize) * SUBHEAD_GAP } ?? 0) : 0))
        }
    }
    return out
}

func textHeight(_ layout: [Line]) -> Double {
    layout.reduce(0) { $0 + $1.gapAbove + $1.leading }
}

// Render the layout from its left edge into a transparent canvas-size buffer.
// Line y is the ascender top, as the block math expects.
func renderTextLayer(_ layout: [Line], top: Double, left: Double, ink: Double, w: Int, h: Int) -> Buffer {
    drawn(w: w, h: h) { ctx in
        var y = top
        for line in layout {
            y += line.gapAbove
            let color = CGColor(red: ink, green: ink, blue: ink, alpha: line.alpha / 255.0)
            let ct = CTLineCreateWithAttributedString(attributed(line.text, line.font, line.tracking, color))
            let baseline = y + Double(line.font.ascender)
            ctx.textPosition = CGPoint(x: left, y: Double(h) - baseline)
            CTLineDraw(ct, ctx)
            y += line.leading
        }
    }
}

// --- compositing ------------------------------------------------------------

func composite(_ canvas: inout Buffer, _ layer: Buffer, x: Int, y: Int) {
    canvas.data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: canvas.w, height: canvas.h, bitsPerComponent: 8,
            bytesPerRow: canvas.w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
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
func dropShadows(
    canvasW: Int, canvasH: Int, window: Buffer, x: Int, y: Int, scale: Double,
    spec: [(Double, Double, Double)] = [(70.0, 8.0, 0.42), (26.0, 26.0, 0.55)]
) -> [Buffer] {
    var layers: [Buffer] = []
    for (blur, dy, opacity) in spec {
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
    shot: String, out: String, headline: String, subhead: String, canvasW: Int, canvasH: Int,
    frame: Frame, lang: String, ground: String?, blockY: Double?
) {
    let rawWin = loadWindow(shot)
    let unit = (Double(canvasW) * Double(canvasH)).squareRoot()

    let groundRGB = ground.map(parseHex) ?? groundColor(rawWin)
    var canvas = Buffer(w: canvasW, h: canvasH)
    for i in stride(from: 0, to: canvas.data.count, by: 4) {
        canvas.data[i] = clamp8(groundRGB.r * 255)
        canvas.data[i + 1] = clamp8(groundRGB.g * 255)
        canvas.data[i + 2] = clamp8(groundRGB.b * 255)
        canvas.data[i + 3] = 255
    }

    let short = !frame.portrait
        && Double(rawWin.h) * frame.width / Double(rawWin.w) < Double(canvasH) * SHORT_WINDOW_FRAC
    let layout = layoutText(
        headline, subhead, frame, canvasW, canvasH, lang, display: short ? DISPLAY_HEADLINE : 1.0)
    let blockH = textHeight(layout)
    let gap = blockH > 0 ? unit * 0.034 : 0

    let win: Buffer
    var textTop: Double, windowTop: Double
    if frame.portrait {
        let scale = min(frame.width / Double(rawWin.w), frame.screenH / Double(rawWin.h))
        win = deviceScreen(
            rawWin.cgImage, w: Double(rawWin.w) * scale, h: Double(rawWin.h) * scale, hairline: unit * 0.0012)
        windowTop = frame.screenTop
        // The text sits on the screen, not at the top: a one-line headline
        // then stays beside what it names.
        textTop = windowTop - Double(canvasH) * PORTRAIT_GAP_FRAC - blockH
    } else {
        let scale = frame.width / Double(rawWin.w)
        win = resized(rawWin, w: Int(frame.width), h: Int(Double(rawWin.h) * scale))
        // The capitals' tops sit on the line, not the line box's.
        let overshoot = layout.first.map { Double($0.font.ascender - $0.font.capHeight) } ?? 0
        textTop = frame.left * LANDSCAPE_TOP_MARGINS - overshoot
        windowTop = textTop + blockH + gap
        // A tall window runs off the bottom edge, which is what lets it be
        // this wide. A short one leaves room, and the stack sits in it.
        if short {
            textTop = (Double(canvasH) - blockH - gap - Double(win.h)) * (blockY ?? SHORT_STACK_Y)
            windowTop = textTop + blockH + gap
        }
    }

    if blockH > 0 {
        let ink = luminance(groundRGB) > 0.55 ? 0.06 : 1.0
        composite(
            &canvas, renderTextLayer(layout, top: textTop, left: frame.left, ink: ink, w: canvasW, h: canvasH),
            x: 0, y: 0)
    }

    let x = Int(frame.left.rounded()), y = Int(windowTop.rounded())
    let shadows = dropShadows(
        canvasW: canvasW, canvasH: canvasH, window: win, x: x, y: y, scale: unit / 2277,
        spec: [(64.0, 36.0, 0.34), (12.0, 6.0, 0.26)])
    for shadow in shadows { composite(&canvas, shadow, x: 0, y: 0) }
    composite(&canvas, win, x: x, y: y)

    flattenAndSave(&canvas, out)
    print(String(format: "  ground #%02X%02X%02X", clamp8(groundRGB.r * 255), clamp8(groundRGB.g * 255), clamp8(groundRGB.b * 255)))
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

// ASC wants opaque screenshots.
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
        return deviceScreen(cg, w: pw, h: ph, hairline: Double(w) * 0.0012)
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
var ground: String? = nil
var headlineScale: Double? = nil
var subheadScale: Double? = nil
var blockY: Double? = nil
var widthFrac: Double? = nil
var canvasSpec = "\(CANVAS_W)x\(CANVAS_H)"
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
    case "--width": widthFrac = Double(value())
    case "--canvas": canvasSpec = value()
    case "--ground": ground = value().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    case "--headline-scale": headlineScale = Double(value())
    case "--subhead-scale": subheadScale = Double(value())
    case "--block-y": blockY = Double(value())
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

let frame = Frame(
    w: canvasParts[0], h: canvasParts[1], widthFrac: widthFrac, headlineScale: headlineScale,
    subheadScale: subheadScale)
if measure {
    _ = layoutText(headline, subhead, frame, canvasParts[0], canvasParts[1], lang)
    exit(0)
}
guard let shotPath = shot, let output = outPath else {
    die("usage: compose-app-store-overlay <shot.png> <out.png> [--headline ...] (or --measure)")
}
compose(
    shot: shotPath, out: output, headline: headline, subhead: subhead,
    canvasW: canvasParts[0], canvasH: canvasParts[1], frame: frame, lang: lang, ground: ground, blockY: blockY)
