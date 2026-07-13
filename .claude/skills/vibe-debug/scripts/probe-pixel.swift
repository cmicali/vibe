// Prints the RGBA of one or more pixels in an image file. Use to assert on
// background tones and colors instead of eyeballing near-identical grays.
//   Usage: swift probe-pixel.swift <image.png> <x> <y> [<x> <y> ...]
// Coordinates are bitmap pixels with origin at the TOP-LEFT. Note that
// screencapture output is 2x on retina displays (window point = pixel / 2).
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, args.count % 2 == 0 else {
    FileHandle.standardError.write(
        "usage: swift probe-pixel.swift <image.png> <x> <y> [<x> <y> ...]\n".data(using: .utf8)!)
    exit(64)
}
guard let img = NSImage(contentsOfFile: args[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read image: \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cg)
print("size: \(rep.pixelsWide)x\(rep.pixelsHigh)")
var i = 2
while i + 1 < args.count {
    guard let x = Int(args[i]), let y = Int(args[i + 1]),
          x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
          let c = rep.colorAt(x: x, y: y) else {
        print("(\(args[i]),\(args[i + 1])): out of bounds or unreadable")
        i += 2
        continue
    }
    print(String(format: "(%d,%d): R %.3f G %.3f B %.3f A %.3f",
                 x, y, c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent))
    i += 2
}
