// Print the CGWindowID of a window to stage behind Vibe for `CAPTURE=merged`
// screenshots — for `screencapture -l<id>` (see generate-readme-screenshots.sh).
//
//   swift backdrop-window-id.swift "IntelliJ IDEA"   # by owning app name
//   swift backdrop-window-id.swift wallpaper         # the desktop picture
//
// App matching is a case-insensitive substring of the owner name, and picks the
// largest on-screen window it owns so a palette or tool window can't win over
// the editor. The wallpaper is a real window owned by the Dock, sitting far
// below the normal window levels; capturing it gets the picture ALONE, since
// desktop icons are a separate Finder window at a different layer, so no file
// names come along. Exits 1 with nothing printed if there's no match.
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
    // "Wallpaper-<uuid>" owned by the Dock is the one actually on screen; the
    // Wallpaper agent's own window is an offscreen staging copy, used as a
    // fallback in case the Dock stops hosting it.
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
