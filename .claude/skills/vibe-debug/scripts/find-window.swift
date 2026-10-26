// Print one line per on-screen window of one process, front to back:
//   windowID pid x y width height
// Usage: swift find-window.swift <pid>
//
// By pid, not by owner name: every build slot's windows are owned by "Vibe"
// (the vibe-debug skill's Slots).
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pidFilter = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: swift find-window.swift <pid>\n".data(using: .utf8)!)
    exit(64)
}
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("cannot read window list\n".data(using: .utf8)!)
    exit(1)
}
var found = false
for w in list {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    if pid != pidFilter { continue }
    let wid = w[kCGWindowNumber as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(wid, pid,
          b["X"] as? Int ?? 0, b["Y"] as? Int ?? 0,
          b["Width"] as? Int ?? 0, b["Height"] as? Int ?? 0)
    found = true
}
exit(found ? 0 : 1)
