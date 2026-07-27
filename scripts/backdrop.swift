// A full-screen window to stage behind Vibe for `CAPTURE=merged` screenshots
// (see generate-screenshots.sh) — either an image or a gradient.
//
//   swift backdrop.swift <image-path>   # draw an image, aspect-filled
//   swift backdrop.swift [hex ...]      # or a gradient; default blue → violet
//   swift backdrop.swift --rect <x> <y> <w> <h> <image-path>
//
// `--rect` (global screen points, origin top-left — the space find-window.swift
// prints and screencapture -R takes) draws a SECOND copy of the content,
// aspect-filled into exactly that rect, over the full-screen one. That is what
// generate-app-store-screenshots.sh uses: its output canvas is a scaled
// rendering of this same image, and the glass is transparent enough to show
// the backdrop nearly directly, so the pixels behind the window have to be the
// canvas's pixels at the canvas's scale — otherwise what shows through the
// window doesn't line up with the background around it. Only the part of the
// rect behind the window matters; the seam where the rect meets the
// full-screen fill is outside every capture.
//
// Merged captures show what is genuinely behind the window through the glass
// and the playlist frost, which otherwise means "whatever happens to be on your
// screen" — not reproducible, and not something to publish unexamined. This
// covers the screen with something known instead.
//
// The window sits at .normal level and is ordered front, so every other app's
// window ends up BEHIND it; activating Vibe afterwards raises Vibe (and only
// Vibe) above it. It ignores mouse events and stays up until killed.
//
// Ordering front ONCE isn't enough: every time the screenshot script kills Vibe,
// macOS activates whatever app is next in the stack, which raises that app's
// window above this one — and the next shot then composites its glass against
// that app instead of the backdrop. So the window re-asserts itself on a timer,
// skipping the tick whenever Vibe is frontmost. That is what keeps it from ever
// landing on top of the window being photographed.
import AppKit
import ImageIO

func color(_ hex: String) -> CGColor {
    var value: UInt64 = 0
    Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&value)
    return CGColor(red: CGFloat((value >> 16) & 0xFF) / 255.0,
                   green: CGFloat((value >> 8) & 0xFF) / 255.0,
                   blue: CGFloat(value & 0xFF) / 255.0,
                   alpha: 1)
}

var arguments = Array(CommandLine.arguments.dropFirst())

// --rect x y w h, if present, is peeled off the front.
var alignedRect: CGRect?
if arguments.first == "--rect" {
    let values = arguments.dropFirst().prefix(4).compactMap(Double.init)
    guard values.count == 4, values[2] > 0, values[3] > 0 else {
        FileHandle.standardError.write("usage: --rect <x> <y> <w> <h>\n".data(using: .utf8)!)
        exit(64)
    }
    alignedRect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    arguments = Array(arguments.dropFirst(5))
}

// A single existing path means image mode; anything else is gradient stops.
let imagePath = arguments.count == 1 && FileManager.default.fileExists(atPath: arguments[0])
        ? arguments[0] : nil
let hexes = arguments.isEmpty || imagePath != nil ? ["1B1A6E", "4A3AC8"] : arguments

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock tile, never steals activation

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no main screen\n".data(using: .utf8)!)
    exit(1)
}

let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                      backing: .buffered, defer: false)
window.level = .normal
window.ignoresMouseEvents = true
window.isOpaque = true
window.collectionBehavior = [.stationary, .ignoresCycle]

let bounds = CGRect(origin: .zero, size: screen.frame.size)

var loadedImage: CGImage?
if let imagePath {
    guard let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: imagePath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("could not read \(imagePath)\n".data(using: .utf8)!)
        exit(1)
    }
    loadedImage = image
}

// One per drawn rect: the full screen, and the aligned rect when there is one.
func makeContentLayer() -> CALayer {
    if let loadedImage {
        let imageLayer = CALayer()
        imageLayer.contents = loadedImage
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true   // aspect-fill overflows its bounds
        return imageLayer
    }
    let gradient = CAGradientLayer()
    gradient.colors = hexes.map(color)
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    return gradient
}

let layer = makeContentLayer()
layer.frame = bounds

if let alignedRect {
    // Global top-left screen points → this window's (bottom-left) layer space.
    // Single-display assumption, like the rest of the screenshot tooling:
    // screens[0] carries the menu bar, and CG's global origin is its top-left.
    let primaryMaxY = (NSScreen.screens.first ?? screen).frame.maxY
    let sublayer = makeContentLayer()
    sublayer.frame = CGRect(x: alignedRect.minX - screen.frame.minX,
                            y: primaryMaxY - alignedRect.maxY - screen.frame.minY,
                            width: alignedRect.width, height: alignedRect.height)
    layer.addSublayer(sublayer)
}

let view = NSView(frame: bounds)
view.wantsLayer = true
view.layer = layer
window.contentView = view
window.orderFrontRegardless()

let vibeBundleID = "com.commonwealthrecordings.Vibe"

final class Reasserter: NSObject {
    let window: NSWindow
    init(_ window: NSWindow) { self.window = window }

    @objc func tick() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != vibeBundleID else {
            return
        }
        window.orderFrontRegardless()
    }
}

let reasserter = Reasserter(window)
Timer.scheduledTimer(timeInterval: 0.3, target: reasserter, selector: #selector(Reasserter.tick),
                     userInfo: nil, repeats: true)

app.run()
