// Composite one App Store screenshot: a background image, aspect-filled to the
// canvas, with a captured window PNG placed on it.
//
//   swift compose-app-store-shot.swift <background> <window.png> <out.png> \
//       <canvasW> <canvasH> <destX> <destY> <destW>
//
// window.png is a merged capture (compose-window-shot.swift). Its shadow
// padding is asymmetric, so the window rect is measured as the bounding box of
// alpha == 255.
//
// dest* is where that box lands, in canvas pixels, TOP-LEFT origin. destW alone
// fixes the scale, so a caller cannot stretch the window by rounding one axis
// differently; the shadow scales with it and is not cropped to dest.
//
// Written WITHOUT an alpha channel: App Store Connect rejects one.
import CoreGraphics
import Foundation
import ImageIO

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        die("could not read an image from \(path)")
    }
    return image
}

// The window rect within a shadow-padded capture, top-left origin.
func opaqueBounds(_ image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    data.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            die("could not create a \(width)x\(height) bitmap context")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where data[(y * width + x) * 4 + 3] == 255 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    if maxX < 0 {
        die("no fully opaque pixels in \(CommandLine.arguments[2]) — is it really a window shot?")
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let args = CommandLine.arguments
guard args.count == 9,
      let canvasW = Int(args[4]), let canvasH = Int(args[5]),
      let destX = Double(args[6]), let destY = Double(args[7]), let destW = Double(args[8]),
      canvasW > 0, canvasH > 0, destW > 0 else {
    die("usage: compose-app-store-shot.swift <background> <window.png> <out.png> "
        + "<canvasW> <canvasH> <destX> <destY> <destW>")
}

let background = loadImage(args[1])
let windowImage = loadImage(args[2])
let box = opaqueBounds(windowImage)
let scale = CGFloat(destW) / box.width
let canvas = CGRect(x: 0, y: 0, width: CGFloat(canvasW), height: CGFloat(canvasH))

// noneSkipLast: an opaque canvas, so the PNG has no alpha; the shadow still
// blends.
guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    die("could not create a \(canvasW)x\(canvasH) canvas")
}
ctx.interpolationQuality = .high

// Aspect-filled and centred: the crop backdrop.swift's --rect layer draws on
// screen, so the glass and its surround stay continuous.
let fill = max(canvas.width / CGFloat(background.width),
               canvas.height / CGFloat(background.height))
let filled = CGSize(width: CGFloat(background.width) * fill,
                    height: CGFloat(background.height) * fill)
ctx.draw(background, in: CGRect(x: (canvas.width - filled.width) / 2,
                                y: (canvas.height - filled.height) / 2,
                                width: filled.width, height: filled.height))

// The whole capture, shadow included, placed so its opaque box lands on dest.
// CoreGraphics is bottom-left origin.
let drawn = CGSize(width: CGFloat(windowImage.width) * scale,
                   height: CGFloat(windowImage.height) * scale)
let drawnX = CGFloat(destX) - box.minX * scale
let drawnTop = CGFloat(destY) - box.minY * scale
ctx.draw(windowImage, in: CGRect(x: drawnX, y: canvas.height - drawnTop - drawn.height,
                                 width: drawn.width, height: drawn.height))

guard let image = ctx.makeImage() else { die("could not build the output image") }
guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: args[3]) as CFURL, "public.png" as CFString, 1, nil) else {
    die("could not create \(args[3])")
}
CGImageDestinationAddImage(dest, image, nil)
if !CGImageDestinationFinalize(dest) {
    die("could not write \(args[3])")
}
print("composed \(args[3]) — \(canvasW)x\(canvasH), window "
      + "\(Int(box.width))x\(Int(box.height))px at \(String(format: "%.3f", scale))x "
      + "→ \(Int(box.width * scale))x\(Int(box.height * scale)) at \(Int(destX)),\(Int(destY))")
