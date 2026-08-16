# Util

Code with **no feature**. That is the entire admission test, and it is stricter than it sounds: if you can name the feature a file serves, it belongs in that feature's directory, however utility-shaped it looks. The window-animation timing is the live example: utility-shaped, but it is only here because *two* windows share it and no single feature owns it.

What passes the test: the portable `NS*` categories (`Categories/`), the display formatters (`Formatters`), the occlusion-gated playback ticker (`UIUpdateTimer` — two gates and a rate, with no knowledge of the window or the player that set them, which is why both platforms' screens drive it), the prefix header's small change (`HelperMacros.h` — control-state and main-thread shorthands, `clampMin`; it reaches every translation unit through the `.pch`, so anything added there is paid for everywhere), `VibeWeakProxy` (a Foundation-only forwarding proxy that breaks the retain cycle a `CADisplayLink` or `NSTimer` target creates; shared because the class is platform-free, though only iOS aims one at anything today), and the URL walking below.

**`Mac/` is the AppKit half** — the app's typography (`Fonts`), the one window-chrome timing every window the app resizes shares (`WindowAnimation.h`), the single-track commands (`TrackCommands`, which reveal in Finder and write the pasteboard), and the categories on AppKit classes. **`iOS/` is the UIKit half** — `UIView+DarkMode`, the mirror of `Mac/`'s `NSView+DarkMode`. Neither target names the other's subdirectory, which is the whole of how each is kept out; see the root `CLAUDE.md` on the directory being the platform boundary.

## NSURLUtil is the disk walk, and it stays ignorant on purpose

`NSURLUtil` expands whatever the user opened — a file, a folder, a playlist file — into an ordered list of audio URLs, on background workers, never the main thread. Two things it discovers along the way are wanted elsewhere, and it reports both through **handler blocks the app installs at launch** rather than calling anyone:

- the grant a playlist file needs, when its entries turn out to live somewhere unreadable (`Vibe/Mac/App/`'s `FolderAccessManager+GrantPanel`);
- the folders it listed and the covers it saw in them, which the folder-art resolver takes for free rather than paying for its own I/O (`Vibe/Audio/Metadata/`).

The indirection is not portability, even though this directory is now shared with iOS. It is that a walk which called an app singleton behind a user setting, a sandbox grant and a modal panel could not be exercised in a test, and this one is, including a fuzz suite. **Unset handlers mean the walk still works and simply throws the extra facts away**, which is exactly what the tests install.

So the rule is narrower than "imports nothing from a feature", and worth stating exactly, because two imports here look like violations and are not: **what `Util/` may not call is anything stateful** — a singleton, a setting, a grant, a panel. Stateless code is fair game wherever it lives, so `NSURLUtil.m` imports `PlaylistFile` (a `+`-only CUE/M3U parser, itself unit- and fuzz-tested) and `FolderArtRules.h` (`static inline` decisions, no linkage) directly. Neither can make the walk untestable, which is the property the handlers exist to protect.

## Categories

Behavior added to a foreign class is a category (`NSURL+Hash`, `NSImage+Util`), never a free function taking that class as its first argument — see the root `CLAUDE.md`'s suffix rules. A category on an AppKit class belongs in `Mac/`, a portable one in `Categories/`; a category on one of the app's own classes belongs beside that class.

The one deliberate exception is `Common/PlatformImage.h`'s bounded decode, which is a free function precisely because it has no single foreign class to hang on — it constructs an `NSImage` or a `UIImage` depending on the target.
