// Merge the two screenshot paths into one image that has both halves right.
//
//   swift compose-window-shot.swift <window.png> <region.png> <out.png>
//   swift compose-window-shot.swift --info <window.png>
//
// `window.png`  — screencapture -l<windowID>: the window's own buffer, so it
//                 carries the transparent background, the real drop shadow and
//                 the antialiased rounded corners. Its glass and
//                 NSVisualEffectView materials, though, resolved against a
//                 neutral backdrop instead of the actual screen.
// `region.png`  — screencapture -R over EXACTLY the window's rect: the truly
//                 composited pixels (translucency showing what is behind), but
//                 an opaque rectangle with no shadow and square corners.
//
// The window's pixels sit inside window.png offset by the shadow padding, which
// is NOT symmetric (macOS drops the shadow downward), so the offset is measured
// rather than assumed: the window interior captures fully opaque while every
// shadow pixel is partial, so the bounding box of alpha == 255 IS the window
// rect. Region RGB is copied into that box wherever the window capture is fully
// opaque; the partial-alpha edge and corner pixels keep their original color,
// so the corner arcs stay clean instead of pulling in the backdrop, and
// everything outside the box — the shadow — is left untouched.
import CoreGraphics
import Foundation
import ImageIO

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

struct Bitmap {
    let width: Int
    let height: Int
    let data: UnsafeMutablePointer<UInt8>
    let colorSpace: CGColorSpace
    var bytesPerRow: Int { width * 4 }

    // Normalize whatever the PNG happens to be into RGBA8 premultiplied. With
    // alpha == 255 (every pixel this tool copies) premultiplied and straight
    // color are the same bytes, so the copy needs no math.
    init(_ image: CGImage, colorSpace override: CGColorSpace? = nil) {
        width = image.width
        height = image.height
        colorSpace = override ?? image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        data.initialize(repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: data, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            die("could not create a \(width)x\(height) bitmap context")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func offset(_ x: Int, _ y: Int) -> Int { y * bytesPerRow + x * 4 }
    func alpha(_ x: Int, _ y: Int) -> UInt8 { data[offset(x, y) + 3] }
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        die("could not read an image from \(path)")
    }
    return image
}

// Bounding box of the fully opaque pixels — the window rect within a
// shadow-padded window capture.
func opaqueBounds(_ bitmap: Bitmap) -> (x: Int, y: Int, width: Int, height: Int) {
    var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width where bitmap.alpha(x, y) == 255 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    if maxX < 0 {
        die("no fully opaque pixels in the window capture — is it really a window shot?")
    }
    return (minX, minY, maxX - minX + 1, maxY - minY + 1)
}

func writePNG(_ bitmap: Bitmap, to path: String) {
    guard let ctx = CGContext(data: bitmap.data, width: bitmap.width, height: bitmap.height,
                              bitsPerComponent: 8, bytesPerRow: bitmap.bytesPerRow,
                              space: bitmap.colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = ctx.makeImage() else {
        die("could not build the output image")
    }
    guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
        die("could not create \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        die("could not write \(path)")
    }
}

let args = CommandLine.arguments

if args.count == 3, args[1] == "--info" {
    let bitmap = Bitmap(loadImage(args[2]))
    let box = opaqueBounds(bitmap)
    print("image \(bitmap.width)x\(bitmap.height)  window \(box.width)x\(box.height) "
          + "at \(box.x),\(box.y)  padding l\(box.x) t\(box.y) "
          + "r\(bitmap.width - box.x - box.width) b\(bitmap.height - box.y - box.height)")
    exit(0)
}

guard args.count == 4 else {
    die("usage: compose-window-shot.swift <window.png> <region.png> <out.png>\n"
        + "       compose-window-shot.swift --info <window.png>")
}

let windowImage = loadImage(args[1])
let out = Bitmap(windowImage)
let region = Bitmap(loadImage(args[2]), colorSpace: out.colorSpace)
let box = opaqueBounds(out)

guard region.width == box.width, region.height == box.height else {
    die("""
        size mismatch: window content is \(box.width)x\(box.height) but the region \
        capture is \(region.width)x\(region.height).
        The region must cover EXACTLY the window rect, and the window must not \
        move between the two captures.
        """)
}

for y in 0..<box.height {
    for x in 0..<box.width {
        let dst = out.offset(box.x + x, box.y + y)
        guard out.data[dst + 3] == 255 else { continue }  // edge/corner: keep as captured
        let src = region.offset(x, y)
        out.data[dst] = region.data[src]
        out.data[dst + 1] = region.data[src + 1]
        out.data[dst + 2] = region.data[src + 2]
    }
}

writePNG(out, to: args[3])
print("composed \(args[3]) — window content from the region capture, "
      + "shadow and corners from the window capture")
