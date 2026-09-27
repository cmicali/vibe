// Print the CGWindowID of the window generate-readme-screenshots.sh captures
// (`screencapture -l<id>`) and stages behind Vibe.
//
//   swift backdrop-window-id.swift "IntelliJ IDEA"   # by owning app name
//   swift backdrop-window-id.swift wallpaper         # the desktop picture
//
// The owner name matches as a case-insensitive substring, and the largest
// window wins so a palette cannot beat the editor. The wallpaper is a real
// Dock-owned window; desktop icons are a separate Finder window, so none come
// along. Exits 1, printing no id, when nothing matches.
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []

func field<T>(_ window: [String: Any], _ key: CFString) -> T? {
    window[key as String] as? T
}

func windowID(ownerContains needle: String) -> Int? {
    var best: (id: Int, area: CGFloat)?
    for window in windows {
        guard let owner: String = field(window, kCGWindowOwnerName),
              owner.range(of: needle, options: .caseInsensitive) != nil,
              owner != "Vibe",
              field(window, kCGWindowLayer) == 0 as Int?,
              let id: Int = field(window, kCGWindowNumber),
              let bounds: [String: CGFloat] = field(window, kCGWindowBounds) else { continue }
        let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
        if area > (best?.area ?? 0) {
            best = (id, area)
        }
    }
    return best?.id
}

func wallpaperWindowID() -> Int? {
    // The Dock's "Wallpaper-<uuid>" is the one on screen; the Wallpaper
    // agent's offscreen copy is a fallback should the Dock stop hosting it.
    for (owner, prefix) in [("Dock", "Wallpaper"), ("Wallpaper", "")] {
        for window in windows {
            guard field(window, kCGWindowOwnerName) == owner as String?,
                  let name: String = field(window, kCGWindowName), name.hasPrefix(prefix),
                  let id: Int = field(window, kCGWindowNumber) else { continue }
            return id
        }
    }
    return nil
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "wallpaper"
if let id = target.lowercased() == "wallpaper" ? wallpaperWindowID()
        : windowID(ownerContains: target) {
    print(id)
} else {
    FileHandle.standardError.write("no on-screen window matching '\(target)'\n"
            .data(using: .utf8)!)
    exit(1)
}
