// Prints the on-screen window stack, front to back, one per line:
//   <index> <ownerName> <pid> <width>x<height> layer<n>
// Usage: swift window-stack.swift
//
// The screenshot runs cover the screen with backdrop.swift and then raise the
// app back over it; this is how they check that the raise actually took. A
// window can be key while another app's window sits on top of it, and the
// merged capture reads the composited screen — so without this check a lost
// race photographs the backdrop through a window-shaped hole, silently.
import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("cannot read window list\n".data(using: .utf8)!)
    exit(1)
}
for (index, w) in list.enumerated() {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = b["Width"] as? Int ?? 0
    let height = b["Height"] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    print(index, owner.replacingOccurrences(of: " ", with: "_"), pid, "\(width)x\(height)",
          "layer\(layer)")
}
