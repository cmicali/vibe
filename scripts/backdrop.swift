// A full-screen window to stage behind Vibe for `CAPTURE=merged` screenshots
// (see generate-screenshots.sh) — either an image or a gradient.
//
//   swift backdrop.swift <image-path>   # draw an image, aspect-filled
//   swift backdrop.swift [hex ...]      # or a gradient; default blue → violet
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

let arguments = Array(CommandLine.arguments.dropFirst())
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
let layer: CALayer
if let imagePath {
    guard let source = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: imagePath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("could not read \(imagePath)\n".data(using: .utf8)!)
        exit(1)
    }
    let imageLayer = CALayer()
    imageLayer.contents = image
    imageLayer.contentsGravity = .resizeAspectFill
    layer = imageLayer
} else {
    let gradient = CAGradientLayer()
    gradient.colors = hexes.map(color)
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    layer = gradient
}
layer.frame = bounds

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
