// Prints one line per on-screen Vibe window (front to back):
//   windowID pid x y width height
// Usage: swift find-window.swift [pid]
// Pass a pid to filter when multiple Vibe instances are running.
import CoreGraphics
import Foundation

let pidFilter = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("cannot read window list\n".data(using: .utf8)!)
    exit(1)
}
var found = false
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == "Vibe" else { continue }
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    if let f = pidFilter, f != pid { continue }
    let wid = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(wid, pid,
          b["X"] as? Int ?? 0, b["Y"] as? Int ?? 0,
          b["Width"] as? Int ?? 0, b["Height"] as? Int ?? 0)
    found = true
}
exit(found ? 0 : 1)
